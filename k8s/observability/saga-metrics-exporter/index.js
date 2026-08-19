// See README.md for why this exists as a standalone exporter instead of
// instrumentation inside order-service.
'use strict';

const http = require('http');
const { MongoClient } = require('mongodb');
const { Registry, Gauge, collectDefaultMetrics } = require('prom-client');

const MONGO_URI = process.env.MONGO_URI;
const PORT = Number(process.env.PORT || 9308);

if (!MONGO_URI) {
  console.error('MONGO_URI is required (same value order-service itself uses)');
  process.exit(1);
}

// Mirrors order-service/src/order-orchestrator/state-machine.ts's SAGA_STATES
// — duplicated rather than imported since this exporter deliberately has no
// dependency on order-service's source (see README.md).
const SAGA_STATES = ['STARTED', 'INVENTORY_RESERVED', 'PAYMENT_SUCCEEDED', 'CONFIRMED', 'CANCELLED'];

const register = new Registry();
collectDefaultMetrics({ register });

let db;

const sagaStateGauge = new Gauge({
  name: 'saga_terminal_state_total',
  help: 'Current count of saga_log documents per SagaState. Terminal states are CONFIRMED/CANCELLED; the rest are in-flight sagas.',
  labelNames: ['state'],
  registers: [register],
  async collect() {
    // Zero every known state first — otherwise a state that drops to 0
    // documents keeps reporting its last nonzero value forever (Gauge.set
    // only overwrites labels it's actually called with).
    for (const state of SAGA_STATES) {
      this.set({ state }, 0);
    }
    const rows = await db
      .collection('saga_log')
      .aggregate([{ $group: { _id: '$state', count: { $sum: 1 } } }])
      .toArray();
    for (const row of rows) {
      this.set({ state: row._id }, row.count);
    }
  },
});

const server = http.createServer(async (req, res) => {
  if (req.url === '/metrics') {
    try {
      res.setHeader('Content-Type', register.contentType);
      res.end(await register.metrics());
    } catch (err) {
      res.statusCode = 500;
      res.end(String(err));
    }
    return;
  }
  if (req.url === '/health') {
    res.statusCode = db ? 200 : 503;
    res.end();
    return;
  }
  res.statusCode = 404;
  res.end();
});

MongoClient.connect(MONGO_URI).then((client) => {
  db = client.db();
  server.listen(PORT, () => {
    console.log(`saga-metrics-exporter listening on :${PORT}, reading saga_log from ${db.databaseName}`);
  });
});

process.on('SIGTERM', () => process.exit(0));
