/** No sleeps in test bodies — every wait-for-eventual-consistency in this
 * suite goes through here so it fails fast on a real hang instead of a flake,
 * and reports the last observed value when it times out. */

export interface PollOptions {
  timeoutMs: number;
  intervalMs?: number;
  description?: string;
}

export async function pollUntil<T>(
  fn: () => Promise<T>,
  predicate: (value: T) => boolean,
  opts: PollOptions,
): Promise<T> {
  const intervalMs = opts.intervalMs ?? 500;
  const deadline = Date.now() + opts.timeoutMs;
  let lastValue: T | undefined;
  let lastError: unknown;

  while (Date.now() < deadline) {
    try {
      lastValue = await fn();
      if (predicate(lastValue)) return lastValue;
    } catch (err) {
      lastError = err;
    }
    await sleep(intervalMs);
  }

  const label = opts.description ? ` waiting for: ${opts.description}` : '';
  const valueMsg = lastValue !== undefined ? ` Last value: ${safeJson(lastValue)}.` : '';
  const errMsg = lastError !== undefined ? ` Last error: ${String(lastError)}.` : '';
  throw new Error(`pollUntil timed out after ${opts.timeoutMs}ms${label}.${valueMsg}${errMsg}`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function safeJson(value: unknown): string {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}
