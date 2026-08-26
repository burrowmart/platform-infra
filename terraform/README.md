# platform-infra/terraform

Two Terraform roots that stand up the archtenet demo cluster and everything
around it. This replaces the `eksctl create cluster` step entirely — there is
no eksctl anywhere in this repo, and no EKS.

```
cluster/    single-node k3s on a spot EC2 instance, plus the S3 OIDC
            discovery bucket that makes IRSA work without EKS
platform/   ingress-nginx, the Cloudflare Tunnel, IRSA roles, service
            secrets, the OPA bundle bucket
modules/    shared modules, used by platform/
```

**Перший раз?** Не починай звідси. Порядок:
[docs/LOCAL-DEPLOYMENT.md](../docs/LOCAL-DEPLOYMENT.md) (Kubernetes на
ноутбуці, $0) → [docs/AWS-GETTING-STARTED.md](../docs/AWS-GETTING-STARTED.md)
(акаунт AWS і цей кластер, покроково) →
[docs/AWS-DEPLOYMENT.md](../docs/AWS-DEPLOYMENT.md) (решта платформи).
Нижче — короткий варіант для тих, хто вже знає, що робить.

```bash
cp cluster/terraform.tfvars.example  cluster/terraform.tfvars    # fill in
cp platform/terraform.tfvars.example platform/terraform.tfvars   # fill in
export TF_VAR_cloudflare_api_token="..."

make cluster-init platform-init
make up            # cluster, then platform
make help          # everything else
```

## Why two roots

The `kubernetes` and `helm` providers in `platform/` are configured from the
cluster's kubeconfig. Terraform must be able to configure a provider *before*
it can plan the resources that use it, so a provider config that depends on a
resource created in the same apply fails with "configuration depends on values
that cannot be determined until apply". Creating the cluster and installing
into it are therefore two applies, in order. `make up` runs both.

`cluster/` blocks until the node has finished bootstrapping and published its
kubeconfig, so `platform/` never runs against a cluster that isn't there yet.

## What it costs

The command this replaced —

```
eksctl create cluster --node-type t3.medium --nodes 2 --node-private-networking
```

— bills roughly **$165/month**: $73 for the EKS control plane (fixed, no free
tier, cannot be switched off), ~$33 for the NAT Gateway that
`--node-private-networking` forces, ~$60 for two on-demand t3.medium nodes.

What's here instead, running 24/7 in eu-central-1:

| | |
|---|---:|
| t3.large **spot** (8 GiB) | ~$18 |
| Elastic IP | ~$3.60 |
| 40 GiB gp3 root volume | ~$3.20 |
| VPC, S3 OIDC bucket, SSM Parameter Store, IAM | ~$0 |
| **Total** | **~$25/month** |

`make stop` between demos drops that to the EBS volume and the Elastic IP —
**~$7/month** — with every workload, PVC and image intact on restart.
`t3.medium` instead of `t3.large` roughly halves the compute line, but only if
you run one replica per service and skip the observability stack.

Three cost decisions are worth naming, because each was a real line item:

- **No NAT Gateway.** The node sits in a public subnet with an Elastic IP.
  That is not a security regression here: the security group has *zero*
  inbound rules, every Service is `ClusterIP`, and traffic arrives through
  the Cloudflare Tunnel's outbound-only connection. A NAT Gateway would have
  bought nothing but a bill.
- **SSM Parameter Store, not Secrets Manager** (`secrets_backend` in
  `platform/`). Secrets Manager is $0.40 per secret per month; this tree
  creates 5 keys x 12 services = 60 secrets, so ~$24/month — more than the
  cluster. Parameter Store Standard tier is free and External Secrets
  Operator reads it natively.
- **Spot with `interruption_behavior = "stop"`, persistent request.** When
  AWS reclaims capacity it stops the node instead of terminating it, and
  starts it again when capacity returns. The EBS root volume — and therefore
  the whole cluster — survives. A `terminate` behaviour would wipe it.

  The cost of that choice: a *persistent* request is the only kind AWS lets
  you pair with `stop`, and a persistent request that outlives its instance
  relaunches one. `make down` runs `make check-orphans` afterwards to list
  any request still `open`/`active`, so a destroyed cluster cannot quietly
  start billing again. Run `make check-orphans` yourself if you ever destroy
  by hand. Set `use_spot = false` to avoid the whole question at ~3x the
  compute cost.

## What changed versus the EKS design, and what didn't

**Unchanged.** The Cloudflare Tunnel is still the only inbound path. Every
Service is still `ClusterIP`. IRSA still works, per service, with no static
AWS credentials anywhere — `modules/irsa` is byte-for-byte the same module it
was on EKS. Helm charts, the OPA PDP, the Envoy PEP sidecars, and the reusable
CI workflow all keep their shape.

**IRSA without EKS.** EKS's whole IRSA mechanism rests on it publishing an
OIDC discovery endpoint for the API server's service-account signing key. k3s
has the same key and publishes nothing, so `cluster/` publishes it: the API
server is started with `service-account-issuer` pointing at a public S3
bucket, and the bootstrap script copies the API server's own JWKS
(`kubectl get --raw /openid/v1/jwks`) into it. STS cannot tell the difference.
The bucket is public on purpose — it holds a public key and nothing else.

There is no EKS pod-identity webhook to inject `AWS_ROLE_ARN` and the
projected token, so the `base-service` Helm chart does that itself whenever
`irsaRoleArn` is set. Service code is untouched: the AWS SDK's default
credential chain picks the env vars up exactly as it did on EKS.

**API access moved to an SSM tunnel.** No `aws eks update-kubeconfig`, and no
inbound rule on 6443. The kubeconfig lives in an SSM `SecureString`; humans
and CI both fetch it and open an `AWS-StartPortForwardingSession` to the node.
`make tunnel` does this locally; the deploy job in
`.github/workflows/service-ci.yml` does it on the runner.

**Honest downgrades.** These are real, and worth knowing before this pattern
goes anywhere near production:

- One node, no HA. The control plane, every workload, and all PVC data are on
  a single spot instance. A spot reclaim is a full outage until AWS returns
  capacity; a disk failure is total data loss.
- The CI deploy role authenticates as k3s cluster-admin. EKS access policies
  gave finer-grained scoping (`AmazonEKSEditPolicy`) that k3s has no
  equivalent for. IAM still constrains which principal can fetch the
  credential and which one instance it can tunnel to.
- `HorizontalPodAutoscaler` and `PodDisruptionBudget` resources still render,
  but mean very little on a single node.

## Prerequisites

- Terraform >= 1.6
- AWS credentials for the target account
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html):
  `brew install --cask session-manager-plugin`
- A Cloudflare API token with `Tunnel:Edit` + `DNS:Edit` on the target zone

## Verifying the invariants

All of these should return **no matches**:

```bash
grep -rn "LoadBalancer"      --include='*.tf' .
grep -rn "NodePort"          --include='*.tf' .
grep -rn "aws_lb"            --include='*.tf' .
grep -rEn "AKIA[0-9A-Z]{16}" --include='*.tf' .
```

And the one inbound rule that could exist should not:

```bash
cd cluster && terraform output -json 2>/dev/null
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=archtenet-demo-node" \
  --query 'SecurityGroups[0].IpPermissions'   # => []
```
