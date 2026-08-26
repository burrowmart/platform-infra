# Інструкція 2б. Деплой в AWS

Перший крок — [LOCAL-DEPLOYMENT.md](LOCAL-DEPLOYMENT.md), **зроби його
раніше.** Акаунт AWS і сам кластер — [AWS-GETTING-STARTED.md](AWS-GETTING-STARTED.md);
секція 1 нижче це його стисла версія. Тут той самий Helm і ті самі команди `kubectl`, але
додається все хмарне: кластер, IAM, секрети, авторизація, публічний домен.
Якщо Kubernetes-частина ще не звична, тут буде неможливо зрозуміти, що саме
зламалось.

Час: ~3–4 години першого разу.

> Далі текст англійською — це робочий runbook проєкту. Порядок кроків і
> команди ті самі, що в українській локальній інструкції.

**Demo-grade choices made in this guide** (documented so nobody mistakes them for production):
- **MongoDB Atlas M0 (free tier)** — a real replica set (change streams work) with zero ops. Production: bigger Atlas tier or self-managed.
- **Redis and RabbitMQ in-cluster** via Bitnami Helm charts. Production: ElastiCache / Amazon MQ.
- **Single-node k3s on a spot EC2 instance**, not EKS — see [terraform/README.md](../terraform/README.md) for the cost breakdown and the honest list of what that gives up.
- Cost: roughly **$25/month** running 24/7, **~$7/month** with the node stopped. `make stop` between demos (section 12).

---

## 0. Prerequisites

Accounts: AWS, Cloudflare (with your domain added, e.g. `demo.archtenet.dev` zone), MongoDB Atlas, GitHub org (`burrowmart`) with all repos pushed.

CLI tools — verify each:

```bash
aws --version && aws sts get-caller-identity   # must print your account id
terraform -version                              # >= 1.6
kubectl version --client
helm version
session-manager-plugin --version                # brew install --cask session-manager-plugin
```

No eksctl: the cluster is created by Terraform.

If `aws sts get-caller-identity` fails, you have no AWS credentials yet — do steps 1–3 of
[AWS-GETTING-STARTED.md](AWS-GETTING-STARTED.md) first, then come back.

Set your region once (must match `terraform.tfvars`):

```bash
export AWS_REGION=eu-central-1
```

---

## 1. Create the cluster

Terraform, in two phases. Phase 1 is the cluster itself; phase 2 is everything around it (section 4).

```bash
cd platform-infra/terraform/cluster
cp terraform.tfvars.example terraform.tfvars   # fill aws_region + aws_account_id
terraform init
terraform apply                                 # ~5–8 min
```

Full step-by-step for a first-timer, including the AWS account and IAM setup:
[AWS-GETTING-STARTED.md](AWS-GETTING-STARTED.md).

Then verify. The API server has **no inbound security-group rule** — you reach it through an SSM port-forward:

```bash
cd ..              # platform-infra/terraform
make tunnel        # opens 127.0.0.1:6443, leave it running
make kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
# Expected: 1 node, STATUS Ready
```

> You now have two clusters in `kubectl`: the local kind one and this. Check which you are pointed at with `kubectl config current-context` before every destructive command.

> IRSA (pod → AWS permissions) works here without EKS: the cluster publishes its service-account signing key to a public S3 discovery bucket, and an IAM OIDC provider is registered against it. See [terraform/cluster/README.md](../terraform/cluster/README.md).

---

## 2. Create external data stores

### 2.1 MongoDB Atlas (free M0)

1. Atlas → Build a Database → **M0 Free** → provider AWS, region = `$AWS_REGION`.
2. Database Access → add user `platform` with a strong password → role Read/Write any database.
3. Network Access → allow the cluster node's Elastic IP: `cd platform-infra/terraform/cluster && terraform output -raw node_public_ip`. *Avoid 0.0.0.0/0 even in a demo.* (You already added your laptop's IP for the local deployment — keep both.)
4. Copy the connection string (`mongodb+srv://platform:<pass>@...`). **You'll put it into Parameter Store in step 4 — don't put it in any file.**

