# platform-infra

Onboarding entry point for the archtenet backend platform.
**Start here.** See individual service repos for domain logic; this repo owns the shared Helm chart, CI pipeline, infrastructure, and the local dev stack.

---

## Acceptance criteria — verified

[`ACCEPTANCE.md`](./ACCEPTANCE.md) is the standing verification report for `ARCHITECTURE.md`'s six acceptance
criteria (compensation, crash recovery, correlation, network isolation, PEP+OPA authz, notification resilience),
generated end-to-end against this repo's own Docker Compose stack by [`acceptance/run-acceptance.ts`](./acceptance/run-acceptance.ts) — no mocks. Re-run it with:

```bash
cd acceptance && npm install && npm run run
```

---

## Traffic path

No public inbound. No ALB/NLB. `cloudflared` dials out to the Cloudflare edge — that is the only internet-facing connection in the entire cluster.

```mermaid
flowchart TD
    CF["Cloudflare Edge\n+ OAuth Worker\n(injects id_token as cf-token header)"]
    TUN["Cloudflare Tunnel\n(outbound-only, no public listener)"]
    CFD["cloudflared pods\nns: cloudflared — 3 replicas"]
    NGX["nginx IngressController\n(ClusterIP, internal only)"]
    SVC["ClusterIP Service"]
    ENV["Envoy PEP sidecar\n:8080"]
    OPA["OPA PDP DaemonSet\n(gRPC ext_authz)"]
    APP["NestJS app\n:3000"]

    CF -->|"HTTPS (public)"| TUN
    TUN -->|"mTLS outbound"| CFD
    CFD -->|"HTTP"| NGX
    NGX -->|"HTTP (host/path routing)"| SVC
    SVC -->|"HTTP"| ENV
    ENV <-->|"gRPC ext_authz"| OPA
    ENV -->|"HTTP (on allow)"| APP
```

Every pod has **two containers**: the NestJS app and the Envoy PEP sidecar. Envoy checks every request via `ext_authz` against the OPA PDP DaemonSet before forwarding to the app. The app also independently verifies the Cognito JWT (JWKS guard) — it never trusts injected headers blindly.

---

## System map

### Domain services

| Service | Mongo collection(s) | Redis keys | RabbitMQ queues consumed | Sync callers | Async in |
|---|---|---|---|---|---|
| **user-service** | `users`, `outbox` | — | — | user-bff (REST) | — |
| **catalog-service** | `catalog`, `outbox` | — | `catalog.reserve-inventory`<br>`catalog.release-inventory` | catalog-bff (REST) | saga cmds from order-orchestrator |
| **order-service** | `orders`, `outbox`, `saga-log` | — | `order.inventory-reserved`<br>`order.inventory-rejected`<br>`order.payment-succeeded`<br>`order.payment-failed` | order-bff (REST) | saga replies from catalog & payment |
| **payment-service** | `payments`, `outbox` | — | `payment.charge`<br>`payment.refund-payment` | payment-bff (REST) | saga cmds from order-orchestrator |
| **notification-service** | `notifications`, `outbox` | `notif:{userId}:unread` (counter)<br>`notif:{userId}:recent` (list, LPUSH/LTRIM) | `notification.order-confirmed`<br>`notification.order-cancelled` | shell REST direct | choreographed domain events |
| **chat-service** | `chats`, `outbox` | `chat:presence:{userId}` (TTL)<br>`chat:typing:{convId}:{userId}` (TTL) | `chat.*` | ws-gateway, chat-bff | — |

### BFFs & edge

| Unit | Owns | Calls (sync REST) | Notes |
|---|---|---|---|
| **user-bff** | — | user-service | Aggregates user profile + preferences |
| **catalog-bff** | — | catalog-service | Aggregates catalog + search |
| **order-bff** | — | order-service, catalog-service | Aggregates order summary + line items |
| **cart-bff** | Redis: `cart:{userId}:items` (hash)<br>`cart:{userId}` (TTL) | catalog-service (price lookup) | Redis-only; no Mongo collection, no cart-service |
| **payment-bff** | — | payment-service | Aggregates payment history |
| **ws-gateway** | — | Redis pub/sub subscriber | One multiplexed WS per client; ticket auth on handshake; resume cursor support |

### Redis pub/sub channels (ws-gateway subscribes)

| Channel pattern | Publisher | Consumer |
|---|---|---|
| `notif:push:{userId}` | notification-service | ws-gateway → user's socket |
| `chat:{conversationId}` | chat-service | ws-gateway → all participants' sockets |

