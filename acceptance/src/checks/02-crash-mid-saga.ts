/** Criterion 2: "Killing the service mid-saga and restarting resumes
 * correctly (idempotent, no double effects)."
 *
 * Reuses T2.5 scenario 3 (integration-tests/test/03-crash-mid-saga.spec.ts)
 * verbatim for the scenario mechanics — pause payment-service so `charge`
 * sits in flight, kill+restart order-service mid-saga, unpause payment —
 * assertions run here, in this harness. */

import { randomUUID } from 'crypto';
import { CONTAINERS } from '../../../integration-tests/src/support/config';
import { dockerInspectStatus, dockerKill, dockerPause, dockerStart, dockerUnpause } from '../../../integration-tests/src/support/docker';
import { createCatalogItem, createOrder, getOrder, waitForAllServicesHealthy } from '../../../integration-tests/src/support/http';
import { catalogDb, ObjectId, orderDb, paymentDb } from '../../../integration-tests/src/support/mongo';
import { pollUntil } from '../../../integration-tests/src/support/poll';
import { evidence } from '../lib/types';
import type { CheckResult } from '../lib/types';

export async function checkCrashMidSaga(): Promise<CheckResult> {
  const startedAt = new Date();
  const ev: CheckResult['evidence'] = [];
  const assertions: string[] = [];
  let pass = true;
  let error: string | undefined;

  try {
    const sku = `CRASH-${randomUUID()}`;
    const item = await createCatalogItem({
      sku,
      name: 'Resilient Widget',
      description: 'acceptance check 2 item',
      price: 1000,
      stock: 5,
    });

    await dockerPause(CONTAINERS.payment);

    let orderId = '';
    try {
      const userEmail = `${randomUUID()}@example.com`;
      const order = await createOrder({ userEmail, items: [{ sku: item.id, qty: 1, price: 1000 }] });
      orderId = order.id;
      assertions.push(assert('order starts PENDING', order.status === 'PENDING', `status=${order.status}`));

      const sagaLogCol = await orderDb.sagaLog();
      const sagaAfterReserve = await pollUntil(
        () => sagaLogCol.findOne({ orderId: order.id }),
        (doc) => doc?.state === 'INVENTORY_RESERVED',
        { timeoutMs: 20_000, description: `saga for order ${order.id} to reach INVENTORY_RESERVED` },
      );
      assertions.push(assert('saga reached INVENTORY_RESERVED with charge in flight', sagaAfterReserve?.currentStep === 'charge', `currentStep=${sagaAfterReserve?.currentStep}`));

      await dockerKill(CONTAINERS.order);
      const statusAfterKill = await dockerInspectStatus(CONTAINERS.order);
      assertions.push(assert('order-service container exited', statusAfterKill === 'exited', `status=${statusAfterKill}`));

      await dockerStart(CONTAINERS.order);
    } finally {
      await dockerUnpause(CONTAINERS.payment);
    }

    await waitForAllServicesHealthy(60_000);

    const finalOrder = await pollUntil(() => getOrder(orderId), (o) => o.status !== 'PENDING', {
      timeoutMs: 40_000,
      description: `order ${orderId} to leave PENDING after restart`,
    });
    assertions.push(assert('order resumed to CONFIRMED after restart', finalOrder.status === 'CONFIRMED', `status=${finalOrder.status}`));

    const paymentsCol = await paymentDb.payments();
    const payments = await paymentsCol.find({ orderId }).toArray();
    assertions.push(assert('exactly one Payment (no duplicate charge)', payments.length === 1, `count=${payments.length}`));
    assertions.push(assert('payment SUCCEEDED', payments[0]?.status === 'SUCCEEDED', `status=${payments[0]?.status}`));

    const paymentStepResultsCol = await paymentDb.sagaStepResults();
    const paymentStepResults = payments[0] ? await paymentStepResultsCol.find({ sagaId: payments[0].sagaId }).toArray() : [];
    const chargeStepResults = paymentStepResults.filter((r) => r.step === 'charge');
    assertions.push(assert('exactly one charge step-result (idempotency held)', chargeStepResults.length === 1, `count=${chargeStepResults.length}`));

    const items = await catalogDb.items();
    const catalogDoc = await items.findOne({ _id: new ObjectId(item.id) });
    assertions.push(assert('inventory reserved exactly once (no double-reserve)', catalogDoc?.reserved === 1, `reserved=${catalogDoc?.reserved}`));

    const catalogStepResultsCol = await catalogDb.sagaStepResults();
    const catalogStepResults = payments[0] ? await catalogStepResultsCol.find({ sagaId: payments[0].sagaId }).toArray() : [];
    const reserveStepResults = catalogStepResults.filter((r) => r.step === 'reserve-inventory');
    assertions.push(assert('exactly one reserve-inventory step-result', reserveStepResults.length === 1, `count=${reserveStepResults.length}`));

    const sagaLogCol = await orderDb.sagaLog();
    const finalSagaLog = await sagaLogCol.findOne({ orderId });
    const stepHistory = finalSagaLog?.stepHistory ?? [];
    const expected = ['reserve-inventory:sent', 'reserve-inventory:succeeded', 'charge:sent', 'charge:succeeded'];
    const actual = stepHistory.map((e) => `${e.step}:${e.status}`);
    assertions.push(assert('no duplicate saga_log steps from crash/restart/redelivery', JSON.stringify(actual) === JSON.stringify(expected), `actual=${JSON.stringify(actual)}`));

    pass = assertions.every((a) => a.startsWith('PASS'));

    ev.push(
      evidence(
        'Order / payment / catalog / saga_log evidence',
        [
          `orderId: ${orderId}`,
          `final order status: ${finalOrder.status}`,
          `payments for order: ${payments.length} (status=${payments[0]?.status})`,
          `catalog reserved: ${catalogDoc?.reserved}`,
          `saga_log stepHistory: ${JSON.stringify(actual)}`,
        ].join('\n'),
      ),
    );
    ev.push(evidence('Assertions', assertions.join('\n')));
  } catch (err) {
    pass = false;
    error = err instanceof Error ? `${err.message}\n${err.stack}` : String(err);
    ev.push(evidence('Assertions before failure', assertions.join('\n')));
  } finally {
    // Defensive cleanup mirroring 03-crash-mid-saga.spec.ts's afterAll, so a
    // failed assertion above never leaves the shared stack paused/down for
    // the next check or the next run of this harness.
    try {
      if ((await dockerInspectStatus(CONTAINERS.payment)) === 'paused') await dockerUnpause(CONTAINERS.payment);
      if ((await dockerInspectStatus(CONTAINERS.order)) !== 'running') await dockerStart(CONTAINERS.order);
      await waitForAllServicesHealthy(60_000);
    } catch (cleanupErr) {
      ev.push(evidence('Cleanup warning', String(cleanupErr)));
    }
  }

  const finishedAt = new Date();
  return {
    id: 'check-2-crash-resume',
    title: 'Kill mid-saga + restart → correct resume, no double effects',
    criterion: 'Killing the service mid-saga and restarting resumes correctly (idempotent, no double effects).',
    pass,
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAt.getTime(),
    evidence: ev,
    summary: pass ? 'order-service killed after reserve-inventory succeeded and charge was in flight; restarted; saga resumed to CONFIRMED with exactly one charge and one reservation.' : 'One or more assertions failed or the scenario errored — see evidence.',
    error,
  };
}

function assert(label: string, ok: boolean, detail: string): string {
  return `${ok ? 'PASS' : 'FAIL'}: ${label} (${detail})`;
}
