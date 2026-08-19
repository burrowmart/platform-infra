#!/usr/bin/env -S npx tsx
/**
 * Acceptance harness for ARCHITECTURE.md's six acceptance criteria.
 *
 * Brings up the full local stack (mongo/redis/rabbitmq + order/catalog/
 * payment/notification-service + the observability profile), runs all six
 * checks against it (each check asserts from *this* harness — see
 * src/checks/*.ts — reusing integration-tests' support libs and
 * opa-policies/demo where the task calls for reuse), prints an N/6 summary,
 * and writes ../ACCEPTANCE.md with evidence for every criterion.
 *
 * Usage:
 *   npm run run                  # from platform-infra/acceptance
 *   RUN_LABEL="1" npm run run    # label this run in the report (optional)
 */

import * as fs from 'fs';
import * as path from 'path';
import { composeUp, composeContainerId } from './src/lib/compose';
import { waitForAllServicesHealthy } from '../integration-tests/src/support/http';
import { pollUntil } from '../integration-tests/src/support/poll';
import { closeMongo } from '../integration-tests/src/support/mongo';
import { renderReport } from './src/lib/report';
import type { CheckResult } from './src/lib/types';

import { checkFailedPayment } from './src/checks/01-failed-payment';
import { checkCrashMidSaga } from './src/checks/02-crash-mid-saga';
import { checkCorrelation } from './src/checks/03-correlation';
import { checkManifestAudit } from './src/checks/04-manifest-audit';
import { checkEnvoyOpa } from './src/checks/05-envoy-opa';
import { checkNotificationsRedis } from './src/checks/06-notifications-redis';

const NOTIFICATION_URL = process.env.NOTIFICATION_URL ?? 'http://localhost:4004';
const RUN_LABEL = process.env.RUN_LABEL ?? new Date().toISOString();
const REPORT_PATH = path.resolve(__dirname, '..', 'ACCEPTANCE.md');

async function waitForNotificationServiceHealthy(): Promise<void> {
  await pollUntil(
    async () => {
      try {
        const res = await fetch(`${NOTIFICATION_URL}/health`);
        return res.status;
      } catch {
        return 0;
      }
    },
    (status) => status === 200,
    { timeoutMs: 90_000, description: 'notification-service (http://localhost:4004) to report healthy' },
  );
}

async function main(): Promise<void> {
  const startedAt = new Date();
  console.log(`\n=== Acceptance run "${RUN_LABEL}" starting ${startedAt.toISOString()} ===\n`);

  console.log('--- Bringing up compose stack (base + test + acceptance + observability profile) ---');
  const composeResult = await composeUp();
  if (!composeResult.ok) {
    console.error('!!! One or more images failed to build — see docker compose output above for which service. Continuing with whatever came up.');
  }

  console.log('--- Waiting for order/catalog/payment-service health ---');
  await waitForAllServicesHealthy(120_000);
  console.log('--- Waiting for notification-service health ---');
  try {
    await waitForNotificationServiceHealthy();
  } catch (err) {
    // Do not abort the whole harness — checks 1-5 don't depend on
    // notification-service. Check 6 will fail on its own, with its own
    // evidence, if this service never came up.
    console.error(`!!! notification-service did not become healthy: ${err instanceof Error ? err.message : err}`);
    console.error('!!! Continuing with the remaining checks; check 6 will report this failure with evidence.');
  }
  // mongo must have a resolvable container id before check 6 needs it — fail
  // fast here with a clear error rather than deep inside that check.
  await composeContainerId('mongo');

  const results: CheckResult[] = [];

  const checks: Array<[string, () => Promise<CheckResult>]> = [
    ['1/6 failed payment -> compensation -> CANCELLED', checkFailedPayment],
    ['2/6 crash mid-saga -> resume, no double effects', checkCrashMidSaga],
    ['3/6 cf-ray correlation (Loki + Tempo)', checkCorrelation],
    ['4/6 manifest audit (helm + terraform)', checkManifestAudit],
    ['5/6 envoy-pep sidecar + live OPA ext_authz', checkEnvoyOpa],
    ['6/6 notifications: Redis-backed, Mongo-rebuildable', checkNotificationsRedis],
  ];

  for (const [label, fn] of checks) {
    console.log(`\n--- Running check ${label} ---`);
    const result = await fn();
    results.push(result);
    console.log(`--- ${result.pass ? 'PASS' : 'FAIL'}: ${result.title} (${(result.durationMs / 1000).toFixed(1)}s) ---`);
    if (!result.pass) {
      console.log(`    summary: ${result.summary}`);
      if (result.error) console.log(`    error: ${result.error.split('\n')[0]}`);
    }
  }

  await closeMongo();

  const finishedAt = new Date();
  const passCount = results.filter((r) => r.pass).length;

  const report = renderReport(results, { startedAt: startedAt.toISOString(), finishedAt: finishedAt.toISOString(), runNumber: 0 }).replace(
    /\*\*Run 0\*\*/,
    `**Run "${RUN_LABEL}"**`,
  );
  fs.writeFileSync(REPORT_PATH, report);
  console.log(`\nWrote ${REPORT_PATH}`);

  console.log(`\n=== RESULT: ${passCount}/6 PASS ===`);
  for (const [i, r] of results.entries()) {
    console.log(`  ${i + 1}. [${r.pass ? 'PASS' : 'FAIL'}] ${r.title}`);
  }
  console.log('');

  if (passCount !== 6) {
    const failing = results.filter((r) => !r.pass).map((r) => r.title);
    console.error(`FAILING: ${failing.join('; ')}`);
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error('Acceptance harness crashed:', err);
  process.exitCode = 1;
});
