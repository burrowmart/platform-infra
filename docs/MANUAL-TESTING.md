# Manual Testing Guide (Local)

Step-by-step manual test of the whole platform on your laptop. No Kubernetes needed — everything runs on Docker Compose. Written so a junior developer can follow it top to bottom. **Run the steps in order** — later steps depend on data created earlier.

> Placement: `platform-infra/docs/MANUAL-TESTING.md`

---

## 0. Prerequisites

Install once:

| Tool | Check it works | Why |
|---|---|---|
| Docker + Compose | `docker compose version` | runs Mongo/Redis/RabbitMQ/services |
| Node 20 | `node -v` → `v20.x` | runs services locally if needed |
| mongosh | `mongosh --version` | look inside MongoDB |
| redis-cli | `redis-cli --version` | look inside Redis |
| curl + jq | `curl --version`, `jq --version` | call REST APIs, pretty-print JSON |
| wscat | `npm i -g wscat` | test WebSocket |

**Ports used in this guide** (check `.env` files if something differs):

```
user-service 3001   catalog-service 3002   order-service 3003
payment-service 3004   notification-service 3005   chat-service 3006
ws-gateway 3007   cart-bff 4004   order-bff 4003
Mongo 27017   Redis 6379   RabbitMQ 5672 (UI: http://localhost:15672, guest/guest)
```

**Auth for local testing:** every service supports `AUTH_DISABLED=true` in `.env`. Set it for all services now, and pass your identity in a header: `-H "x-debug-user: vlada@test.dev"`. (In AWS, real Cognito JWTs are enforced — never set this flag there.)

**Payment failure switch:** payment-service reads `FAIL_PAYMENT_OVER_AMOUNT=1000`. Any order with total > 1000 will fail payment. We use this in step 6.

---

## 1. Start the infrastructure

```bash
cd platform-infra
docker compose up -d mongo redis rabbitmq
docker compose ps        # all three must show "healthy" (wait ~30s)
```

**Verify Mongo is a replica set** (critical — the outbox/change streams silently do nothing without it):

```bash
mongosh --eval "rs.status().members[0].stateStr"
# Expected: PRIMARY
```

If you get an error → the replica set didn't initialize; run `docker compose down -v && docker compose up -d` and wait again.

**Verify RabbitMQ UI:** open http://localhost:15672 (guest/guest). You should see the Overview page. Keep this tab open — you'll watch messages here.

---

## 2. Start the services

Start each service in its own terminal (or use the compose profiles if you added them):

```bash
cd user-service && npm ci && npm run start:dev
# repeat for: catalog-service, order-service, payment-service,
#             notification-service, chat-service, ws-gateway, cart-bff, order-bff
```

**Smoke check — every service must answer:**

```bash
for p in 3001 3002 3003 3004 3005 3006 3007; do
  echo "port $p:" && curl -s localhost:$p/metrics | head -1
done
# Expected: each prints a Prometheus metric line (starts with "# HELP")
```

If a service crashes on boot, read its first 20 log lines — 90% of the time it's a wrong `MONGO_URI` (must contain `replicaSet=rs0`) or Rabbit not up yet.

---

## 3. Create test data (user + catalog)

**Create a user:**

```bash
curl -s -X POST localhost:3001/users \
  -H "content-type: application/json" -H "x-debug-user: vlada@test.dev" \
  -d '{"email":"vlada@test.dev","displayName":"Vlada","roles":["customer"]}' | jq
# Expected: 201, JSON with your email
```

**Create two catalog items** — one cheap, one expensive (the expensive one triggers payment failure later):

```bash
curl -s -X POST localhost:3002/catalog \
  -H "content-type: application/json" -H "x-debug-user: vlada@test.dev" \
  -d '{"sku":"BOOK-1","name":"Book","price":20,"stock":10}' | jq

curl -s -X POST localhost:3002/catalog \
  -H "content-type: application/json" -H "x-debug-user: vlada@test.dev" \
  -d '{"sku":"LAPTOP-1","name":"Laptop","price":2000,"stock":3}' | jq
# Expected: 201 for both, "reserved": 0
```

