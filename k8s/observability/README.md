# platform-infra/k8s/observability

The collection layer: logs (Vector → Loki), traces (OTel Collector → Tempo),
metrics (Prometheus, scraping every service's existing `/metrics`), and
Grafana dashboards as code. Plain manifests, not a Helm chart — same
rationale as `../opa`: shared cluster infrastructure, not a per-service
release.

Every app service already emits everything this layer collects
(`ARCHITECTURE.md`'s Observability section) — this directory only adds the
infrastructure that gathers, stores, and displays those signals. The one
exception is `saga-metrics-exporter/`, a small standalone exporter added
because no Prometheus metric for `saga_log` terminal states existed
anywhere before this — see its README for why that's a separate exporter
and not a change to order-service.

## Why Vector, not Fluent Bit

Both are legitimate DaemonSet log-shippers; Vector won for three reasons —
see the fuller comment in `vector/vector.yaml`:

1. **One tool, two environments.** Vector's `kubernetes_logs` source (used
   here) and `docker_logs` source (used by the Compose profile) are both
   first-class. Fluent Bit's local-dev story means bind-mounting
   `/var/lib/docker/containers`, which doesn't exist as a host path on
   Docker Desktop (macOS/Windows run Docker in a VM).
2. **VRL** (`transforms.parse_json` in `vector/vector.yaml`) is a typed
   expression language with forced error handling — precise, reviewable
   control over exactly which fields become Loki labels, which matters a
   lot given the cardinality constraint below.
3. Single static binary, low memory, fits a per-node DaemonSet.

## Label strategy (why it matters)

Loki labels **`service`** and **`namespace`** only. **`correlationId` is
never a label** — every request mints a new one, so promoting it to a label
would open a new index series per HTTP request, i.e. unbounded cardinality,
the exact failure mode Loki's own docs warn about. It stays a plain JSON
field inside the stored log line, queried with `| json | correlationId=".."`
— see `../docs/find-by-rayid.md`. The same `service`/`namespace` convention
is mirrored in Prometheus's relabeling (`prometheus/prometheus.yml`) so a
dashboard variable can drive both a metrics panel and a logs panel.

## Layout

| Path | What |
|---|---|
| `namespace.yaml` | `observability` |
| `vector/` | DaemonSet, RBAC, `vector.yaml` (kubernetes_logs → Loki) |
| `loki/` | Deployment, Service, PVC, `loki-config.yaml` (filesystem, single binary) |
| `tempo/` | Deployment, Service, PVC, `tempo.yaml` (OTLP receiver, local storage) |
| `otel-collector/` | Deployment, Service, `config.yaml` (OTLP in → OTLP out to Tempo) |
| `prometheus/` | Deployment, Service, RBAC, `prometheus.yml` (annotation-based pod discovery) |
| `rabbitmq-exporter/` | README only — the patch lives in `../../demo/data-namespace.yaml` (enables RabbitMQ's built-in `rabbitmq_prometheus` plugin) |
| `saga-metrics-exporter/` | Node exporter for `saga_log` terminal-state counts (deployed to `default`, not `observability` — see its README) |
| `grafana/` | Deployment, Service, provisioning (datasources + dashboard-provider), `dashboards/*.json` |

## Apply order

Namespace first; everything else has no strict ordering beyond
"ConfigMap before the thing that mounts it," but doing it top-to-bottom is
simplest. The four components with raw (non-k8s) config files use
`kubectl create configmap --from-file` instead of a static ConfigMap
manifest — keeps the config file itself as the single source of truth
(also what the Compose profile bind-mounts directly), rather than
duplicating its content inline into a second YAML file. `../opa`'s
`configmap.yaml.template` already deviates from plain `apply -f` for a
similar reason (envsubst); this is the same idea.

```bash
cd platform-infra/k8s/observability

kubectl apply -f namespace.yaml

# --- Vector ---
kubectl apply -f vector/serviceaccount.yaml -f vector/clusterrole.yaml -f vector/clusterrolebinding.yaml
kubectl create configmap vector-config -n observability \
  --from-file=vector.yaml=./vector/vector.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f vector/daemonset.yaml

# --- Loki ---
kubectl apply -f loki/pvc.yaml
kubectl create configmap loki-config -n observability \
  --from-file=loki-config.yaml=./loki/loki-config.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f loki/deployment.yaml -f loki/service.yaml

# --- Tempo ---
kubectl apply -f tempo/pvc.yaml
kubectl create configmap tempo-config -n observability \
  --from-file=tempo.yaml=./tempo/tempo.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f tempo/deployment.yaml -f tempo/service.yaml

# --- OTel Collector ---
kubectl create configmap otel-collector-config -n observability \
  --from-file=config.yaml=./otel-collector/config.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f otel-collector/deployment.yaml -f otel-collector/service.yaml

# --- Prometheus ---
kubectl apply -f prometheus/serviceaccount.yaml -f prometheus/clusterrole.yaml -f prometheus/clusterrolebinding.yaml
kubectl create configmap prometheus-config -n observability \
  --from-file=prometheus.yml=./prometheus/prometheus.yml --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f prometheus/deployment.yaml -f prometheus/service.yaml

# --- RabbitMQ Prometheus plugin (demo broker) ---
kubectl apply -f ../../demo/data-namespace.yaml   # includes the rabbitmq_prometheus + per-object-metrics patch

# --- saga-metrics-exporter (namespace: default, co-located with order-service) ---
kubectl apply -f saga-metrics-exporter/deployment.yaml -f saga-metrics-exporter/service.yaml

# --- Grafana ---
kubectl create configmap grafana-datasources -n observability \
  --from-file=datasources.yaml=./grafana/provisioning/datasources.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap grafana-dashboards-provider -n observability \
  --from-file=dashboards.yaml=./grafana/provisioning/dashboards-provider.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap grafana-dashboards-data -n observability \
  --from-file=./grafana/dashboards --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f grafana/deployment.yaml -f grafana/service.yaml
```

Then every app service's Helm chart (`--set` on top of its existing
`helm/values.yaml`, which already points `OTEL_EXPORTER_OTLP_ENDPOINT` at
`otel-collector.observability.svc.cluster.local:4317` and carries the
`prometheus.io/*` pod annotations from the base chart) — no per-service
change needed beyond what's already in this branch.

## Verifying end-to-end

`kubectl port-forward -n observability svc/grafana 3000:3000` →
`http://localhost:3000` (admin/admin — see the env-var comment in
`grafana/deployment.yaml` about swapping this for a real secret). Dashboards
land under the "Archtenet" folder. For the exact queries acceptance
criterion #3 needs (one `cf-ray` across every service's logs, one trace by
`rayId`), see `../docs/find-by-rayid.md` — those queries are identical
whether run against this k8s stack or the Compose `observability` profile.
