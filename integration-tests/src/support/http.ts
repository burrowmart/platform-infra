import { CATALOG_URL, ORDER_URL, PAYMENT_URL } from './config';
import { pollUntil } from './poll';

export interface OrderItem {
  sku: string;
  qty: number;
  price: number;
}

export interface Order {
  id: string;
  userEmail: string;
  items: OrderItem[];
  total: number;
  status: 'PENDING' | 'CONFIRMED' | 'CANCELLED';
  sagaId?: string;
  createdAt: string;
  updatedAt: string;
}

export interface CatalogItem {
  id: string;
  name: string;
  description: string;
  price: number;
  stock: number;
  createdAt: string;
  updatedAt: string;
}

export interface Payment {
  id: string;
  orderId: string;
  userId: string;
  amount: number;
  status: 'PENDING' | 'SUCCEEDED' | 'FAILED' | 'REFUNDED';
  createdAt: string;
  updatedAt: string;
}

export interface Paginated<T> {
  data: T[];
  total: number;
  page: number;
  limit: number;
}

async function asJson<T>(res: Response): Promise<T> {
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} ${res.statusText} for ${res.url}: ${text}`);
  }
  return text ? (JSON.parse(text) as T) : (undefined as T);
}

export async function createCatalogItem(input: {
  sku: string;
  name: string;
  description: string;
  price: number;
  stock: number;
}): Promise<CatalogItem> {
  const res = await fetch(`${CATALOG_URL}/catalog`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(input),
  });
  return asJson<CatalogItem>(res);
}

export async function createOrder(
  input: { userEmail: string; items: OrderItem[] },
  headers: Record<string, string> = {},
): Promise<Order> {
  const res = await fetch(`${ORDER_URL}/orders`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(input),
  });
  return asJson<Order>(res);
}

export async function getOrder(id: string): Promise<Order> {
  const res = await fetch(`${ORDER_URL}/orders/${id}`);
  return asJson<Order>(res);
}

export async function getPayments(query: { orderId?: string }): Promise<Paginated<Payment>> {
  const params = new URLSearchParams();
  if (query.orderId) params.set('orderId', query.orderId);
  const res = await fetch(`${PAYMENT_URL}/payments?${params.toString()}`);
  return asJson<Paginated<Payment>>(res);
}

async function isHealthy(baseUrl: string): Promise<boolean> {
  try {
    const res = await fetch(`${baseUrl}/health`);
    return res.status === 200;
  } catch {
    return false;
  }
}

/** Waits for order/catalog/payment services to answer GET /health — used at
 * the top of every scenario so a slow container start doesn't read as a
 * saga-logic failure. */
export async function waitForAllServicesHealthy(timeoutMs = 90000): Promise<void> {
  for (const [name, url] of [
    ['order-service', ORDER_URL],
    ['catalog-service', CATALOG_URL],
    ['payment-service', PAYMENT_URL],
  ] as const) {
    await pollUntil(() => isHealthy(url), (ok) => ok, {
      timeoutMs,
      description: `${name} (${url}) to report healthy`,
    });
  }
}