---

## 4. Cart flow (Redis-only)

```bash
# Add 2 books to the cart
curl -s -X POST localhost:4004/cart/items \
  -H "content-type: application/json" -H "x-debug-user: vlada@test.dev" \
  -d '{"sku":"BOOK-1","qty":2}' | jq

# Read the cart
curl -s localhost:4004/cart -H "x-debug-user: vlada@test.dev" | jq
# Expected: BOOK-1, qty 2, price 20 (price came from catalog-service — that's the BFF aggregating)
```

**Look inside Redis** (this proves the cart never touches Mongo):

```bash
redis-cli HGETALL "cart:vlada@test.dev"     # your item as JSON
redis-cli TTL "cart:vlada@test.dev"         # a positive number (abandonment TTL)
```

---

## 5. Happy-path saga (the main event)

Checkout the cart:

```bash
curl -s -X POST localhost:4004/cart/checkout \
  -H "x-debug-user: vlada@test.dev" | jq
# Expected: 201 with an order in status "PENDING" and an "id"
export ORDER_ID=<paste the id here>
```

Now watch the saga complete (takes 1–3 seconds):

```bash
curl -s localhost:3003/orders/$ORDER_ID -H "x-debug-user: vlada@test.dev" | jq .status
# Expected: "CONFIRMED"
```

**Verify every side effect** — this is the actual test:

```bash
# 1. Stock was reserved
curl -s localhost:3002/catalog/BOOK-1 -H "x-debug-user: vlada@test.dev" | jq .reserved
# Expected: 2

# 2. Payment exists and succeeded
curl -s localhost:3004/payments/by-order/$ORDER_ID -H "x-debug-user: vlada@test.dev" | jq .status
# Expected: "SUCCEEDED"

# 3. Saga log shows every step in order
mongosh order_service --eval 'db.saga_log.find().sort({_id:-1}).limit(1).pretty()'
# Expected: state "CONFIRMED", stepHistory: reserve-inventory → charge, each "OK"

# 4. A notification was created (choreography from order-confirmed)
curl -s localhost:3005/notifications/unread-count -H "x-debug-user: vlada@test.dev" | jq
# Expected: {"count": 1}

# 5. The cart is now empty
curl -s localhost:4004/cart -H "x-debug-user: vlada@test.dev" | jq
# Expected: empty
```

In the RabbitMQ UI → Queues: message counters moved on the saga queues. If a queue has a growing "Ready" count and nothing consumes it — that service's consumer is down.

---

## 6. Failure path: payment fails → compensations

Order the laptop (total 2000 > `FAIL_PAYMENT_OVER_AMOUNT=1000`):

```bash
curl -s -X POST localhost:4004/cart/items \
  -H "content-type: application/json" -H "x-debug-user: vlada@test.dev" \
  -d '{"sku":"LAPTOP-1","qty":1}' | jq
curl -s -X POST localhost:4004/cart/checkout -H "x-debug-user: vlada@test.dev" | jq
export ORDER_ID2=<paste the new id>
```

Wait 2–3 seconds, then verify the rollback:

```bash
curl -s localhost:3003/orders/$ORDER_ID2 -H "x-debug-user: vlada@test.dev" | jq .status
# Expected: "CANCELLED"

curl -s localhost:3002/catalog/LAPTOP-1 -H "x-debug-user: vlada@test.dev" | jq .reserved
# Expected: 0   ← inventory was reserved, then RELEASED by the compensation

mongosh order_service --eval 'db.saga_log.findOne({orderId:"'$ORDER_ID2'"}).stepHistory'
# Expected: reserve-inventory OK → charge FAILED → release-inventory OK (reverse order!)
```

This is acceptance criterion #1. If `reserved` is not 0 — the compensation is broken.

---

## 7. Crash mid-saga → resume (the scary one)

