/** Criterion 6: "Notifications: unread count reads from Redis (never
 * Mongo); the durable list survives a Redis flush (rebuildable from
 * Mongo)."
 *
 * Drives a real order to CONFIRMED (order-service publishes order-confirmed
 * -> notification-service's real choreography consumer persists to Mongo,
 * then INCRs the Redis unread counter) against notification-service running
 * in acceptance/docker-compose.acceptance.yml, then:
 *   1. reads unread-count (must come from Redis)
 *   2. kills Mongo briefly, re-reads unread-count (must still respond — no
 *      Mongo dependency on the hot path)
 *   3. restarts Mongo, FLUSHALLs Redis, re-reads unread-count (must rebuild
 *      the exact count from Mongo's durable journal) and confirms the Redis
 *      key was actually repopulated (not just coincidentally equal).
 */

import Redis from 'ioredis';
import { randomUUID } from 'crypto';
import { createCatalogItem, createOrder, getOrder, waitForAllServicesHealthy } from '../../../integration-tests/src/support/http';
import { dockerInspectStatus, dockerKill, dockerStart } from '../../../integration-tests/src/support/docker';
import { pollUntil } from '../../../integration-tests/src/support/poll';
import { composeContainerId } from '../lib/compose';
import { evidence } from '../lib/types';
import type { CheckResult } from '../lib/types';

const NOTIFICATION_URL = process.env.NOTIFICATION_URL ?? 'http://localhost:4004';
const REDIS_URL = process.env.ACCEPTANCE_REDIS_URL ?? 'redis://localhost:6379';

async function getUnreadCount(userEmail: string): Promise<{ status: number; count?: number }> {
  const res = await fetch(`${NOTIFICATION_URL}/notifications/unread-count`, {
    headers: { 'x-test-user-email': userEmail },
  });
  if (!res.ok) return { status: res.status };
  const body = (await res.json()) as { count: number };
  return { status: res.status, count: body.count };
}

async function getList(userEmail: string): Promise<{ status: number; total?: number }> {
  const res = await fetch(`${NOTIFICATION_URL}/notifications`, { headers: { 'x-test-user-email': userEmail } });
  if (!res.ok) return { status: res.status };
  const body = (await res.json()) as { total: number };
  return { status: res.status, total: body.total };
}

