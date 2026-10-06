# platform-infra/demo

Everything needed to run the platform on a laptop `kind` cluster. This is the
**only** local path — there is no second one.

Walkthrough: [`../docs/LOCAL-DEPLOYMENT.md`](../docs/LOCAL-DEPLOYMENT.md).
Run it all at once: `./run-demo.sh`.

| File | What |
|---|---|
| `kind-config.yaml` | Cluster definition — `kind create cluster --config`. Maps host 8081 to the node's port 80 and labels the node `ingress-ready`; **neither can be added to a running cluster** |
| `ingress-nginx-values.yaml` | The ingress controller that owns the `nginx-internal` class, matching `../terraform/modules/internal-ingress` |
| `data-namespace.yaml` | Redis + RabbitMQ in namespace `data`. Also carries the `rabbitmq_prometheus` + per-object-metrics patch that `../k8s/observability/` refers to |
| `mongo-in-cluster.yaml` | **Optional.** MongoDB as a single-node replica set, for working without Atlas |
| `platform-secret.yaml` | `REDIS_URL` / `RABBITMQ_URL` — the local stand-in for what External Secrets Operator syncs out of AWS |
| `opa-stack.sh` | The full authorization stack, from the real manifests in `../k8s/opa` and `../k8s/opal`: MinIO (S3 stand-in) with the bundle uploaded into it, the OPA DaemonSet (`opa` + `opal-client`), the OPAL server, and the RabbitMQ→OPAL fetcher. Local glue only: quickstart MinIO creds, demo-signed JWTs, `kind load` |
| `values-local.yaml` | Helm overlay applied to every service chart. Switches off what a laptop cannot provide (ESO, IRSA, ingress, HPA/PDB) and nothing else |
| `run-demo.sh` | base chart → ingress → data stores → secret → OPA/OPAL stack → build/load/install every service |

`../scripts/vendor-base-chart.sh` packages `../helm/base-service` into every
service's gitignored `helm/charts/`. Helm resolves dependencies at *package*
time, not install time, so this must run after any edit to the base chart —
`run-demo.sh` does it for you.

## MongoDB

Atlas M0 is the recommended path, locally as well as in AWS: free, a real
replica set (the outbox's change-stream watcher requires one), and one fewer
difference between environments. `mongo-in-cluster.yaml` exists for working
offline and costs about 1 GB of Docker's memory.

## What this deliberately does not run

- **Cloudflare Tunnel.** ingress-nginx *does* run here, with the same
  IngressClass and the same annotations as AWS — what is missing is only the
  tunnel in front of it. In AWS `cloudflared` dials out and forwards to the
  controller's ClusterIP Service; locally the controller binds the node's
  port 80 and you reach it on `localhost:8081` with a `Host:` header.
- **Cognito.** `AUTH_DISABLED=true` in the app container — but authorization
  is still enforced, by Envoy + OPA, against JWTs minted with
  `../../opa-policies/demo/mint-token.js`.

Every one of those is off because a laptop cannot provide it, not because it
is optional in a deployed environment.