---

## Order-placement saga

Orchestrated by the `order-orchestrator` module inside **order-service**. Message names are the frozen constants from `contracts/src/messages`.

```
order-bff
  │  POST /orders  (REST)
  ▼
order-service  ── creates Order(PENDING) + saga-log row ──►  outbox collection
                                                                   │
                                              outbox-publisher watches via change stream
                                                                   │
                                    ┌──────────────────────────────┘
                                    │  saga.commands exchange
                                    │  routing-key: reserve-inventory
                                    ▼
                             catalog-service
                             (queue: catalog.reserve-inventory)
                                    │
                     ┌─────── stock OK? ───────┐
                     │ YES                     │ NO
                     ▼                         ▼
          InventoryReservedPayload    InventoryRejectedPayload
          → saga.replies              → saga.replies
          → order.inventory-reserved  → order.inventory-rejected
                     │                         │
                     │                         └──► order-orchestrator
                     │                               mark Order(CANCELLED)
                     │                               publish OrderCancelledPayload
                     │                               → domain.events  ──► notification-service
                     │
                     ▼
          order-orchestrator sends ChargePayload
          → saga.commands  routing-key: charge
          → payment-service (queue: payment.charge)
                     │
              ┌── charged? ──┐
              │ YES          │ NO
              ▼              ▼
  PaymentSucceededPayload  PaymentFailedPayload
  → saga.replies           → saga.replies
  → order.payment-succeeded → order.payment-failed
              │              │
              │              └──► order-orchestrator
              │                    compensation: ReleaseInventoryPayload
              │                    → saga.commands  routing-key: release-inventory
              │                    → catalog.release-inventory
              │                    mark Order(CANCELLED)
              │                    publish OrderCancelledPayload → domain.events
              │
              ▼
   order-orchestrator
   mark Order(CONFIRMED)
   publish OrderConfirmedPayload
   → domain.events (exchange: domain.events, routing-key: order-confirmed)
              │
   ┌──────────┴──────────────────────────────────────────────┐
   ▼  queue: notification.order-confirmed                     ▼  (other future consumers)
notification-service
  persist Notification → Mongo
  INCR notif:{userId}:unread   (Redis)
  LPUSH notif:{userId}:recent  (Redis)
  PUBLISH notif:push:{userId}  (Redis pub/sub)
              │
              ▼
         ws-gateway fan-out → user's WebSocket
```

### Exact message types (from `contracts/src/messages`)

| Direction | Exchange | Routing key | Queue | Payload type |
|---|---|---|---|---|
| orchestrator → catalog | `saga.commands` | `reserve-inventory` | `catalog.reserve-inventory` | `ReserveInventoryPayload` |
| catalog → orchestrator | `saga.replies` | `inventory-reserved` | `order.inventory-reserved` | `InventoryReservedPayload` |
| catalog → orchestrator | `saga.replies` | `inventory-rejected` | `order.inventory-rejected` | `InventoryRejectedPayload` |
| orchestrator → payment | `saga.commands` | `charge` | `payment.charge` | `ChargePayload` |
| payment → orchestrator | `saga.replies` | `payment-succeeded` | `order.payment-succeeded` | `PaymentSucceededPayload` |
| payment → orchestrator | `saga.replies` | `payment-failed` | `order.payment-failed` | `PaymentFailedPayload` |
| orchestrator → catalog *(compensation)* | `saga.commands` | `release-inventory` | `catalog.release-inventory` | `ReleaseInventoryPayload` |
| payment → orchestrator *(compensation)* | `saga.commands` | `refund-payment` | `payment.refund-payment` | `RefundPaymentPayload` |
| order-service → all | `domain.events` | `order-confirmed` | `notification.order-confirmed` | `OrderConfirmedPayload` |
| order-service → all | `domain.events` | `order-cancelled` | `notification.order-cancelled` | `OrderCancelledPayload` |

All messages are wrapped in `MessageEnvelope<T>` (see `contracts/src/messages/envelope.ts`). Every consumer deduplicates by `messageId`; every saga step is keyed by `(sagaId, step)`.

---

## Correlation / observability

`cf-ray` from the Cloudflare edge (or `x-correlation-id` generated at ingress if absent) flows through:
- every NestJS log line (via `nestjs-pino` + `AsyncLocalStorage`)
- every outbound REST call header
- every RabbitMQ message property (`correlationId` in the envelope)
- every OTel span attribute (`rayId`)