### 2.2 Redis + RabbitMQ in the cluster

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install redis bitnami/redis -n data --create-namespace \
  --set architecture=standalone --set auth.enabled=true
helm install rabbitmq bitnami/rabbitmq -n data \
  --set auth.username=platform
kubectl get pods -n data
# Expected: redis-master-0 and rabbitmq-0 Running (wait 2–3 min)
```

Get the generated passwords (printed by helm notes, or):

```bash
kubectl get secret -n data redis -o jsonpath='{.data.redis-password}' | base64 -d; echo
kubectl get secret -n data rabbitmq -o jsonpath='{.data.rabbitmq-password}' | base64 -d; echo
```

In-cluster URLs (used in step 4): `redis://:<pass>@redis-master.data.svc:6379`, `amqp://platform:<pass>@rabbitmq.data.svc:5672`.

---

## 3. Create Cognito (identity)

AWS Console → Cognito → Create user pool:

1. Sign-in with **email**. Defaults elsewhere are fine for the demo.
2. App client: type "Public", no client secret, enable Authorization Code flow, scopes `openid email profile`. Callback URL: `https://app.<your-zone>/callback` (the Cloudflare OAuth worker's URL — the worker is deployed separately, see its own repo/prompt).
3. Write down: **User pool ID** (`eu-west-1_XXXX`), **Client ID**, and the issuer URL `https://cognito-idp.$AWS_REGION.amazonaws.com/<pool-id>`.
4. Create one test user (email + password).

The services only need `issuer` + `audience(client id)` to validate JWTs — they go into Parameter Store next.

---

## 4. Terraform phase 2: everything around the cluster

The SSM tunnel from section 1 must be open — this root talks to the Kubernetes API through it.

```bash
cd platform-infra/terraform/platform
cp terraform.tfvars.example terraform.tfvars
```

Fill `terraform.tfvars` — every variable, no blanks:

```hcl
aws_region             = "eu-central-1"   # same as the cluster root
aws_account_id         = "111122223333"
cloudflare_account_id  = "..."
cloudflare_zone_id     = "..."
base_domain            = "internal.archtenet.dev"
github_owner           = "burrowmart"
opa_bundle_bucket_name = "burrowmart-opa-bundles-111122223333"
secrets_backend        = "ssm"            # free; "secretsmanager" is ~$24/month here
```

The Cloudflare token never goes in a file:

```bash
export TF_VAR_cloudflare_api_token="..."   # Cloudflare → My Profile → API Tokens → Zone.DNS + Cloudflare Tunnel edit
```

Apply:

```bash
terraform init
terraform plan     # read it once: tunnel, cloudflared, ingress-nginx (ClusterIP), IAM roles, S3, parameter entries
terraform apply    # type yes
```

**Save the outputs** — you need them in later steps:

```bash
terraform output
# github_deploy_role_arns   = { "burrowmart/*" = "arn:aws:iam::...:role/github-oidc-deploy-..." }
# github_actions_variables  = { AWS_REGION = ..., KUBECONFIG_PARAM = ..., K3S_INSTANCE_ID = ... }
# irsa_role_arns            = { user-service = ..., ... }
# opa_bundle_bucket_name    = ...
```

**Now fill the secret VALUES.** Terraform created one entry per key with a `CHANGEME` placeholder; values never live in git. With the default `secrets_backend = "ssm"` these are SSM parameters at `/svc/<service>/<key>`:

```bash
COGNITO_ISSUER="https://cognito-idp.$AWS_REGION.amazonaws.com/<pool-id>"
COGNITO_AUDIENCE="<app client id>"
REDIS_URL="redis://:<pass>@redis-master.data.svc:6379"
RABBITMQ_URL="amqp://platform:<pass>@rabbitmq.data.svc:5672"
ATLAS_BASE="mongodb+srv://platform:<pass>@cluster0.xxxxx.mongodb.net"   # no trailing db name

for svc in user-service catalog-service order-service payment-service notification-service chat-service ws-gateway cart-bff user-bff catalog-bff order-bff payment-bff; do
  put() { aws ssm put-parameter --name "/svc/$svc/$1" --value "$2" --type SecureString --overwrite >/dev/null; }
  put mongo-uri        "$ATLAS_BASE/$svc?retryWrites=true&w=majority"
  put redis-url        "$REDIS_URL"
  put rabbit-url       "$RABBITMQ_URL"
  put cognito-issuer   "$COGNITO_ISSUER"
  put cognito-audience "$COGNITO_AUDIENCE"
done
```

> Same shape as the local `platform-local` Secret from instruction 1 — one database per service, identical env var names. Only the source changed.

---

## 5. Install External Secrets Operator

The Helm charts create `ExternalSecret` resources; without the operator they do nothing.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
kubectl get pods -n external-secrets
# Expected: 3 pods Running
```

Apply the ClusterSecretStore. It must point at the same backend `secrets_backend` selected — with the default `"ssm"` that is `service: ParameterStore`, and the store name must match `secretStoreName` in the charts (`aws-parameter-store`):

```bash
kubectl apply -f platform-infra/k8s/secret-store.yaml
kubectl get clustersecretstore
# Expected: STATUS Valid, READY True
```

If it reports an auth error, the store's ServiceAccount is missing its IRSA role annotation — cross-check against `terraform output irsa_role_arns`.

---

## 6. Deploy OPA (authorization)

Publish the policy bundle, then run the PDP:

```bash
cd opa-policies
make build
aws s3 cp dist/bundle.tar.gz s3://$(cd ../platform-infra/terraform/platform && terraform output -raw opa_bundle_bucket_name)/bundle.tar.gz

kubectl apply -f ../platform-infra/k8s/opa/
kubectl get pods -n opa
# Expected: one opa pod per node (DaemonSet), Running
kubectl logs -n opa ds/opa | grep -i bundle
# Expected: "Bundle loaded and activated successfully"
```

If the bundle fails to load → the OPA pod's IRSA role can't read the bucket; recheck terraform output vs the DaemonSet's ServiceAccount annotation.

---

## 7. Wire GitHub Actions (CI/CD)

In the GitHub **org** settings → Secrets and variables → Actions → Variables, create:

| Variable | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | from `terraform output github_deploy_role_arns` |
| `AWS_REGION` | from `terraform output github_actions_variables` |
| `KUBECONFIG_PARAM` | from `terraform output github_actions_variables` |
| `K3S_INSTANCE_ID` | from `terraform output github_actions_variables` |

No AWS keys anywhere — the workflow logs in via OIDC using that role. That's the whole point.

The deploy job reads the kubeconfig from SSM and opens the same Session Manager port-forward you use locally, so CI needs no inbound rule on the cluster either.

---

## 8. Deploy the services (in this order)

Order matters: contracts is a dependency, user-service proves the pipeline, then everything else.

1. **contracts** — push to `main`, check the Actions tab: green.
2. **user-service** — push to `main`. The pipeline runs lint → test → build → push image to ghcr.io → scan → helm deploy. First run takes ~10 min.

   ```bash
   kubectl get pods -n services -l app=user-service
   # Expected: 2/2 Running  ← TWO containers per pod: app + envoy-pep. 1/2 = Envoy can't reach OPA.
   # (Locally this was 1/1: the PEP sidecar is disabled by values-local.yaml. Here it must be on.)
   kubectl get externalsecret -n services
   # Expected: SecretSynced True
   ```

   **Do not continue until user-service is 2/2 Running.** Every other service fails the same way if this one does.
3. Push the rest: catalog, payment, order, notification, chat, ws-gateway, then the BFFs. Same check for each.

Common first-deploy failures:

| Pod state | Meaning | Fix |
|---|---|---|
| `ImagePullBackOff` | ghcr package is private | GitHub → package settings → make public (demo) |
| `CreateContainerConfigError` | secret not synced | `kubectl describe externalsecret` — usually a typo in the `/svc/<service>/` parameter path, or a ClusterSecretStore pointing at the wrong backend |
| App container `CrashLoopBackOff` | bad MONGO_URI / Atlas network access | `kubectl logs <pod> -c app` — read the first error |
| `1/2 Running` | Envoy sidecar can't reach OPA | is the OPA DaemonSet up (step 6)? |

---

## 9. Verify the tunnel (the only door in)

```bash
kubectl get pods -n cloudflared
# Expected: 3 pods Running
kubectl logs -n cloudflared deploy/cloudflared | grep -i "registered"
# Expected: connections registered to Cloudflare edge

# THE key invariant of this architecture — prove there is no public inbound:
kubectl get svc -A | grep -E "LoadBalancer|NodePort"
# Expected: EMPTY output. Any line here = architecture violation, find and delete it.
```

Then from your laptop:

```bash
curl -s https://demo.archtenet.dev/users/health
# Expected: a JSON health response, served through Cloudflare → tunnel → internal ingress
```

If it 404s: check the tunnel's ingress rules (terraform module) map your hostname to `ingress-nginx-internal`. If it times out: cloudflared logs.

---

## 10. Smoke test in the cloud

Get a real token for your Cognito test user (Hosted UI login, or for CLI):

```bash
aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH \
  --client-id <client-id> \
  --auth-parameters USERNAME=<email>,PASSWORD=<password> \
  --query 'AuthenticationResult.IdToken' --output text
export TOKEN=<paste it>
```

Repeat the core scenarios from `MANUAL-TESTING.md` against the public hostname, with real auth (`-H "Authorization: Bearer $TOKEN"` instead of `x-debug-user`): create catalog item → cart → checkout → order CONFIRMED → notification unread-count = 1. If auth returns 403 on a valid token — that's OPA denying: check the user's attributes in user-service and the OPA decision logs (`kubectl logs -n opa ds/opa`).

---

## 11. Run the acceptance harness

```bash
cd platform-infra/acceptance
npm ci && npm run acceptance -- --target=cloud
# Expected final line: 6/6 PASS
```

This writes `ACCEPTANCE.md`. It is gitignored — regenerate it when you need the evidence rather than committing a snapshot that goes stale the moment the code changes.

---

## 12. Tear down (do this after every demo)

Between demos — keeps everything, drops the bill to ~$7/month:

```bash
cd platform-infra/terraform && make stop
# make start brings it back with every workload intact (then: make tunnel)
```

Remove entirely:

```bash
cd platform-infra/terraform && make down
# runs `make check-orphans` afterwards: anything it lists is still billing —
# a persistent spot request that outlives its instance relaunches one.
# Atlas M0 is free — pause or keep it.
```

---

## Deployment order — one-page checklist

```
[ ] 0. Local deployment done first (docs/LOCAL-DEPLOYMENT.md)
[ ] 1. terraform/cluster applied, `make tunnel`, node Ready
[ ] 2. Atlas M0 + in-cluster Redis/RabbitMQ, passwords saved
[ ] 3. Cognito pool + client + test user, issuer/audience saved
[ ] 4. terraform/platform applied, outputs saved, Parameter Store VALUES filled
[ ] 5. External Secrets Operator + ClusterSecretStore Valid
[ ] 6. OPA bundle in S3, DaemonSet Running, "bundle activated" in logs
[ ] 7. GitHub org variables (role ARN, region, KUBECONFIG_PARAM, K3S_INSTANCE_ID)
[ ] 8. Deploy: contracts → user-service (2/2 Running!) → all others
[ ] 9. Tunnel: 3 cloudflared pods, ZERO LoadBalancer/NodePort, curl via hostname works
[ ] 10. Smoke test with a real Cognito token
[ ] 11. Acceptance harness: 6/6 PASS
[ ] 12. make stop between demos; make down + check-orphans when finished
```
