/** Criterion 3: "One cf-ray/x-correlation-id value is visible across all
 * services' logs and one distributed trace for a single request."
 *
 * T5.3, automated: unlike integration-tests/test/04-correlation.spec.ts
 * (which reads `docker logs` directly), this check goes through the actual
 * observability pipeline — Vector -> Loki and OTel Collector -> Tempo —
 * using the exact LogQL/TraceQL queries documented in
 * ../../docs/find-by-rayid.md, against the docker-compose.observability.yml
 * `observability` profile stack. */

import { randomUUID } from 'crypto';
import { createCatalogItem, createOrder, getOrder } from '../../../integration-tests/src/support/http';
import { pollUntil } from '../../../integration-tests/src/support/poll';
import { evidence } from '../lib/types';
import type { CheckResult } from '../lib/types';

const LOKI_URL = process.env.LOKI_URL ?? 'http://localhost:3100';
const TEMPO_URL = process.env.TEMPO_URL ?? 'http://localhost:3200';
const EXPECTED_SERVICES = ['order-service', 'catalog-service', 'payment-service'];

interface LokiStream {
  stream: Record<string, string>;
  values: [string, string][];
}

async function queryLoki(rayId: string): Promise<LokiStream[]> {
  const query = `{namespace="compose-local"} | json | correlationId="${rayId}"`;
  const end = Date.now() * 1_000_000; // ns
  const start = end - 5 * 60 * 1_000_000_000; // 5 min lookback, ns
  const url = `${LOKI_URL}/loki/api/v1/query_range?query=${encodeURIComponent(query)}&start=${start}&end=${end}&limit=500`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Loki query failed: HTTP ${res.status} ${await res.text()}`);
  const body = (await res.json()) as { data: { result: LokiStream[] } };
  return body.data.result;
}

interface TempoSearchResult {
  traces?: { traceID: string; rootServiceName?: string }[];
}

async function searchTempo(rayId: string): Promise<TempoSearchResult> {
  const q = `{ span.rayId = "${rayId}" }`;
  const url = `${TEMPO_URL}/api/search?${new URLSearchParams({ q })}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Tempo search failed: HTTP ${res.status} ${await res.text()}`);
  return (await res.json()) as TempoSearchResult;
}

interface TempoTrace {
  batches?: { resource?: { attributes?: { key: string; value: { stringValue?: string } }[] }; scopeSpans?: unknown[] }[];
}

async function fetchTrace(traceId: string): Promise<TempoTrace> {
  const res = await fetch(`${TEMPO_URL}/api/traces/${traceId}`);
  if (!res.ok) throw new Error(`Tempo trace fetch failed: HTTP ${res.status} ${await res.text()}`);
  return (await res.json()) as TempoTrace;
}

export async function checkCorrelation(): Promise<CheckResult> {
  const startedAt = new Date();
  const ev: CheckResult['evidence'] = [];
  const assertions: string[] = [];
  let pass = true;
  let error: string | undefined;

  try {
    const rayId = `ACC-RAY-${randomUUID()}`;
    const sku = `RAY-${randomUUID()}`;
    const item = await createCatalogItem({ sku, name: 'Traceable Widget', description: 'acceptance check 3 item', price: 1000, stock: 5 });

    const userEmail = `${randomUUID()}@example.com`;
    const order = await createOrder({ userEmail, items: [{ sku: item.id, qty: 1, price: 1000 }] }, { 'cf-ray': rayId });

    const finalOrder = await pollUntil(() => getOrder(order.id), (o) => o.status !== 'PENDING', {
      timeoutMs: 30_000,
      description: `order ${order.id} to leave PENDING`,
    });
    assertions.push(assert('order CONFIRMED', finalOrder.status === 'CONFIRMED', `status=${finalOrder.status}`));

    // Loki/Tempo ingest lag — see docs/find-by-rayid.md ("give it 10-15s").
    const lokiStreams = await pollUntil(
      () => queryLoki(rayId),
      (streams) => {
        const services = new Set(streams.map((s) => s.stream.service));
        return EXPECTED_SERVICES.every((svc) => services.has(svc));
      },
      { timeoutMs: 45_000, intervalMs: 2_000, description: `Loki to carry rayId ${rayId} across all three services` },
    );
    const seenServices = [...new Set(lokiStreams.map((s) => s.stream.service))].sort();
    assertions.push(assert('Loki has log lines from all 3 saga services carrying correlationId', EXPECTED_SERVICES.every((s) => seenServices.includes(s)), `seen=${JSON.stringify(seenServices)}`));
    const totalLines = lokiStreams.reduce((n, s) => n + s.values.length, 0);
    assertions.push(assert('at least one log line per service', totalLines >= EXPECTED_SERVICES.length, `totalLines=${totalLines}`));

    const tempoResult = await pollUntil(() => searchTempo(rayId), (r) => (r.traces?.length ?? 0) > 0, {
      timeoutMs: 45_000,
      intervalMs: 2_000,
      description: `Tempo to index a trace with span.rayId = ${rayId}`,
    });
    const traces = tempoResult.traces ?? [];
    assertions.push(assert('exactly one distributed trace found for this rayId', traces.length === 1, `traceCount=${traces.length} ids=${JSON.stringify(traces.map((t) => t.traceID))}`));

    let resourceServiceNames = new Set<string>();
    if (traces[0]) {
      // The search index (above) can report a hit slightly before every
      // service's batch has landed in the full /api/traces/<id> document —
      // observed directly: a fetch immediately after the search succeeded
      // returned only the initiating service's batches. Poll the full trace
      // too, not just the search hit.
      await pollUntil(
        async () => {
          const trace = await fetchTrace(traces[0].traceID);
          resourceServiceNames = new Set<string>();
          for (const batch of trace.batches ?? []) {
            const svcAttr = batch.resource?.attributes?.find((a) => a.key === 'service.name');
            if (svcAttr?.value?.stringValue) resourceServiceNames.add(svcAttr.value.stringValue);
          }
          return resourceServiceNames;
        },
        (names) => names.size >= 2,
        { timeoutMs: 20_000, intervalMs: 2_000, description: `full trace ${traces[0].traceID} to include spans from >=2 services` },
      );
      assertions.push(assert('trace spans multiple services', resourceServiceNames.size >= 2, `resourceServices=${JSON.stringify([...resourceServiceNames])}`));
    }

    pass = assertions.every((a) => a.startsWith('PASS'));

    ev.push(
      evidence(
        'LogQL query + result summary',
        [`query: {namespace="compose-local"} | json | correlationId="${rayId}"`, `services present: ${JSON.stringify(seenServices)}`, `total matching log lines: ${totalLines}`].join('\n'),
      ),
    );
    ev.push(evidence('Sample log lines (one per service)', EXPECTED_SERVICES.map((svc) => {
      const stream = lokiStreams.find((s) => s.stream.service === svc);
      return `[${svc}] ${stream?.values[0]?.[1] ?? '(none found)'}`;
    }).join('\n')));
    ev.push(
      evidence(
        'TraceQL query + result',
        [`query: { span.rayId = "${rayId}" }`, `traces found: ${traces.length}`, `traceID: ${traces[0]?.traceID ?? 'n/a'}`, `distinct services in trace: ${resourceServiceNames.size} (${JSON.stringify([...resourceServiceNames])})`].join('\n'),
      ),
    );
    ev.push(evidence('Assertions', assertions.join('\n')));
  } catch (err) {
    pass = false;
    error = err instanceof Error ? `${err.message}\n${err.stack}` : String(err);
    ev.push(evidence('Assertions before failure', assertions.join('\n')));
  }

  const finishedAt = new Date();
  return {
    id: 'check-3-correlation',
    title: 'One cf-ray across all services’ logs + one distributed trace',
    criterion: 'One cf-ray/x-correlation-id value is visible across all services’ logs and one distributed trace for a single request.',
    pass,
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAt.getTime(),
    evidence: ev,
    summary: pass ? 'A single cf-ray was queryable in Loki across order/catalog/payment service logs and resolved to exactly one multi-service trace in Tempo.' : 'One or more assertions failed or the scenario errored — see evidence.',
    error,
  };
}

function assert(label: string, ok: boolean, detail: string): string {
  return `${ok ? 'PASS' : 'FAIL'}: ${label} (${detail})`;
}
