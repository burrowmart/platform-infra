import { Collection, Db, Document, MongoClient, ObjectId } from 'mongodb';
import { DB_NAMES, MONGO_URI } from './config';

let client: MongoClient | undefined;

export async function getMongoClient(): Promise<MongoClient> {
  if (!client) {
    client = new MongoClient(MONGO_URI);
    await client.connect();
  }
  return client;
}

export async function closeMongo(): Promise<void> {
  await client?.close();
  client = undefined;
}

export interface CatalogItemDoc {
  _id: ObjectId;
  sku: string;
  stock: number;
  reserved: number;
}

export interface SagaLogStepHistoryEntry {
  step: string;
  status: 'sent' | 'succeeded' | 'failed';
  messageId: string;
  at: Date;
}

export interface SagaLogDoc {
  sagaId: string;
  orderId: string;
  correlationId: string;
  currentStep: string;
  stepHistory: SagaLogStepHistoryEntry[];
  state: 'STARTED' | 'INVENTORY_RESERVED' | 'PAYMENT_SUCCEEDED' | 'CONFIRMED' | 'CANCELLED';
}

export interface PaymentDoc {
  orderId: string;
  sagaId: string;
  status: 'PENDING' | 'SUCCEEDED' | 'FAILED' | 'REFUNDED';
}

export interface SagaStepResultDoc {
  sagaId: string;
  step: string;
}

async function collection<T extends Document>(
  dbName: string,
  collectionName: string,
): Promise<Collection<T>> {
  const c = await getMongoClient();
  const db: Db = c.db(dbName);
  return db.collection<T>(collectionName);
}

export const orderDb = {
  sagaLog: () => collection<SagaLogDoc>(DB_NAMES.order, 'saga_log'),
};

export const catalogDb = {
  items: () => collection<CatalogItemDoc>(DB_NAMES.catalog, 'catalog_items'),
  sagaStepResults: () => collection<SagaStepResultDoc>(DB_NAMES.catalog, 'saga_step_results'),
};

export const paymentDb = {
  payments: () => collection<PaymentDoc>(DB_NAMES.payment, 'payments'),
  sagaStepResults: () => collection<SagaStepResultDoc>(DB_NAMES.payment, 'saga_step_results'),
};

export { ObjectId };
