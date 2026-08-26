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

## Why a DaemonSet load-balanced by a plain ClusterIP Service

Every node runs exactly one OPA (+ OPAL client) pod, and the Service
round-robins across all of them — any Envoy sidecar on any node can reach
any OPA replica. `opa-policies/envoy/ext-authz.yaml`'s comment mentions a
node-local-only alternative (Downward API `HOST_IP` + `internalTrafficPolicy:
Local`); not needed at this deployment's scale, and the extra hop through
the Service is negligible next to the 0.5s ext_authz timeout already budgeted
in every service's Envoy config.
