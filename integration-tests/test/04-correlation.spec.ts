import { randomUUID } from 'crypto';
import { CONTAINERS, EXCHANGES, ROUTING_KEYS } from '../src/support/config';
import { dockerLogs } from '../src/support/docker';
import { createCatalogItem, createOrder, getOrder, waitForAllServicesHealthy } from '../src/support/http';
import { closeMongo } from '../src/support/mongo';
import { pollUntil } from '../src/support/poll';
import { AmqpProbe } from '../src/support/amqp';

describe('saga: cf-ray correlation id propagation', () => {
  beforeAll(async () => {
    await waitForAllServicesHealthy();
  }, 100_000);

  afterAll(async () => {
    await closeMongo();
  });

  it('carries one cf-ray value across all three services\' logs and onto the RabbitMQ message properties', async () => {
    // Unique per run (rather than the literal "SAGA-RAY-1") so re-running the
    // suite back-to-back can't have a stale match from the previous run mask
    // a real propagation bug in this run.
    const rayId = `SAGA-RAY-${randomUUID()}`;

    const sku = `RAY-${randomUUID()}`;
    const item = await createCatalogItem({
      sku,
      name: 'Traceable Widget',
      description: 'correlation integration test item',
      price: 1000,
      stock: 5,
    });

    // Bind before POSTing — captures the charge command's native AMQP
    // `correlationId` property as dispatched by the orchestrator.
    const chargeProbe = new AmqpProbe();
    await chargeProbe.bind(EXCHANGES.SAGA_COMMANDS, ROUTING_KEYS.CHARGE, 'direct');

    try {
      const userEmail = `${randomUUID()}@example.com`;
      const order = await createOrder(
        { userEmail, items: [{ sku: item.id, qty: 1, price: 1000 }] },
        { 'cf-ray': rayId },
      );

      const finalOrder = await pollUntil(() => getOrder(order.id), (o) => o.status !== 'PENDING', {
        timeoutMs: 30_000,
        description: `order ${order.id} to leave PENDING`,
      });
      expect(finalOrder.status).toBe('CONFIRMED');

      const { properties } = await chargeProbe.waitForMessage(
        (m) => (m.envelope.payload as { orderId?: string } | undefined)?.orderId === order.id,
        15_000,
      );
      expect(properties.correlationId).toBe(rayId);

      // Log lines are written well before the order reaches CONFIRMED above,
      // but poll briefly anyway to absorb any stdout flush lag.
      for (const [name, container] of Object.entries(CONTAINERS)) {
        await pollUntil(() => dockerLogs(container), (logs) => logs.includes(rayId), {
          timeoutMs: 10_000,
          intervalMs: 500,
          description: `${name}-service (${container}) logs to contain ${rayId}`,
        });
      }
    } finally {
      await chargeProbe.close();
    }
  });
});
