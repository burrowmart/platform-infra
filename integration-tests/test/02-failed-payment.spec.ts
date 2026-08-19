import { randomUUID } from 'crypto';
import { FAIL_PAYMENT_OVER_AMOUNT } from '../src/support/config';
import { createCatalogItem, createOrder, getOrder, getPayments, waitForAllServicesHealthy } from '../src/support/http';
import { catalogDb, closeMongo, ObjectId, orderDb } from '../src/support/mongo';
import { pollUntil } from '../src/support/poll';

// payment-service's real fail trigger is FAIL_PAYMENT_OVER_AMOUNT (see
// docker-compose.test.yml), not a client-suppliable `forceFail` flag —
// CreateOrderDto has no such field, and it's rejected by order-service's
// forbidNonWhitelisted ValidationPipe even if sent. An order priced above
// the threshold exercises the exact same real, non-mocked failure path.
const OVER_THRESHOLD_QTY = 10;
const UNIT_PRICE = 1000; // total = 10_000 > FAIL_PAYMENT_OVER_AMOUNT (5_000)

describe('saga: failed payment triggers compensation', () => {
  beforeAll(async () => {
    await waitForAllServicesHealthy();
  }, 100_000);

  afterAll(async () => {
    await closeMongo();
  });

  it('cancels the order, releases inventory, and records compensations in saga_log in reverse order', async () => {
    const sku = `FAIL-${randomUUID()}`;
    const item = await createCatalogItem({
      sku,
      name: 'Expensive Widget',
      description: 'failed-payment integration test item',
      price: UNIT_PRICE,
      stock: 50,
    });

    const userEmail = `${randomUUID()}@example.com`;
    const order = await createOrder({
      userEmail,
      items: [{ sku: item.id, qty: OVER_THRESHOLD_QTY, price: UNIT_PRICE }],
    });
    expect(order.total).toBeGreaterThan(FAIL_PAYMENT_OVER_AMOUNT);
    expect(order.status).toBe('PENDING');

    const finalOrder = await pollUntil(() => getOrder(order.id), (o) => o.status !== 'PENDING', {
      timeoutMs: 30_000,
      description: `order ${order.id} to leave PENDING`,
    });
    expect(finalOrder.status).toBe('CANCELLED');

    const items = await catalogDb.items();
    const catalogDoc = await pollUntil(() => items.findOne({ _id: new ObjectId(item.id) }), (doc) => doc?.reserved === 0, {
      timeoutMs: 15_000,
      description: `catalog item ${item.id} reserved to be released back to 0`,
    });
    expect(catalogDoc?.reserved).toBe(0);
    expect(catalogDoc?.stock).toBe(50);

    const payments = await pollUntil(() => getPayments({ orderId: order.id }), (p) => p.data.length > 0, {
      timeoutMs: 10_000,
      description: `a payment to exist for order ${order.id}`,
    });
    expect(payments.data).toHaveLength(1);
    expect(payments.data[0].status).toBe('FAILED');

    const sagaLogCol = await orderDb.sagaLog();
    const sagaLog = await pollUntil(() => sagaLogCol.findOne({ orderId: order.id }), (doc) => doc?.state === 'CANCELLED', {
      timeoutMs: 15_000,
      description: `saga_log for order ${order.id} to reach CANCELLED`,
    });
    expect(sagaLog).toBeTruthy();

    const stepHistory = sagaLog!.stepHistory;

    // The step that actually failed is recorded as such.
    expect(stepHistory.some((e) => e.step === 'charge' && e.status === 'failed')).toBe(true);

    const succeededSteps = stepHistory.filter((e) => e.status === 'succeeded').map((e) => e.step);
    // Only reserve-inventory can have succeeded before charge failed — charge
    // itself never reaches 'succeeded' on this path, and it's the only step
    // after reserve-inventory in this saga (see order-orchestrator's
    // STEP_COMPENSATIONS: charge's own compensation, refund-payment, is
    // structurally unreachable — there is no step after a successful charge).
    expect(succeededSteps).toEqual(['reserve-inventory']);

    // Compensation commands ('sent') dispatched for the succeeded steps, each
    // mapped to its own compensation step name (order-orchestrator's
    // STEP_COMPENSATIONS: reserve-inventory -> release-inventory,
    // charge -> refund-payment), strictly in reverse order of succeededSteps.
    const stepCompensations: Record<string, string> = {
      'reserve-inventory': 'release-inventory',
      charge: 'refund-payment',
    };
    const compensationStepNames = new Set(Object.values(stepCompensations));
    const compensationsSent = stepHistory
      .filter((e) => e.status === 'sent' && compensationStepNames.has(e.step))
      .map((e) => e.step);
    const expectedCompensations = [...succeededSteps].reverse().map((step) => stepCompensations[step]);
    expect(compensationsSent).toEqual(expectedCompensations);
  });
});