This means a single `cf-ray` value is queryable across **all service logs** in Loki and locates the corresponding distributed trace in Tempo/Jaeger.

---

## Run locally

```bash
# 1. Start the infrastructure stack
cd platform-infra
docker compose up -d

# 2. Check all three services are healthy
docker compose ps
# Expected: mongo, redis, rabbitmq all "healthy"

# 3. Confirm MongoDB is PRIMARY
docker compose exec mongo mongosh --quiet --eval \
  'rs.status().members.map(m => ({ name: m.name, stateStr: m.stateStr }))'
# Expected: [ { name: 'localhost:27017', stateStr: 'PRIMARY' } ]

# 4. (Optional) tail logs
docker compose logs -f

# 5. Tear down (preserves volumes)
docker compose down

# 5b. Tear down and wipe volumes (full reset)
docker compose down -v
```

### Ports

| Service | Port | UI / notes |
|---|---|---|
| MongoDB | 27017 | connect with `mongosh mongodb://localhost:27017/?replicaSet=rs0` |
| Redis | 6379 | connect with `redis-cli -h localhost` |
| RabbitMQ AMQP | 5672 | `amqp://guest:guest@localhost:5672` |
| RabbitMQ management | 15672 | http://localhost:15672 — guest / guest |

### Running a service against the stack

Uncomment the `user-service` block in `docker-compose.yml` (or copy it for any other service) and fill in `COGNITO_USER_POOL_ID` / `COGNITO_CLIENT_ID`. The key env vars every service needs:

```env
MONGO_URI=mongodb://mongo:27017/<db-name>?replicaSet=rs0
REDIS_URL=redis://redis:6379
RABBITMQ_URL=amqp://guest:guest@rabbitmq:5672
```

> `replicaSet=rs0` in `MONGO_URI` is **required** — without it the Mongoose driver won't use the replica-set protocol and change streams (outbox) will fail.

---

---

## How a service inherits the base chart

### 1. Declare the dependency in your service's `helm/Chart.yaml`

```yaml
dependencies:
  - name: base-service
    version: "0.1.0"
    # file:// for local dev; replace with an OCI registry URL for CI
    repository: "file://../../platform-infra/helm/base-service"
```

Run once to resolve:
```bash
helm dependency update ./helm
```

### 2. Override only what differs in `helm/values.yaml`

```yaml
image:
  repository: ghcr.io/myorg/user-service
  tag: latest          # overridden by CI: --set image.tag=sha-<SHA>

app:
  port: 3000
  env:
    MONGO_URI: mongodb://localhost:27017/users

ingress:
  host: user-service.internal.archtenet.com
  path: /api/v1/users

secretsManagerPath: /prod/user-service
irsaRoleArn: arn:aws:iam::111122223333:role/user-service-irsa
```

All other keys (Envoy image, HPA thresholds, PDB, Service type) are inherited from the base chart's `values.yaml`.

---

## How a service calls the reusable CI workflow

In your service repo's `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    uses: myorg/platform-infra/.github/workflows/service-ci.yml@main
    with:
      service-name: user-service
      helm-path: ./helm
    secrets:
      SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
```

### Required repository variables (set once per service repo)

| Variable              | Example value                                              |
|-----------------------|------------------------------------------------------------|
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::111122223333:role/github-oidc-deploy`        |
| `AWS_REGION`          | `eu-west-1`                                                |
| `EKS_CLUSTER_NAME`    | `archtenet-prod`                                           |

The deploy role trust policy must allow the GitHub OIDC subject for the calling repository. No static AWS keys are stored anywhere.

---

## Directory structure

```
platform-infra/
├── .github/
│   └── workflows/
│       └── service-ci.yml        # reusable pipeline (workflow_call)
├── examples/
│   └── example-service-values.yaml
├── helm/
│   └── base-service/             # parent chart; services inherit via file:// dep
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── configmap.yaml    # Envoy static config (OPA ext_authz)
│           ├── deployment.yaml   # app + envoy-pep two-container pod
│           ├── externalsecret.yaml
│           ├── hpa.yaml
│           ├── ingress.yaml      # nginx-internal class only
│           ├── pdb.yaml
│           ├── service.yaml      # ClusterIP only
│           └── serviceaccount.yaml  # IRSA annotation
└── README.md                     # this file
```
