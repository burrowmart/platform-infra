import { randomUUID } from 'crypto';
import { EXCHANGES, ROUTING_KEYS } from '../src/support/config';
import { createCatalogItem, createOrder, getOrder, getPayments, waitForAllServicesHealthy } from '../src/support/http';
import { catalogDb, closeMongo, ObjectId } from '../src/support/mongo';
import { pollUntil } from '../src/support/poll';
import { AmqpProbe } from '../src/support/amqp';

describe('saga: happy path', () => {
  beforeAll(async () => {
    await waitForAllServicesHealthy();
  }, 100_000);

  afterAll(async () => {
    await closeMongo();
  });

  it('reserves stock, charges payment, confirms the order, and publishes order-confirmed', async () => {
    const sku = `HAPPY-${randomUUID()}`;
    const item = await createCatalogItem({
      sku,
      name: 'Widget',
      description: 'happy-path integration test item',
      price: 1000,
      stock: 10,
    });

    // Bind before placing the order — order-confirmed is published within
    // milliseconds of payment succeeding, so binding after POST /orders would race it.
    const confirmedProbe = new AmqpProbe();
    await confirmedProbe.bind(EXCHANGES.DOMAIN_EVENTS, ROUTING_KEYS.ORDER_CONFIRMED, 'topic');

    try {
      const userEmail = `${randomUUID()}@example.com`;
      const order = await createOrder({
        userEmail,
        // sku here must be the catalog item's Mongo _id, not its business `sku`
        // string — order-orchestrator forwards items[].sku verbatim as
        // catalogItemId, and catalog-service looks reservations up by _id.
        items: [{ sku: item.id, qty: 2, price: 1000 }],
      });
      expect(order.status).toBe('PENDING');

      const finalOrder = await pollUntil(() => getOrder(order.id), (o) => o.status !== 'PENDING', {
        timeoutMs: 30_000,
        description: `order ${order.id} to leave PENDING`,
      });
      expect(finalOrder.status).toBe('CONFIRMED');

      // reserved/stock are never exposed over REST (catalog-service's toResponse
      // omits them) — read them straight from Mongo.
      const items = await catalogDb.items();
      const catalogDoc = await pollUntil(() => items.findOne({ _id: new ObjectId(item.id) }), (doc) => doc?.reserved === 2, {
        timeoutMs: 10_000,
        description: `catalog item ${item.id} reserved to reach 2`,
      });
      expect(catalogDoc?.reserved).toBe(2);
      expect(catalogDoc?.stock).toBe(10);

      const payments = await pollUntil(() => getPayments({ orderId: order.id }), (p) => p.data.length > 0, {
        timeoutMs: 10_000,
        description: `a payment to exist for order ${order.id}`,
      });
      expect(payments.data).toHaveLength(1);
      expect(payments.data[0].status).toBe('SUCCEEDED');

      const { envelope } = await confirmedProbe.waitForMessage(
        (m) => (m.envelope.payload as { orderId?: string } | undefined)?.orderId === order.id,
        15_000,
      );
      expect(envelope.type).toBe('order-confirmed');
    } finally {
      await confirmedProbe.close();
    }
  });
});
