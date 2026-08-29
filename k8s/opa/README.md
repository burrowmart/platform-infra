# platform-infra/k8s/opa

The OPA PDP DaemonSet — plain manifests, not a Helm chart (this is
infrastructure shared cluster-wide, not a per-service release like
`platform-infra/helm/base-service`).

## Files

| File | What |
|---|---|
| `namespace.yaml` | `opa-system` |
| `serviceaccount.yaml` | `opa-pdp`, IRSA-annotated (real EKS only) |
| `configmap.yaml.template` | OPA `config.yaml` — S3 bundle polling + the `envoy_ext_authz_grpc` plugin. `${OPA_BUNDLE_S3_URL}` is `envsubst`'d in by whatever deploys this (the demo script, or your real pipeline) |
| `daemonset.yaml` | `opa` + `opal-client` containers, one pod per node |
| `service.yaml` | ClusterIP `opa-pdp:9191` — what every service's Envoy sidecar calls |
| `minio.yaml` | **Unused by the current local path.** A local S3 stand-in, so `kind` could exercise the real `services.s3` / SigV4-signing code path. `../../demo/opa.yaml` mounts the 4 KB bundle from a ConfigMap instead, which drops MinIO, its credentials Secret and the bucket-seeding step. Keep this only if you specifically want to exercise the S3 polling path locally. Not part of the production path — real S3 needs no in-cluster resource. |

## Apply order

```bash
kubectl apply -f namespace.yaml
kubectl apply -f serviceaccount.yaml
kubectl create secret generic opa-s3-credentials -n opa-system \
  --from-literal=access-key-id=... --from-literal=secret-access-key=...
kubectl apply -f minio.yaml                    # demo only
envsubst < configmap.yaml.template | kubectl apply -f -
kubectl apply -f service.yaml
# opal-client-secrets (OPAL_CLIENT_TOKEN) must exist before this:
kubectl apply -f daemonset.yaml
```

The apply order above is the **deployed** (S3 + OPAL) path. Nothing scripts it
yet — `OPA_BUNDLE_S3_URL` comes from terraform's `opa_bundle_bucket_name`
output, and the OPAL secrets from `../opal/`.

For a laptop cluster use `../../demo/opa.yaml` instead (bundle from a
ConfigMap, no MinIO, no OPAL client), which `../../demo/run-demo.sh` applies
for you. Walkthrough: `../../docs/LOCAL-DEPLOYMENT.md` step 5.

## Why a DaemonSet behind a node-local ClusterIP Service

Every node runs exactly one OPA (+ OPAL client) pod, and the Service carries
`internalTrafficPolicy: Local`, so kube-proxy sends each Envoy sidecar to the
OPA pod on its own node — the PDP call never leaves the node. That is the
point of running a PDP per node at all; a plain round-robin ClusterIP would
put an inter-node hop inside every authorization check.

`opa-policies/envoy/ext-authz.yaml` sketches the other way to get node-local
routing — Envoy dialling `$(HOST_IP):9191` through a Downward-API env var,
bypassing the Service entirely. It is not used: the base chart never injects
`HOST_IP`, and `internalTrafficPolicy` achieves the same placement with no
chart changes and no second address format to keep in sync.

The cost is the loss of cross-node fallback. A node whose OPA pod is unready
has no endpoint behind the Service, and `failure_mode_allow: false` makes
that a 403 on every request on that node. Planned rollouts are covered —
`daemonset.yaml` uses `maxSurge: 1` / `maxUnavailable: 0`, so the new pod
passes its readiness probe before the old one goes away. An unplanned crash
is a node-local outage until the pod restarts; that is the deliberate price
of node-local routing, and the reason the readiness probe checks
`/health?bundles=true` rather than bare liveness.
