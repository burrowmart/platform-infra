/** Endpoints/containers this suite targets — the stack started by
 * `docker-compose.yml` + `docker-compose.test.yml` (see package.json's
 * compose:up script). Overridable via env for CI runners that publish
 * different host ports. */

export const ORDER_URL = process.env.ORDER_URL ?? 'http://localhost:4001';
export const CATALOG_URL = process.env.CATALOG_URL ?? 'http://localhost:4002';
export const PAYMENT_URL = process.env.PAYMENT_URL ?? 'http://localhost:4003';

// Port 27018 (not the usual 27017): this stack's docker-compose.test.yml
// publishes Mongo there specifically because 27017 on this host is also
// claimed by an unrelated native mongod, which silently wins routing for
// "localhost:27017" — see the comment on the `mongo` service override.
// directConnection=true is required on top of that: the replica set's member
// is advertised as `mongo:27017` (so sibling app containers can reach it),
// which isn't resolvable from the host — directConnection skips that
// redirect and talks to the given host:port as-is, all this read-only test
// client needs.
export const MONGO_URI = process.env.MONGO_URI ?? 'mongodb://localhost:27018/?directConnection=true';
export const RABBITMQ_URL = process.env.RABBITMQ_URL ?? 'amqp://guest:guest@localhost:5672';

// Must match docker-compose.test.yml's container_name for each app service.
export const CONTAINERS = {
  order: 'order-service-it',
  catalog: 'catalog-service-it',
  payment: 'payment-service-it',
} as const;

// Must match docker-compose.test.yml's MONGO_URI database name per service.
export const DB_NAMES = {
  order: 'orders_it',
  catalog: 'catalog_it',
  payment: 'payments_it',
} as const;

// Must match docker-compose.test.yml's FAIL_PAYMENT_OVER_AMOUNT on payment-service.
export const FAIL_PAYMENT_OVER_AMOUNT = 5000;

export const EXCHANGES = {
  SAGA_COMMANDS: 'saga.commands',
  SAGA_REPLIES: 'saga.replies',
  DOMAIN_EVENTS: 'domain.events',
} as const;

export const ROUTING_KEYS = {
  RESERVE_INVENTORY: 'reserve-inventory',
  CHARGE: 'charge',
  RELEASE_INVENTORY: 'release-inventory',
  ORDER_CONFIRMED: 'order-confirmed',
  ORDER_CANCELLED: 'order-cancelled',
} as const;
