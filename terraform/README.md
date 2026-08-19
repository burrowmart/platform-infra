# platform-infra/terraform

Terraform for everything that sits *around* the EKS cluster: the Cloudflare
Tunnel that's the cluster's only inbound path, the internal ingress
controller behind it, CI's AWS identity, IRSA roles, Secrets Manager
entries, and the OPA bundle bucket.

**The EKS cluster itself is not created here.** It's looked up by name
(`data "aws_eks_cluster" "this"` in [data.tf](data.tf)) and assumed to
already exist. Every resource in this tree wires *around* that cluster —
none of it provisions the cluster, its node groups, or its VPC.

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
| [`modules/github-oidc`](modules/github-oidc) | GitHub Actions OIDC provider + one assume-role per repo pattern (`repo:{owner}/*:ref:refs/heads/main`), `eks:DescribeCluster` only, an EKS access entry + `AmazonEKSEditPolicy` association for the actual kubectl/helm deploy permissions. No ECR permissions — images are on ghcr.io. | Secrets & CI auth |
| [`modules/irsa`](modules/irsa) | Reusable: one IAM role per service, trust-scoped to that service's `namespace`/`ServiceAccount` via the EKS cluster's own OIDC provider, with a Secrets Manager read policy scoped to `svc/{service}/*` | Secrets & CI auth |
| [`modules/secrets`](modules/secrets) | Secrets Manager entries per service — `mongo-uri`, `rabbit-url`, `redis-url`, `cognito-issuer`, `cognito-audience` — values sourced from a sensitive variable, never a literal in `.tf` source | Secrets & CI auth |
| [`modules/opa-bundle-bucket`](modules/opa-bundle-bucket) | Versioned, private S3 bucket for OPA bundles; a write-only role for the `opa-policies` repo's CI (GitHub OIDC); a read-only role for the OPA PDP DaemonSet (EKS IRSA) | Auth & Authz (OPA bundle source) |

Root [`main.tf`](main.tf) also creates the EKS cluster's IAM OIDC identity
provider (`aws_iam_openid_connect_provider.eks`) — a prerequisite for IRSA
that isn't part of "the cluster" itself, so it lives here rather than in the
cluster's own provisioning.

## Plan / apply

```bash
cd platform-infra/terraform
terraform init

cp terraform.tfvars.example terraform.tfvars   # then fill it in
export TF_VAR_cloudflare_api_token="..."       # never in a tfvars file
# real secret values (mongo/rabbit/redis URIs, Cognito issuer/audience) go
# in a gitignored secrets.auto.tfvars or TF_VAR_secret_values — see the
# comment at the bottom of terraform.tfvars.example

terraform plan  -out=tfplan
terraform apply tfplan
```

Requires:
- AWS credentials for `aws_account_id` (the deploy role or your own,
  sufficient for `eks:DescribeCluster`, IAM, S3, Secrets Manager)
- Network + auth access to the target EKS cluster's API server
- A Cloudflare API token scoped to `Tunnel:Edit` + `DNS:Edit` on the zone
  in `cloudflare_zone_id`

### Required variables with no default

`aws_region`, `aws_account_id`, `eks_cluster_name`, `cloudflare_account_id`,
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
credentials (for the `data "aws_eks_cluster"` lookup and every resource's
provider) and a reachable Cloudflare account — it cannot complete against
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
- **`thumbprint_list` is omitted** on both `aws_iam_openid_connect_provider`
  resources (GitHub's and the EKS cluster's). Since AWS provider ~5.10 it's
  optional+computed — the provider derives and keeps it current itself,
  which matters because these upstream TLS chains do rotate.
- **State contains secret values in plaintext** (`modules/secrets`) — an
  inherent Terraform limitation, not something this tree works around. Use
  an encrypted remote backend with restricted read access; don't rely on
  `sensitive = true` for anything beyond keeping values out of CLI output.
- **`AmazonEKSEditPolicy` is cluster-scoped, not namespace-scoped**, for the
  CI deploy role. Each service's CI creates its own namespace on first
  deploy (`helm upgrade --install --create-namespace`), which a
  namespace-scoped access entry can't pre-authorize. `Edit` (not `Admin`)
  still excludes RBAC and node-level changes.
