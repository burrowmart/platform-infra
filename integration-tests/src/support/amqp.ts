import * as amqplib from 'amqplib';
import { RABBITMQ_URL } from './config';

export interface CapturedMessage<T = unknown> {
  envelope: T & { type?: string; correlationId?: string; sagaId?: string; payload?: unknown };
  properties: amqplib.MessageProperties;
}

/**
 * Binds a throwaway exclusive queue to an exchange/routingKey and lets tests
 * poll for a matching message without stealing it from the real consumer —
 * direct/topic exchanges fan out to every bound queue, so this is a pure
 * observer.
 */
export class AmqpProbe {
  private conn?: amqplib.ChannelModel;
  private ch?: amqplib.Channel;
  private queue = '';

  async bind(exchange: string, routingKey: string, exchangeType: 'topic' | 'direct'): Promise<void> {
    this.conn = await amqplib.connect(RABBITMQ_URL);
    this.ch = await this.conn.createChannel();
    await this.ch.assertExchange(exchange, exchangeType, { durable: true });
    const q = await this.ch.assertQueue('', { exclusive: true, autoDelete: true });
    this.queue = q.queue;
    await this.ch.bindQueue(this.queue, exchange, routingKey);
  }

  async waitForMessage<T = unknown>(
    predicate: (msg: CapturedMessage<T>) => boolean,
    timeoutMs: number,
  ): Promise<CapturedMessage<T>> {
    if (!this.ch) throw new Error('AmqpProbe.bind() must be called before waitForMessage()');
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const msg = await this.ch.get(this.queue, { noAck: true });
      if (msg) {
        const envelope = JSON.parse(msg.content.toString()) as CapturedMessage<T>['envelope'];
        const captured: CapturedMessage<T> = { envelope, properties: msg.properties };
        if (predicate(captured)) return captured;
      } else {
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
    }
    throw new Error(
      `AmqpProbe timed out after ${timeoutMs}ms waiting for a matching message on queue bound to ${this.queue}`,
    );
  }

  async close(): Promise<void> {
    await this.ch?.close().catch(() => undefined);
    await this.conn?.close().catch(() => undefined);
  }
}
