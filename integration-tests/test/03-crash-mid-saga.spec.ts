import { randomUUID } from 'crypto';
import { CONTAINERS } from '../src/support/config';
import { dockerInspectStatus, dockerKill, dockerPause, dockerStart, dockerUnpause } from '../src/support/docker';
import { createCatalogItem, createOrder, getOrder, getPayments, waitForAllServicesHealthy } from '../src/support/http';
import { catalogDb, closeMongo, ObjectId, orderDb, paymentDb } from '../src/support/mongo';
import { pollUntil } from '../src/support/poll';

describe('saga: crash mid-saga (order-service killed and restarted)', () => {
  beforeAll(async () => {
    await waitForAllServicesHealthy();
  }, 100_000);

  afterAll(async () => {
    // Defensive cleanup so a failed assertion above never leaves the shared
    // stack paused/down for the next scenario file.
    if ((await dockerInspectStatus(CONTAINERS.payment)) === 'paused') {
      await dockerUnpause(CONTAINERS.payment);
    }
    if ((await dockerInspectStatus(CONTAINERS.order)) !== 'running') {
      await dockerStart(CONTAINERS.order);
    }
    await waitForAllServicesHealthy();
    await closeMongo();
  }, 100_000);

  it('resumes and completes exactly once after order-service is killed mid-saga', async () => {
    const sku = `CRASH-${randomUUID()}`;
    const item = await createCatalogItem({
      sku,
      name: 'Resilient Widget',
      description: 'crash-mid-saga integration test item',
      price: 1000, // well under FAIL_PAYMENT_OVER_AMOUNT so payment succeeds once unpaused
      stock: 5,
    });

    // Freeze payment-service so the charge command it will receive sits
    // unconsumed — this holds the saga open at INVENTORY_RESERVED/charge long
    // enough to kill+restart order-service while a step is genuinely in flight.
    await dockerPause(CONTAINERS.payment);

    let order: Awaited<ReturnType<typeof createOrder>>;
    try {
      const userEmail = `${randomUUID()}@example.com`;
      order = await createOrder({ userEmail, items: [{ sku: item.id, qty: 1, price: 1000 }] });
      expect(order.status).toBe('PENDING');

      const sagaLogCol = await orderDb.sagaLog();
      const sagaAfterReserve = await pollUntil(
        () => sagaLogCol.findOne({ orderId: order.id }),
        (doc) => doc?.state === 'INVENTORY_RESERVED',
        { timeoutMs: 20_000, description: `saga for order ${order.id} to reach INVENTORY_RESERVED (reserve-inventory complete)` },
      );
      expect(sagaAfterReserve?.currentStep).toBe('charge');

      // Simulate the orchestrator crashing right after dispatching charge.
      await dockerKill(CONTAINERS.order);
      expect(await dockerInspectStatus(CONTAINERS.order)).toBe('exited');

      await dockerStart(CONTAINERS.order);
    } finally {
      // Give payment-service the charge command to process now that
      // order-service is (or is about to be) back up to receive its reply.
      await dockerUnpause(CONTAINERS.payment);
    }

    await waitForAllServicesHealthy(60_000);

    const finalOrder = await pollUntil(() => getOrder(order.id), (o) => o.status !== 'PENDING', {
      timeoutMs: 40_000,
      description: `order ${order.id} to leave PENDING after order-service restart`,
    });
    expect(finalOrder.status).toBe('CONFIRMED');

    // Exactly one Payment — proves payment-service's (sagaId, step) idempotency
    // held even with the restart/redelivery window.
    const paymentsCol = await paymentDb.payments();
    const payments = await paymentsCol.find({ orderId: order.id }).toArray();
    expect(payments).toHaveLength(1);
    expect(payments[0].status).toBe('SUCCEEDED');

    const paymentStepResultsCol = await paymentDb.sagaStepResults();
    const paymentStepResults = await paymentStepResultsCol.find({ sagaId: payments[0].sagaId }).toArray();
    expect(paymentStepResults.filter((r) => r.step === 'charge')).toHaveLength(1);

    // reserved is consistent — incremented exactly once (never double-reserved
    // by a redelivered/replayed reserve-inventory command).
    const items = await catalogDb.items();
    const catalogDoc = await items.findOne({ _id: new ObjectId(item.id) });
    expect(catalogDoc?.reserved).toBe(1);

    const catalogStepResultsCol = await catalogDb.sagaStepResults();
    const catalogStepResults = await catalogStepResultsCol.find({ sagaId: payments[0].sagaId }).toArray();
    expect(catalogStepResults.filter((r) => r.step === 'reserve-inventory')).toHaveLength(1);

    // No duplicate saga_log steps: exactly the 4 expected entries — sent+succeeded
    // for reserve-inventory, sent+succeeded for charge — no extra timeout-retry
    // 'sent' entries and no duplicate 'succeeded' entries from a redelivered reply.
    const sagaLogCol = await orderDb.sagaLog();
    const finalSagaLog = await sagaLogCol.findOne({ orderId: order.id });
    expect(finalSagaLog?.stepHistory).toHaveLength(4);
    expect(finalSagaLog?.stepHistory.map((e) => `${e.step}:${e.status}`)).toEqual([
      'reserve-inventory:sent',
      'reserve-inventory:succeeded',
      'charge:sent',
      'charge:succeeded',
    ]);
  }, 110_000);
});
