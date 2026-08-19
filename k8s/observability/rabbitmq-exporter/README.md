# "the rabbitmq exporter"

There's no separate exporter container in this directory — RabbitMQ has
shipped its own Prometheus exporter as a built-in plugin
(`rabbitmq_prometheus`) since 3.8. The `rabbitmq:3.13-management-alpine`
image already used everywhere in this system bundles it; it just isn't
enabled by default. That's a strictly better fit than a third-party
`kbudde/rabbitmq_exporter`-style sidecar: no extra pod, no separate image to
track for version drift against the broker, and it's the path RabbitMQ's own
docs recommend.

Enabling it is a one-line `enabled_plugins` file mounted over
`/etc/rabbitmq/enabled_plugins`, exposing `/metrics` on port 15692. See the
patch to the demo RabbitMQ deployment:
[`../../../demo/data-namespace.yaml`](../../../demo/data-namespace.yaml) —
the `rabbitmq-enabled-plugins` ConfigMap + the `rabbitmq` Deployment's
`enabled-plugins` volume mount and `prometheus.io/*` pod annotations.

**A second, easy-to-miss step**: `rabbitmq_prometheus` only exposes
*aggregated* cluster-wide totals by default —
`rabbitmq_queue_messages` with no `queue` label at all, which silently
breaks the DLQ-depth-by-queue panel below (empty, no error). Per-object
(per-queue) metrics are an explicit opt-in — verified live against this
demo stack, not just from docs. See
[`rabbitmq-prometheus-per-object.conf`](./rabbitmq-prometheus-per-object.conf)
(`prometheus.return_per_object_metrics = true`), mounted straight to
`/etc/rabbitmq/rabbitmq.conf` in both `data-namespace.yaml` and
`docker-compose.observability.yml` — not `conf.d/*.conf`, since that
directory's auto-inclusion is a RabbitMQ Cluster Operator convention, not
something the plain community image does on its own.

In a real cluster (RabbitMQ run some other way — Amazon MQ, the Bitnami
Helm chart, a StatefulSet not defined in this repo), replicate the same
three things against whatever runs RabbitMQ there:

1. Enable `rabbitmq_prometheus` (either the `enabled_plugins` file above, or
   `rabbitmq-plugins enable rabbitmq_prometheus` if you can exec in).
2. Set `prometheus.return_per_object_metrics = true` (`rabbitmq-prometheus-per-object.conf`
   above, or `rabbitmqctl eval` the equivalent application-env change).
3. Add `prometheus.io/scrape: "true"`, `prometheus.io/port: "15692"`,
   `prometheus.io/path: "/metrics"` to the pod template, and
   `app.kubernetes.io/name: rabbitmq` to its labels so it picks up the same
   `service` label every other scrape target gets (see
   [`../prometheus/prometheus.yml`](../prometheus/prometheus.yml)).

The metric the saga-health dashboard reads off this is `rabbitmq_queue_messages`
(labels `queue`, `vhost`) — DLQ depth is `sum(rabbitmq_queue_messages{queue=~".+\\.dlq"})`,
matching the `<queue>.dlq` naming convention every saga reply/command queue's
dead-letter binding uses (see `order-service/src/order-orchestrator/saga-replies.consumer.ts`).

## Local (Compose)

Same plugin, same port — see
[`../../../docker-compose.observability.yml`](../../../docker-compose.observability.yml)'s
override of the `rabbitmq` service, which mounts the identical
`enabled_plugins` content and adds `15692:15692` to the exposed ports.