1. **Stop payment-service** (Ctrl+C in its terminal). The saga will now get stuck after inventory reservation.
2. Order a book: repeat the checkout from step 5, note the new `ORDER_ID3`. Check: status stays `PENDING`, `reserved` on BOOK-1 increased.
3. **Kill order-service hard** (Ctrl+C) — the saga is now crashed mid-flight.
4. Start order-service again. Watch its logs: you should see it resume open sagas from `saga_log`.
5. Start payment-service again.
6. Within a few seconds: order → `CONFIRMED`, exactly **one** Payment document:

```bash
mongosh payment_service --eval 'db.payments.countDocuments({orderId:"'$ORDER_ID3'"})'
# Expected: 1  ← not 2. Two means idempotency is broken.
```

This is acceptance criterion #2.

---

## 8. Notifications: Redis hot layer + rebuild

```bash
curl -s localhost:3005/notifications -H "x-debug-user: vlada@test.dev" | jq '.items | length'   # list from Mongo
curl -s localhost:3005/notifications/unread-count -H "x-debug-user: vlada@test.dev" | jq        # count from Redis

# Nuke Redis entirely:
redis-cli FLUSHALL

# Ask again — must still work (rebuilt from Mongo):
curl -s localhost:3005/notifications/unread-count -H "x-debug-user: vlada@test.dev" | jq
# Expected: same count as before the flush
```

This is acceptance criterion #6. (Note: FLUSHALL also wiped the cart — expected, carts are disposable.)

---

## 9. Chat + WebSocket (live push)

**Terminal A — connect the socket:**

```bash
TICKET=$(curl -s -X POST localhost:3007/ws/ticket -H "x-debug-user: vlada@test.dev" | jq -r .ticket)
wscat -c "ws://localhost:3007/ws?ticket=$TICKET"
# After connecting, subscribe to a chat channel (paste as one line):
> {"channel":"chat:conv-1","action":"subscribe","payload":{"lastSeen":0}}
```

**Terminal B — send a message via REST:**

```bash
curl -s -X POST localhost:3006/conversations/conv-1/messages \
  -H "content-type: application/json" -H "x-debug-user: vlada@test.dev" \
  -d '{"body":"hello from terminal B"}' | jq
```

**Expected in Terminal A:** the message appears instantly, with `"seq": 1`. Send a second one → `"seq": 2`, no gaps.

**Test resume:** close wscat, send 2 more messages via REST, reconnect with a fresh ticket and `"lastSeen": 2` → the 2 missed messages replay immediately, in order.

**Reused ticket check:** reconnect with the OLD ticket → connection closes with code 4401. Tickets are single-use.

---

## 10. Correlation id end-to-end

```bash
curl -s -X POST localhost:4004/cart/checkout \
  -H "x-debug-user: vlada@test.dev" -H "cf-ray: MYTEST-RAY-42" | jq
```

Now grep every service's log output for `MYTEST-RAY-42`. **Expected:** it appears in cart-bff, order-service, catalog-service, payment-service, and notification-service logs — one id across the whole saga, including the async RabbitMQ hops. This is acceptance criterion #3 (log half; the trace half needs the observability stack — see the runbook `docs/find-by-rayid.md`).

---

## 11. When something is broken — where to look

| Symptom | Look here first |
|---|---|
| Order stuck in PENDING forever | RabbitMQ UI → is a queue piling up "Ready"? Then that consumer service is down or crashed on the message (check its DLQ). |
| No messages published at all | `mongosh <svc> --eval 'db.outbox.find({published:false}).count()'` — rows stuck? The outbox publisher lost the Redis leader lock or Mongo isn't a replica set. |
| Duplicate side effects | `processed_messages` collection in the consumer — is the messageId there? If yes but the effect doubled, the handler isn't inside the dedupe wrapper. |
| 403 on everything | You forgot `AUTH_DISABLED=true` or the `x-debug-user` header. |
| WebSocket connects then silence | redis-cli `SUBSCRIBE "notifications:vlada@test.dev"` yourself — if you see the message but wscat doesn't, the gateway's registry is broken; if you don't, the producer never published. |

---

## 12. Full reset

```bash
docker compose down -v   # -v deletes volumes = all data
docker compose up -d
# then repeat from step 1 (replica set check!)
```
