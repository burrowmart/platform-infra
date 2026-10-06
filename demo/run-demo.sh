#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build every service image, load it into the kind cluster, and helm-install it.
#
#   source platform-infra/.env.local                      # sets MONGO_BASE_URI
#   ./platform-infra/demo/run-demo.sh                     # all services
#   ./platform-infra/demo/run-demo.sh user-service order-service
#
# Covers: ingress-nginx, data stores, the platform Secret, the full OPA/OPAL
# stack (MinIO + OPA DaemonSet + OPAL server + fetcher, via ./opa-stack.sh),
# and every service.
#
# Do the first service by hand before reaching for this — see
# docs/LOCAL-DEPLOYMENT.md. This script is for the repetitive part, not for
# learning what the repetitive part does.
# ---------------------------------------------------------------------------
set -euo pipefail

CLUSTER="${CLUSTER:-archtenet}"
NAMESPACE="${NAMESPACE:-local}"

# Repo root = the backend/ directory, which is also the Docker build context
# every service's Dockerfile expects (it copies contracts/ as well as its own
# source, so building from the service directory would fail).
cd "$(dirname "$0")/../.."
ROOT="$PWD"

ALL_SERVICES=(
  user-service catalog-service order-service payment-service
  notification-service chat-service
  user-bff catalog-bff order-bff cart-bff payment-bff
  ws-gateway
)

SERVICES=("$@")
[ ${#SERVICES[@]} -eq 0 ] && SERVICES=("${ALL_SERVICES[@]}")

echo "=== base-service chart ===================================="
# helm/charts/ is gitignored: the packaged base-service is a build artifact.
# CI pulls it from ghcr.io; locally it is packaged straight from the sibling
# platform-infra checkout, so an edit to the base chart takes effect at once.
"$ROOT/platform-infra/scripts/vendor-base-chart.sh"
echo

echo "=== ingress-nginx ========================================="
# Owns the nginx-internal IngressClass that every service chart targets.
# Must exist before any service: without it the Ingress objects are created
# but nothing serves them, and with the wrong controller settings the
# admission webhook rejects them outright (see demo/ingress-nginx-values.yaml).
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install ingress-nginx-internal ingress-nginx/ingress-nginx \
  --namespace ingress --create-namespace \
  -f "$ROOT/platform-infra/demo/ingress-nginx-values.yaml" \
  --wait --timeout 4m

echo "=== data stores ==========================================="
kubectl apply -f "$ROOT/platform-infra/demo/data-namespace.yaml"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$NAMESPACE" -f "$ROOT/platform-infra/demo/platform-secret.yaml"

# --- OPA/OPAL stack --------------------------------------------------------
# The Envoy PEP sidecar in every pod calls the OPA PDP. It must exist before
# any service starts, or Envoy denies everything (failure_mode_allow: false).
# opa-stack.sh deploys the full stack — MinIO (S3 stand-in), the OPA
# DaemonSet with its opal-client sidecar, the OPAL server, and the
# RabbitMQ->OPAL fetcher — and uploads a freshly built bundle to MinIO, so a
# policy edit is picked up by re-running this script (OPA re-polls within 10s).
# Needs the data stores above: the fetcher consumes RabbitMQ.
echo "=== OPA/OPAL stack ============================================="
CLUSTER="$CLUSTER" NAMESPACE="$NAMESPACE" "$ROOT/platform-infra/demo/opa-stack.sh"
echo

# ---------------------------------------------------------------------------
# MongoDB.
#
# MONGO_BASE_URI is the connection string WITHOUT a database name, e.g.
#   mongodb+srv://platform:<password>@cluster0.abcde.mongodb.net
# Keep it in platform-infra/.env.local (gitignored) and `source` that file —
# never paste it on the command line, where it lands in shell history.
#
# Unset falls back to the optional in-cluster Mongo (mongo-in-cluster.yaml).
# ---------------------------------------------------------------------------
IN_CLUSTER_MONGO="mongodb://mongo-0.mongo.data.svc.cluster.local:27017"
MONGO_BASE_URI="${MONGO_BASE_URI:-}"

if [ -z "$MONGO_BASE_URI" ]; then
  echo "MONGO_BASE_URI is not set — falling back to the in-cluster MongoDB."
  echo "For Atlas: source platform-infra/.env.local first."
  echo
  MONGO_BASE_URI="$IN_CLUSTER_MONGO"
  MONGO_OPTS="?replicaSet=rs0"
else
  MONGO_OPTS="?retryWrites=true&w=majority"
fi

# Each service owns its own database, so the URI differs per service and
# cannot live in the shared platform-local Secret. It goes into a Secret of
# its own rather than a `helm --set`, so the Atlas password never appears in
# the Helm release values or in `helm get values` output.
mongo_uri() {
  echo "${MONGO_BASE_URI}/${1}${MONGO_OPTS}"
}

echo "cluster:   $CLUSTER"
echo "namespace: $NAMESPACE"
echo "services:  ${SERVICES[*]}"
echo

for svc in "${SERVICES[@]}"; do
  if [ ! -f "$ROOT/$svc/Dockerfile" ]; then
    echo "!! $svc has no Dockerfile — skipping"
    continue
  fi

  echo "=== $svc: build ==============================================="
  docker build -f "$svc/Dockerfile" -t "$svc:local" "$ROOT"

  echo "=== $svc: load into kind ======================================"
  kind load docker-image "$svc:local" --name "$CLUSTER"

  echo "=== $svc: mongo secret ========================================"
  kubectl create secret generic "$svc-mongo" \
    --namespace "$NAMESPACE" \
    --from-literal="MONGO_URI=$(mongo_uri "$svc")" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "=== $svc: helm install ========================================"
  helm upgrade --install "$svc" "$ROOT/$svc/helm" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$ROOT/platform-infra/demo/values-local.yaml" \
    --set "base-service.image.repository=$svc" \
    --set "base-service.image.tag=local" \
    --set-json "base-service.app.extraEnvFromSecrets=[\"platform-local\",\"$svc-mongo\"]" \
    --wait --timeout 3m

  echo
done

echo "=== done ======================================================="
kubectl get pods -n "$NAMESPACE"
