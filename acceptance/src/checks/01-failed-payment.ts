/** Criterion 1: "A failed payment triggers compensations (release inventory,
 * cancel order) and the order ends CANCELLED."
 *
 * Reuses T2.5 scenario 2 (integration-tests/test/02-failed-payment.spec.ts)
 * verbatim for the scenario mechanics (over-threshold order -> real
 * payment-service FAIL_PAYMENT_OVER_AMOUNT rejection -> compensation), via
 * the same support libs — but the assertions run here, in this harness, per
 * the task's "assert from this harness" instruction, and every observed
 * value is captured as report evidence rather than only pass/fail. */

import { randomUUID } from 'crypto';
import { FAIL_PAYMENT_OVER_AMOUNT } from '../../../integration-tests/src/support/config';
import { createCatalogItem, createOrder, getOrder, getPayments } from '../../../integration-tests/src/support/http';
import { catalogDb, ObjectId, orderDb } from '../../../integration-tests/src/support/mongo';
import { pollUntil } from '../../../integration-tests/src/support/poll';
import { evidence } from '../lib/types';
import type { CheckResult } from '../lib/types';

const OVER_THRESHOLD_QTY = 10;
const UNIT_PRICE = 1000; // total = 10_000 > FAIL_PAYMENT_OVER_AMOUNT (5_000)

export async function checkFailedPayment(): Promise<CheckResult> {
  const startedAt = new Date();
  const ev: CheckResult['evidence'] = [];
  const assertions: string[] = [];
  let pass = true;
  let error: string | undefined;

  try {
    const sku = `FAIL-${randomUUID()}`;
    const item = await createCatalogItem({
      sku,
      name: 'Expensive Widget',
      description: 'acceptance check 1 item',
      price: UNIT_PRICE,
      stock: 50,
    });

    const userEmail = `${randomUUID()}@example.com`;
    const order = await createOrder({ userEmail, items: [{ sku: item.id, qty: OVER_THRESHOLD_QTY, price: UNIT_PRICE }] });
    assertions.push(assert('order total exceeds FAIL_PAYMENT_OVER_AMOUNT', order.total > FAIL_PAYMENT_OVER_AMOUNT, `total=${order.total} threshold=${FAIL_PAYMENT_OVER_AMOUNT}`));
    assertions.push(assert('order starts PENDING', order.status === 'PENDING', `status=${order.status}`));

    const finalOrder = await pollUntil(() => getOrder(order.id), (o) => o.status !== 'PENDING', {
      timeoutMs: 30_000,
      description: `order ${order.id} to leave PENDING`,
    });
    assertions.push(assert('order ends CANCELLED', finalOrder.status === 'CANCELLED', `status=${finalOrder.status}`));

    const items = await catalogDb.items();
    const catalogDoc = await pollUntil(() => items.findOne({ _id: new ObjectId(item.id) }), (doc) => doc?.reserved === 0, {
      timeoutMs: 15_000,
      description: `catalog item ${item.id} reserved released to 0`,
    });
    assertions.push(assert('inventory reservation released (reserved=0)', catalogDoc?.reserved === 0, `reserved=${catalogDoc?.reserved}`));
    assertions.push(assert('stock untouched', catalogDoc?.stock === 50, `stock=${catalogDoc?.stock}`));

    const payments = await pollUntil(() => getPayments({ orderId: order.id }), (p) => p.data.length > 0, {
      timeoutMs: 10_000,
      description: `a payment to exist for order ${order.id}`,
    });
    assertions.push(assert('exactly one payment attempt', payments.data.length === 1, `count=${payments.data.length}`));
    assertions.push(assert('payment FAILED', payments.data[0]?.status === 'FAILED', `status=${payments.data[0]?.status}`));

    const sagaLogCol = await orderDb.sagaLog();
    const sagaLog = await pollUntil(() => sagaLogCol.findOne({ orderId: order.id }), (doc) => doc?.state === 'CANCELLED', {
      timeoutMs: 15_000,
      description: `saga_log for order ${order.id} to reach CANCELLED`,
    });
    assertions.push(assert('saga_log reached CANCELLED', !!sagaLog, `found=${!!sagaLog}`));

    const stepHistory = sagaLog?.stepHistory ?? [];
    const chargeFailed = stepHistory.some((e) => e.step === 'charge' && e.status === 'failed');
    assertions.push(assert("charge step recorded 'failed'", chargeFailed, JSON.stringify(stepHistory.filter((e) => e.step === 'charge'))));

    const succeededSteps = stepHistory.filter((e) => e.status === 'succeeded').map((e) => e.step);
    assertions.push(assert('only reserve-inventory succeeded before charge failed', JSON.stringify(succeededSteps) === JSON.stringify(['reserve-inventory']), JSON.stringify(succeededSteps)));

    const stepCompensations: Record<string, string> = { 'reserve-inventory': 'release-inventory', charge: 'refund-payment' };
    const compensationStepNames = new Set(Object.values(stepCompensations));
    const compensationsSent = stepHistory.filter((e) => e.status === 'sent' && compensationStepNames.has(e.step)).map((e) => e.step);
    const expectedCompensations = [...succeededSteps].reverse().map((step) => stepCompensations[step]);
    assertions.push(
      assert(
        'compensation(s) dispatched in reverse order',
        JSON.stringify(compensationsSent) === JSON.stringify(expectedCompensations),
        `sent=${JSON.stringify(compensationsSent)} expected=${JSON.stringify(expectedCompensations)}`,
      ),
    );

    pass = assertions.every((a) => a.startsWith('PASS'));

    ev.push(
      evidence(
        'Order / catalog / payment / saga_log evidence',
        [
          `orderId: ${order.id}`,
          `catalogItemId: ${item.id}`,
          `final order status: ${finalOrder.status}`,
          `catalog reserved/stock: ${catalogDoc?.reserved}/${catalogDoc?.stock}`,
          `payment status: ${payments.data[0]?.status}`,
          `saga_log state: ${sagaLog?.state}`,
          `saga_log stepHistory: ${JSON.stringify(stepHistory.map((e) => `${e.step}:${e.status}`))}`,
        ].join('\n'),
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
    id: 'check-1-compensation',
    title: 'Failed payment → compensations → order CANCELLED',
    criterion: 'A failed payment triggers compensations (release inventory, cancel order) and the order ends CANCELLED.',
    pass,
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAt.getTime(),
    evidence: ev,
    summary: pass ? 'Over-threshold order rejected by payment-service, compensations dispatched in reverse order, order ended CANCELLED.' : 'One or more assertions failed or the scenario errored — see evidence.',
    error,
  };
}

function assert(label: string, ok: boolean, detail: string): string {
  return `${ok ? 'PASS' : 'FAIL'}: ${label} (${detail})`;
}
