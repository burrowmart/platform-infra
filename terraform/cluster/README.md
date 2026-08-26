# platform-infra/terraform/cluster — phase 1

Creates the demo cluster: one k3s server on a spot EC2 instance, plus the S3
bucket that publishes its OIDC discovery documents so IRSA works without EKS.

Apply this before [`../platform`](../platform). Cost breakdown, design
rationale, and the honest list of what a single-node cluster gives up are in
[`../README.md`](../README.md).

```bash
cp terraform.tfvars.example terraform.tfvars   # then fill it in
terraform init
terraform apply        # ~5 min; blocks until the API server is up
```

## What gets created

| File | Creates |
|---|---|
| [network.tf](network.tf) | VPC, one public subnet, IGW, Elastic IP, and a security group with **zero inbound rules** |
| [k3s.tf](k3s.tf) | The spot instance, its bootstrap user-data, and a wait that blocks until the kubeconfig lands in SSM |
| [oidc.tf](oidc.tf) | Public S3 discovery bucket + the IAM OIDC provider registered against it |
| [iam.tf](iam.tf) | Node instance role: Session Manager, plus write access to exactly one S3 prefix and one SSM parameter |
| [templates/user-data.sh.tftpl](templates/user-data.sh.tftpl) | The bootstrap itself |

## How the node is reached

Nothing dials in. The security group allows no ingress at all; the node's SSM
agent dials Systems Manager outbound, and `kubectl`/`helm`/Terraform ride a
Session Manager port-forward to `127.0.0.1:6443`:

```bash
make tunnel      # from ../
make kubeconfig  # writes ./kubeconfig (gitignored)
export KUBECONFIG=$PWD/../kubeconfig
kubectl get nodes
```

`make shell` opens a root shell on the node the same way; `make logs` tails
`/var/log/k3s-bootstrap.log`, which is the first place to look if
`terraform apply` times out waiting for bootstrap.

`api_allowed_cidrs` is the deliberate escape hatch — set it to open 6443
directly and skip the tunnel. It is empty by default, and populating it is the
only way this cluster gets a public inbound port.

## Bootstrap, step by step

1. Install k3s, pinned to `k3s_version`, with `traefik` and `servicelb`
   disabled — ingress-nginx is what the Cloudflare Tunnel forwards to, and
   nothing in this architecture may be a `LoadBalancer` Service.
   `local-path-provisioner` and `metrics-server` stay: PVCs and the charts'
   HPAs need them.
2. Start the API server with `service-account-issuer` pointed at the S3
   discovery bucket, then **verify the issuer actually took**. k3s defaults
   that flag to `https://kubernetes.default.svc.cluster.local` and the
   override depends on its extra-arg merge; if that ever stops working,
   tokens would be signed with the wrong `iss` and every IRSA `AssumeRole`
   would fail hours later with an opaque STS error. The script fails at boot
   instead.
3. Publish `/.well-known/openid-configuration` and the API server's own JWKS
   to the bucket.
4. Write the kubeconfig to SSM as a `SecureString`, left pointing at
   `https://127.0.0.1:6443` — the correct address on the client side of the
   port-forward.

## Cost knobs

`instance_type` (default `t3.large`), `use_spot` (default `true`),
`root_volume_size` (default 40 GiB). Between demos, `make stop` /
`make start` from `../` keeps all state and stops the compute charge.

Stay on x86 (`t3.*`). Graviton (`t4g.*`) is ~15% cheaper but the service CI
builds `linux/amd64` images only — switching means adding
`platforms: linux/amd64,linux/arm64` to the `docker/build-push-action` step
in every service first.