export async function checkNotificationsRedis(): Promise<CheckResult> {
  const startedAt = new Date();
  const ev: CheckResult['evidence'] = [];
  const assertions: string[] = [];
  let pass = true;
  let error: string | undefined;
  let mongoContainerId: string | undefined;
  const redis = new Redis(REDIS_URL, { lazyConnect: true, maxRetriesPerRequest: 1 });

  try {
    await redis.connect();

    // ── Generate a real notification via a real confirmed order ────────────
    const userEmail = `acceptance-notif-${randomUUID()}@example.com`;
    const sku = `NOTIF-${randomUUID()}`;
    const item = await createCatalogItem({ sku, name: 'Notifiable Widget', description: 'acceptance check 6 item', price: 500, stock: 5 });
    const order = await createOrder({ userEmail, items: [{ sku: item.id, qty: 1, price: 500 }] });
    const finalOrder = await pollUntil(() => getOrder(order.id), (o) => o.status !== 'PENDING', {
      timeoutMs: 30_000,
      description: `order ${order.id} to leave PENDING`,
    });
    assertions.push(assert('seed order CONFIRMED (produces order-confirmed event)', finalOrder.status === 'CONFIRMED', `status=${finalOrder.status}`));

    // ── 1. Unread count is Redis-backed ─────────────────────────────────────
    const initial = await pollUntil(() => getUnreadCount(userEmail), (r) => r.status === 200 && (r.count ?? 0) >= 1, {
      timeoutMs: 20_000,
      description: `unread-count for ${userEmail} to reach >=1 (notification-service consumed order-confirmed)`,
    });
    assertions.push(assert('unread-count reachable and >=1 after order confirmed', initial.status === 200 && (initial.count ?? 0) >= 1, `status=${initial.status} count=${initial.count}`));
    const baselineCount = initial.count ?? 0;

    const redisKeyBefore = await redis.get(`notif:unread:${userEmail}`);
    assertions.push(assert('Redis key notif:unread:<email> exists (proves count is Redis-backed)', redisKeyBefore !== null, `redis value=${redisKeyBefore}`));
    assertions.push(assert('Redis key value matches REST response', Number(redisKeyBefore) === baselineCount, `redis=${redisKeyBefore} rest=${baselineCount}`));

    // ── 2. Mongo down -> unread-count still responds from Redis ────────────
    mongoContainerId = await composeContainerId('mongo');
    await dockerKill(mongoContainerId);
    assertions.push(assert('mongo container stopped', (await dockerInspectStatus(mongoContainerId)) === 'exited', `status`));

    const duringMongoDown = await getUnreadCount(userEmail);
    assertions.push(assert('unread-count still responds 200 while Mongo is down (Redis-only read)', duringMongoDown.status === 200, `status=${duringMongoDown.status}`));
    assertions.push(assert('unread-count value unchanged while Mongo is down', duringMongoDown.count === baselineCount, `count=${duringMongoDown.count} baseline=${baselineCount}`));

    // ── 3. Restart Mongo, FLUSHALL Redis -> rebuild from Mongo ─────────────
    await dockerStart(mongoContainerId);
    await pollUntil(
      () => dockerInspectStatus(mongoContainerId!),
      (s) => s === 'running',
      { timeoutMs: 30_000, description: 'mongo container to report running again' },
    );
    // Give the replica set a moment to reach PRIMARY again before hitting the app.
    await pollUntil(() => getList(userEmail), (r) => r.status === 200, { timeoutMs: 30_000, intervalMs: 1000, description: 'notification-service Mongo-backed list endpoint to recover after mongo restart' });

    await redis.flushall();
    const redisKeyAfterFlush = await redis.get(`notif:unread:${userEmail}`);
    assertions.push(assert('Redis key gone immediately after FLUSHALL', redisKeyAfterFlush === null, `value=${redisKeyAfterFlush}`));

    const rebuilt = await pollUntil(() => getUnreadCount(userEmail), (r) => r.status === 200, {
      timeoutMs: 20_000,
      description: 'unread-count to respond after Redis FLUSHALL (rebuild path)',
    });
    assertions.push(assert('unread-count rebuilt from Mongo matches original count', rebuilt.count === baselineCount, `rebuilt=${rebuilt.count} baseline=${baselineCount}`));

    const redisKeyAfterRebuild = await redis.get(`notif:unread:${userEmail}`);
    assertions.push(assert('Redis key repopulated by the rebuild path (not just a lucky Mongo passthrough)', Number(redisKeyAfterRebuild) === baselineCount, `redis=${redisKeyAfterRebuild}`));

    const listAfter = await getList(userEmail);
    assertions.push(assert('Mongo-backed list endpoint reflects the durable journal', listAfter.status === 200 && (listAfter.total ?? 0) >= 1, `status=${listAfter.status} total=${listAfter.total}`));

    pass = assertions.every((a) => a.startsWith('PASS'));

    ev.push(
      evidence(
        'Unread-count timeline',
        [
          `userEmail: ${userEmail}`,
          `orderId: ${order.id}`,
          `1. after order CONFIRMED: HTTP ${initial.status}, count=${initial.count} (redis key=${redisKeyBefore})`,
          `2. mongo killed, unread-count: HTTP ${duringMongoDown.status}, count=${duringMongoDown.count}`,
          `3. mongo restarted + redis FLUSHALL, redis key immediately after flush=${redisKeyAfterFlush}`,
          `4. unread-count after flush (rebuild path): HTTP ${rebuilt.status}, count=${rebuilt.count}, redis key now=${redisKeyAfterRebuild}`,
          `5. GET /notifications after rebuild: HTTP ${listAfter.status}, total=${listAfter.total}`,
        ].join('\n'),
      ),
    );
    ev.push(evidence('Assertions', assertions.join('\n')));
  } catch (err) {
    pass = false;
    error = err instanceof Error ? `${err.message}\n${err.stack}` : String(err);
    ev.push(evidence('Assertions before failure', assertions.join('\n')));
  } finally {
    try {
      if (mongoContainerId && (await dockerInspectStatus(mongoContainerId)) !== 'running') {
        await dockerStart(mongoContainerId);
      }
      // Leave the stack fully healthy for the next check / next full run of
      // this harness, not just this check's own assertions satisfied.
      await waitForAllServicesHealthy(60_000);
    } catch (cleanupErr) {
      ev.push(evidence('Cleanup warning', String(cleanupErr)));
    }
    await redis.quit().catch(() => undefined);
  }

  const finishedAt = new Date();
  return {
    id: 'check-6-notifications-redis',
    title: 'Notifications: unread-count from Redis, rebuildable from Mongo',
    criterion: 'Notifications: unread count reads from Redis (never Mongo); the durable list survives a Redis flush (rebuildable from Mongo).',
    pass,
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAt.getTime(),
    evidence: ev,
    summary: pass ? 'unread-count served from Redis and kept responding correctly while Mongo was down; after Mongo recovered and Redis was FLUSHALLed, unread-count and the recent list were correctly rebuilt from the Mongo journal.' : 'One or more assertions failed or the scenario errored — see evidence.',
    error,
  };
}

function assert(label: string, ok: boolean, detail: string): string {
  return `${ok ? 'PASS' : 'FAIL'}: ${label} (${detail})`;
}
