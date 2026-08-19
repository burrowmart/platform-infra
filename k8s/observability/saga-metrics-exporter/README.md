# saga-metrics-exporter

## Why this exists (a scope call worth flagging explicitly)

The saga-health dashboard needs a "saga_log terminal states" panel, but no
Prometheus metric for that exists anywhere in this system today — `saga_log`
is a plain Mongo collection order-service's orchestrator writes to (see
`order-service/src/order-orchestrator/schemas/saga-log.schema.ts`), with no
counter/gauge instrumentation around it.

Two ways to get that data into Prometheus:

1. Instrument order-orchestrator itself (a `Gauge`/`Counter` bump wherever
   the state machine transitions to `CONFIRMED`/`CANCELLED`).
2. A small out-of-process exporter that reads the collection from the
   outside and reports aggregate counts.

This session's brief is explicitly "you build the collection layer" against
services that "already emit" their observability signals — order-service's
own code is out of scope here, and (1) would mean editing
`orchestrator.service.ts`'s saga transition logic during an
observability-only session, for a dashboard nice-to-have. So: (2). This is
a deliberate, called-out scope decision, not an oversight — flagging it here
and in the session summary rather than quietly writing app code.

## What it does

Polls nothing on a timer — `prom-client`'s `Gauge.collect()` hook runs the
Mongo aggregation query fresh on every `/metrics` scrape (Prometheus's own
15s `scrape_interval` is the only cadence that matters), so there's no
separate polling loop to get out of sync with reality.

```
saga_terminal_state_total{state="CONFIRMED"}  12
saga_terminal_state_total{state="CANCELLED"}  3
saga_terminal_state_total{state="STARTED"}    1
saga_terminal_state_total{state="INVENTORY_RESERVED"} 0
saga_terminal_state_total{state="PAYMENT_SUCCEEDED"}  0
```

All five `SagaState` values are reported (see `state-machine.ts`), not just
the two terminal ones — the saga-health dashboard's terminal-state panel
filters to `CONFIRMED|CANCELLED`, and the in-flight count (the non-terminal
sum) is a useful secondary signal for the same panel at no extra cost.

## Read access to `saga_log`

Mounts order-service's own `MONGO_URI` secret (`envFrom.secretRef: name:
order-service`, synced by External Secrets Operator — see
`deployment.yaml`) rather than provisioning a new credential. Read-only by
convention (the exporter never writes), not by a distinct Mongo role — this
is a demo, and creating a separate least-privilege Mongo user is the
natural next step if this graduates past a demo.

## Local (Compose)

`../../../docker-compose.observability.yml` runs the same image against
`orders_it` — the database docker-compose.test.yml's order-service uses.
