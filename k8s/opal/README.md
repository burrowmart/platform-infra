# platform-infra/k8s/opal

Runs the workloads described in `opa-policies/opal/README.md`. Namespace is
`opa-system` — same as `../opa`, since the OPAL server, the OPAL clients
(sidecars on the OPA DaemonSet), and the fetcher are one tightly-coupled unit.

| File | What |
|---|---|
| `opal-server-deployment.yaml` / `-service.yaml` | Single-replica OPAL server, data-plane only (no policy repo configured). `ClusterIP opal-server:7002`. |
| `fetcher-deployment.yaml` | `opa-policies/opal/fetcher` — consumes `user.attributes-changed`, pushes to the OPAL server. |

## Secrets this namespace expects

| Secret | Keys | Used by |
|---|---|---|
| `opal-server-secrets` | `master-token`, `data-config-sources` | `opal-server` (both), `opal-fetcher` (`master-token` only — it authenticates to `POST /data/config` the same way, per OPAL's own docs) |
| `opal-client-secrets` | `client-token` | `opal-client` sidecars in `../opa/daemonset.yaml` |

For the demo, `client-token` and `master-token` are set to the **same**
value — OPAL treats the master token as an all-access credential, so this is
a supported simplification, not a bug. A real deployment would mint scoped
per-peer tokens via OPAL's `POST /token` instead. See `../../demo/run-demo.sh` (which does NOT set this up — the local path in `../../docs/LOCAL-DEPLOYMENT.md` runs OPA without OPAL, on a static bundle)
for how these get created.
