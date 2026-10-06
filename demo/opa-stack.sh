#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploy the FULL authorization stack into the local kind cluster — the same
# pieces, the same manifests, and the same code paths as the cloud deploy:
#
#   MinIO (S3 stand-in)  <--SigV4 poll--  OPA DaemonSet (opa + opal-client)
#   OPAL server  --pubsub-->  opal-client  --PUT /v1/data-->  opa
#   RabbitMQ  -->  fetcher  --POST /data/config-->  OPAL server
#
# Manifests come straight from ../k8s/opa and ../k8s/opal — nothing here is a
# simplified local variant. The only local-specific parts are this script's
# glue: MinIO quickstart credentials, demo-signed JWTs, and `kind load`
# instead of a registry push. Moving to AWS replaces exactly that glue:
# real S3 + IRSA instead of MinIO + static creds, CI-pushed images instead of
# kind load, Cognito tokens instead of mint-token.js.
#
# Idempotent — re-run after a policy edit and the rebuilt bundle lands in
# MinIO, where OPA re-polls it within 10s. No pod restart needed for policy
# changes; that is the point of the S3 polling path.
#
# Expects: RabbitMQ from demo/data-namespace.yaml (the fetcher consumes it;
# without it the fetcher crash-loops until RabbitMQ appears — harmless but
# noisy). Called by run-demo.sh; runnable standalone.
#
# Walkthrough of every step: docs/LOCAL-DEPLOYMENT.md step 5.
# ---------------------------------------------------------------------------
set -euo pipefail

CLUSTER="${CLUSTER:-archtenet}"
# Namespace the services (and thus user-service, OPAL's data source) live in.
NAMESPACE="${NAMESPACE:-local}"

cd "$(dirname "$0")/../.."
ROOT="$PWD"
K8S="$ROOT/platform-infra/k8s"

echo "--- OPA stack: demo keys + policy bundle ----------------------"
# gen-keys BEFORE build (the public JWKS is packed inside the tarball) and
# BEFORE mint-token below (the service token must verify against that JWKS).
if [ ! -f "$ROOT/opa-policies/demo/.keys/private-key.pem" ]; then
  (cd "$ROOT/opa-policies" && node demo/gen-keys.js)
fi
(cd "$ROOT/opa-policies" && make build)

echo "--- OPA stack: namespace + S3 credentials ---------------------"
kubectl apply -f "$K8S/opa/namespace.yaml"
kubectl apply -f "$K8S/opa/serviceaccount.yaml"   # IRSA annotation is inert on kind
# MinIO's well-known quickstart root credentials — minio.yaml reads this same
# Secret as MINIO_ROOT_USER/PASSWORD, the OPA DaemonSet reads it as AWS_* env.
kubectl create secret generic opa-s3-credentials -n opa-system \
  --from-literal=access-key-id=minioadmin \
  --from-literal=secret-access-key=minioadmin \
  --dry-run=client -o yaml | kubectl apply -f -

echo "--- OPA stack: MinIO + bundle upload --------------------------"
kubectl apply -f "$K8S/opa/minio.yaml"
kubectl rollout status deployment/minio -n opa-system --timeout=180s
MINIO_POD=$(kubectl get pod -n opa-system -l app=minio \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
# kubectl cp needs tar inside the image and the MinIO image has none — stream
# over exec stdin instead, then shelve it into the bucket with the bundled mc.
kubectl exec -i -n opa-system "$MINIO_POD" -- sh -c 'cat > /tmp/bundle.tar.gz' \
  < "$ROOT/opa-policies/dist/bundle.tar.gz"
kubectl exec -n opa-system "$MINIO_POD" -- sh -c '
  mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null &&
  mc mb -p local/opa-bundles >/dev/null &&
  mc cp -q /tmp/bundle.tar.gz local/opa-bundles/bundle.tar.gz >/dev/null'

echo "--- OPA stack: OPAL secrets -----------------------------------"
# master-token: stable across re-runs so already-connected clients stay valid.
# client-token == master-token is the documented demo simplification
# (k8s/opal/README.md) — real deploys mint scoped tokens via POST /token.
MASTER_TOKEN=$(kubectl get secret opal-server-secrets -n opa-system \
  -o jsonpath='{.data.master-token}' 2>/dev/null | base64 -d || true)
[ -n "$MASTER_TOKEN" ] || MASTER_TOKEN=$(openssl rand -hex 24)

# The token OPAL clients present to user-service's GET /internal/attributes
# (initial sync + 300s drift correction). 30 days — see mint-token.js header.
SERVICE_TOKEN=$(cd "$ROOT/opa-policies" \
  && node demo/mint-token.js svc-opal-fetcher@archtenet.internal service 2592000 | tail -1)
# The template targets the deployed layout (user-service in its own
# namespace); locally every service lives in $NAMESPACE.
DATA_CONFIG=$(sed \
  -e "s|__SERVICE_TOKEN__|$SERVICE_TOKEN|" \
  -e "s|user-service\.user-service\.svc|user-service.$NAMESPACE.svc|" \
  "$ROOT/opa-policies/opal/data-config.template.json")

kubectl create secret generic opal-server-secrets -n opa-system \
  --from-literal=master-token="$MASTER_TOKEN" \
  --from-literal=data-config-sources="$DATA_CONFIG" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic opal-client-secrets -n opa-system \
  --from-literal=client-token="$MASTER_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "--- OPA stack: OPAL server ------------------------------------"
kubectl apply -f "$K8S/opal/opal-server-deployment.yaml"
kubectl apply -f "$K8S/opal/opal-server-service.yaml"
# Secrets land as env vars, so a re-rendered data-config needs a restart.
kubectl rollout restart deployment/opal-server -n opa-system
kubectl rollout status deployment/opal-server -n opa-system --timeout=180s

echo "--- OPA stack: OPA PDP DaemonSet ------------------------------"
sed "s|\${OPA_BUNDLE_S3_URL}|http://minio.opa-system.svc.cluster.local:9000/opa-bundles|" \
  "$K8S/opa/configmap.yaml.template" | kubectl apply -f -
kubectl apply -f "$K8S/opa/service.yaml"
kubectl apply -f "$K8S/opa/daemonset.yaml"
# Leftovers from the retired simplified path (a Deployment also named opa-pdp
# would match the Service selector alongside the DaemonSet).
kubectl delete deployment opa-pdp -n opa-system --ignore-not-found
kubectl delete configmap opa-bundle -n opa-system --ignore-not-found
kubectl rollout status daemonset/opa-pdp -n opa-system --timeout=180s

echo "--- OPA stack: RabbitMQ->OPAL fetcher -------------------------"
if ! kubectl get svc rabbitmq -n data >/dev/null 2>&1; then
  echo "!! rabbitmq.data not found — the fetcher will crash-loop until it exists"
  echo "!! (kubectl apply -f platform-infra/demo/data-namespace.yaml)"
fi
# Context is opa-policies/, not the fetcher dir — see the Dockerfile header.
docker build -f "$ROOT/opa-policies/opal/fetcher/Dockerfile" \
  -t archtenet/opal-fetcher:dev "$ROOT/opa-policies"
kind load docker-image archtenet/opal-fetcher:dev --name "$CLUSTER"
kubectl apply -f "$K8S/opal/fetcher-deployment.yaml"
# Same tag + IfNotPresent: a freshly kind-loaded image needs a restart to bite.
kubectl rollout restart deployment/opal-fetcher -n opa-system
kubectl rollout status deployment/opal-fetcher -n opa-system --timeout=120s

echo "--- OPA stack: done -------------------------------------------"
kubectl get pods -n opa-system
