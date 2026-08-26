# platform-infra/terraform/platform — phase 2

Terraform for everything that sits *around* the cluster: the Cloudflare
Tunnel that's the cluster's only inbound path, the internal ingress
controller behind it, CI's AWS identity, IRSA roles, the per-service secret
entries, and the OPA bundle bucket.

**The cluster itself is created by [`../cluster`](../cluster)** — a
single-node k3s box on a spot EC2 instance. Apply that root first; this one
reads its state ([data.tf](data.tf)) for the kubeconfig parameter, the OIDC
provider and the node's instance id. See [`../README.md`](../README.md) for
why the split is mandatory and what it costs to run.

Reaching the API server needs the SSM port-forward open — `make tunnel` from
`../`, or just use `make platform-apply`, which opens it for you.

## The invariant

> **The Cloudflare Tunnel is the only path into the cluster.**

No `LoadBalancer` Service, no `NodePort` Service, no `aws_lb`/ALB/NLB, no
public listener anywhere in this tree. `cloudflared` (3 replicas, namespace
`cloudflared`) dials **out** to the Cloudflare edge; it has no
`kubernetes_service` in front of it because there is nothing to expose —
inbound traffic arrives at the edge, rides the tunnel in, and lands on the
internal nginx ingress controller's `ClusterIP` Service
(`ingress-nginx-internal.ingress.svc`). Every other Service in the cluster
(created by each service's own Helm chart, outside this repo) is
`ClusterIP`-only and reachable only through that ingress.

Grep-provable — see [Verification](#verification) below.

## Module map

| Module | Creates | ARCHITECTURE.md section |
|---|---|---|
| [`modules/internal-ingress`](modules/internal-ingress) | ingress-nginx via `helm_release`, `ClusterIP` controller Service named `ingress-nginx-internal` in namespace `ingress`, `IngressClass` `nginx-internal` | Private networking |
| [`modules/cloudflare-tunnel`](modules/cloudflare-tunnel) | `cloudflare_zero_trust_tunnel_cloudflared`, one DNS CNAME per public hostname, and the k8s side: namespace `cloudflared`, credentials Secret, config ConfigMap (`localConfig.ingress`), Deployment (3 replicas, outbound-only, no Service) | Private networking |
| [`../modules/github-oidc`](../modules/github-oidc) | GitHub Actions OIDC provider + one assume-role per repo pattern (`repo:{owner}/*:ref:refs/heads/main`), scoped to `ssm:GetParameter` on the kubeconfig parameter and `ssm:StartSession` with `AWS-StartPortForwardingSession` on the one node. No ECR permissions — images are on ghcr.io. | Secrets & CI auth |
| [`../modules/irsa`](../modules/irsa) | Reusable: one IAM role per service, trust-scoped to that service's `namespace`/`ServiceAccount` via the cluster's OIDC provider, with a read policy scoped to `{prefix}/{service}/*` in whichever backend `secrets_backend` selects | Secrets & CI auth |
| [`../modules/secrets`](../modules/secrets) | Per-service entries — `mongo-uri`, `rabbit-url`, `redis-url`, `cognito-issuer`, `cognito-audience` — in SSM Parameter Store (default, free) or Secrets Manager; values sourced from a sensitive variable, never a literal in `.tf` source | Secrets & CI auth |
| [`../modules/opa-bundle-bucket`](../modules/opa-bundle-bucket) | Versioned, private S3 bucket for OPA bundles; a write-only role for the `opa-policies` repo's CI (GitHub OIDC); a read-only role for the OPA PDP DaemonSet (IRSA) | Auth & Authz (OPA bundle source) |

The cluster's IAM OIDC identity provider — the prerequisite for IRSA — is
created in [`../cluster/oidc.tf`](../cluster/oidc.tf), because on k3s it has
to be registered against the API server's own service-account signing key.

## Plan / apply

```bash
cd platform-infra/terraform/platform
terraform init

cp terraform.tfvars.example terraform.tfvars   # then fill it in
export TF_VAR_cloudflare_api_token="..."       # never in a tfvars file
# real secret values (mongo/rabbit/redis URIs, Cognito issuer/audience) go
# in a gitignored secrets.auto.tfvars or TF_VAR_secret_values — see the
# comment at the bottom of terraform.tfvars.example

(cd .. && make tunnel)                         # SSM port-forward to :6443

terraform plan  -out=tfplan
terraform apply tfplan
```

Requires:
- `../cluster` already applied
- AWS credentials for `aws_account_id`, sufficient for IAM, S3, SSM and
  (if `secrets_backend = "secretsmanager"`) Secrets Manager
- An open SSM port-forward to the cluster API server — `make tunnel`
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  installed locally (`brew install --cask session-manager-plugin`)
- A Cloudflare API token scoped to `Tunnel:Edit` + `DNS:Edit` on the zone
  in `cloudflare_zone_id`

### Required variables with no default

`aws_region`, `aws_account_id`, `cloudflare_account_id`,
`cloudflare_api_token`, `cloudflare_zone_id`, `github_owner`,
`opa_bundle_bucket_name`. Everything else has a default matching the system
map in the top-level `platform-infra/README.md` — override what differs for
your environment. Full list with descriptions: [variables.tf](variables.tf).

## Verification

```bash
terraform init -backend=false
terraform validate
terraform plan -var-file=terraform.tfvars.example   # or your real tfvars
```

`init` and `validate` need no credentials and are the two gates that run
anywhere, including this repo's CI. `plan` additionally needs live AWS
credentials (for the kubeconfig parameter read and every resource's
provider), an open SSM tunnel, and a reachable Cloudflare account — it cannot complete against
placeholder credentials, since a data source read is a real API call, not
something Terraform can fake locally. What `validate` guarantees regardless:
every reference, type, `for_each`, and provider config in the tree is
internally consistent.

Grep for the invariants — all four should return **no matches** anywhere
under this directory:

```bash
grep -rn "LoadBalancer"        --include='*.tf' .
grep -rn "NodePort"            --include='*.tf' .
grep -rn "aws_lb"              --include='*.tf' .
grep -rEn "AKIA[0-9A-Z]{16}"   --include='*.tf' .   # static AWS access keys
```

## Design notes

- **No `aws_caller_identity`/`aws_region` data sources.** `aws_account_id`
  and `aws_region` are required input variables instead, so an `apply`
  against the wrong account fails at variable validation, not partway
  through a diff.
- **`thumbprint_list` is omitted** on every
  `aws_iam_openid_connect_provider` in the tree (GitHub's here, the
  cluster's in `../cluster`). Since AWS provider ~5.10 it's
  optional+computed — the provider derives and keeps it current itself,
  which matters because these upstream TLS chains do rotate.
- **State contains secret values in plaintext** (`modules/secrets`) — an
  inherent Terraform limitation, not something this tree works around. Use
  an encrypted remote backend with restricted read access; don't rely on
  `sensitive = true` for anything beyond keeping values out of CLI output.
- **The CI deploy role is Kubernetes cluster-admin**, and that is a real
  downgrade from the EKS setup this replaced. There, `AmazonEKSEditPolicy`
  scoped CI below RBAC and node-level changes. k3s has no equivalent
  IAM-to-RBAC bridge, so CI authenticates with the cluster's admin client
  certificate out of SSM. IAM still scopes *which* principal can fetch that
  certificate and which single instance it may tunnel to. Tightening this
  would mean issuing a per-repo client cert and a matching `Role`/
  `RoleBinding` — worth doing before anything but a demo runs here.
- **`secrets_backend` defaults to `"ssm"`, not Secrets Manager.** Secrets
  Manager bills $0.40 per secret per month and this tree creates 60 of them
  (5 keys x 12 services) — about $24/month, more than the cluster node
  costs. SSM Parameter Store Standard tier is free and External Secrets
  Operator reads it natively.
