/** Thin wrapper around `docker compose` for the multi-overlay stack this
 * harness needs: base (mongo/redis/rabbitmq) + test (order/catalog/payment)
 * + acceptance (notification-service) + observability (vector/loki/tempo/
 * otel-collector), the same layering pattern integration-tests/package.json
 * already established for base+test. */

import { execFile, spawn } from 'child_process';
import { promisify } from 'util';
import * as path from 'path';

const execFileAsync = promisify(execFile);

export const INFRA_ROOT = path.resolve(__dirname, '..', '..', '..');

const COMPOSE_FILES = [
  'docker-compose.yml',
  'docker-compose.test.yml',
  'acceptance/docker-compose.acceptance.yml',
  'docker-compose.observability.yml',
];

function composeArgs(extra: string[]): string[] {
  const fileArgs = COMPOSE_FILES.flatMap((f) => ['-f', f]);
  return ['compose', ...fileArgs, ...extra];
}

/** Does NOT throw on a non-zero exit — a single service's build failing
 * (e.g. a broken Dockerfile in one of the polyrepo units this stack
 * doesn't own) must not prevent the harness from running the checks that
 * don't depend on that service; the check that does depend on it will fail
 * on its own with clear evidence instead. */
export async function composeUp(): Promise<{ ok: boolean }> {
  try {
    await run(composeArgs(['--profile', 'observability', 'up', '-d', '--build']));
    return { ok: true };
  } catch (err) {
    console.error(`\n!!! docker compose up --build reported an error (continuing — see above for which service): ${err instanceof Error ? err.message : err}\n`);
    return { ok: false };
  }
}

export async function composeDown(opts: { volumes?: boolean } = {}): Promise<void> {
  const args = composeArgs(['--profile', 'observability', 'down']);
  if (opts.volumes) args.push('-v');
  await run(args);
}

export async function composePs(): Promise<string> {
  const { stdout } = await execFileAsync('docker', composeArgs(['ps']), { cwd: INFRA_ROOT });
  return stdout;
}

/** Resolves a compose service name (e.g. "mongo", "redis") to its actual
 * running container ID — avoids hardcoding project-name-prefixed container
 * names, which vary with COMPOSE_PROJECT_NAME / the directory compose runs from. */
export async function composeContainerId(service: string): Promise<string> {
  const { stdout } = await execFileAsync('docker', composeArgs(['ps', '-q', service]), { cwd: INFRA_ROOT });
  const id = stdout.trim().split('\n')[0];
  if (!id) throw new Error(`No running container found for compose service "${service}"`);
  return id;
}

function run(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn('docker', args, { cwd: INFRA_ROOT, stdio: 'inherit' });
    child.on('error', reject);
    child.on('exit', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`docker ${args.join(' ')} exited with code ${code}`));
    });
  });
}
