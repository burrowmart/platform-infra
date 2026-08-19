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
| `minio.yaml` | **Demo-only.** Local S3 stand-in so `kind` can exercise the real `services.s3` / SigV4-signing code path without a real AWS account. Not part of the production path — real S3 needs no in-cluster resource. |

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

See `../../../demo/run-demo.sh` for the scripted version, including where
`OPA_BUNDLE_S3_URL` and the MinIO/OPAL secrets come from.

## Why a DaemonSet load-balanced by a plain ClusterIP Service

Every node runs exactly one OPA (+ OPAL client) pod, and the Service
round-robins across all of them — any Envoy sidecar on any node can reach
any OPA replica. `opa-policies/envoy/ext-authz.yaml`'s comment mentions a
node-local-only alternative (Downward API `HOST_IP` + `internalTrafficPolicy:
Local`); not needed at this deployment's scale, and the extra hop through
the Service is negligible next to the 0.5s ext_authz timeout already budgeted
in every service's Envoy config.
