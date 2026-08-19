# Finding everything for one `cf-ray` value

Given a `cf-ray` (or `x-correlation-id`) value — call it `RAYID` below — here
is the exact query for every service's logs in Loki, and the exact search
for the one distributed trace it produced in Tempo. Both queries are
identical whether the stack is the k8s deployment in `../k8s/observability/`
or the Compose `observability` profile (`../docker-compose.observability.yml`)
— only the `namespace` label value differs (see below).

## Why this works

Every service already stamps `RAYID` onto three things (see
`ARCHITECTURE.md`'s Observability section and `CorrelationInterceptor` /
`ray-id.middleware.ts` in each service):

- every log line, as the JSON field `correlationId`
- every RabbitMQ message's native AMQP `correlationId` property
- every OTel span, as the attribute `rayId`

The collection layer built in `../k8s/observability/` doesn't add any of
that — it just ships what's already there to Loki and Tempo. See
`../k8s/observability/README.md`'s "Label strategy" section for why
`correlationId` is a queried *field*, not a Loki *label*.

## 1. Logs — Loki (LogQL)

```logql
{namespace="default"} | json | correlationId="RAYID"
```

- `{namespace="default"}` is the label selector LogQL requires at least one
  of (Loki refuses a query with no label matcher — it would otherwise have
  to scan every stream in the index). `default` is every app service's
  namespace in the k8s deployment (`order-service`, `catalog-service`,
  `payment-service`, etc. all land there — see e.g.
  `order-bff/helm/values.yaml`'s `*.default.svc.cluster.local` URLs).
  **Running against the Compose `observability` profile instead, use
  `{namespace="compose-local"}`** — Compose has no Kubernetes namespace, so
  the local Vector config (`../observability/vector-compose.yaml`) stamps
  this fixed value instead.
- `| json` parses each line's JSON body into fields.
- `| correlationId="RAYID"` filters to exactly the lines carrying this
  rayId — across every service in that namespace in one query, in
  chronological order, interleaved.

To see it scoped to just the saga participants:

```logql
{namespace="default", service=~"order-service|catalog-service|payment-service"} | json | correlationId="RAYID"
```

In Grafana: Explore → Loki datasource → paste either query → the log panel
shows every line, with a `service` column so you can tell which service
each line came from at a glance.

## 2. Trace — Tempo (TraceQL)

Give it 10-15 seconds after the request completes before searching: spans
sit in the OTel Collector's batch processor for up to 5s
(`otel-collector/config.yaml`'s `batch.timeout`), and Tempo's attribute
search index lags slightly behind raw ingest — a trace-ID lookup
(`/api/traces/<id>`) is available almost immediately, but an attribute
search like the one below needs that extra moment. Observed directly
running this against the Compose stack, not just from docs — an empty
result in the first few seconds isn't a broken pipeline, it's this lag.

```traceql
{ span.rayId = "RAYID" }
```

`rayId` is a **span attribute**, not a trace ID — `ray-id.middleware.ts`
calls `trace.getActiveSpan()?.setAttribute('rayId', rayId)` on the
request's entry span, and W3C traceparent propagation (OTel auto-
instrumentation, `common/tracing/tracing.ts`) carries that trace context
across every REST hop and RabbitMQ hop for the rest of the saga. TraceQL's
`span.<key>` selector finds any span, in any trace, carrying that attribute
— since only the request's original entry span sets it, this resolves to
exactly one trace containing every span downstream of that request:

- the REST call into order-bff / order-service
- the RabbitMQ publish + consume for `reserve-inventory` → catalog-service
- the RabbitMQ publish + consume for `charge` → payment-service
- the reply hops back through `saga.replies`

In Grafana: Explore → Tempo datasource → TraceQL query box → paste the
query above → click the one result → the trace view shows all the REST and
RabbitMQ spans as one waterfall.

Equivalent raw HTTP call against Tempo directly (useful for scripted
verification without Grafana open):

```bash
curl -s --get "http://localhost:3200/api/search" \
  --data-urlencode 'q={ span.rayId = "RAYID" }' | jq .
```

(`localhost:3200` assumes a `kubectl port-forward -n observability
svc/tempo 3200:3200`, or — for Compose — the `tempo` container's
`3200:3200` port mapping in `../docker-compose.observability.yml`.)

## Why there's no one-click link between the two

Grafana's Loki→Tempo "derived field" integration only works when the
captured value *is* a trace ID (it calls `GET /api/traces/<id>` directly).
`RAYID` is a span attribute, not a trace ID, so that shortcut doesn't apply
here — see the comment in
`../k8s/observability/grafana/provisioning/datasources.yaml` for why it was
deliberately left out rather than wired up to silently 404. Two queries,
not one click — but both are exact and both are above.
