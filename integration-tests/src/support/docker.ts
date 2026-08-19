import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

async function docker(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync('docker', args);
  return stdout;
}

export async function dockerPause(container: string): Promise<void> {
  await docker(['pause', container]);
}

export async function dockerUnpause(container: string): Promise<void> {
  await docker(['unpause', container]);
}

export async function dockerKill(container: string): Promise<void> {
  await docker(['kill', container]);
}

export async function dockerStart(container: string): Promise<void> {
  await docker(['start', container]);
}

/** Combined stdout+stderr of `docker logs` — pino writes to stdout, but we
 * don't want a stray console.error from an uncaught rejection to be missed. */
export async function dockerLogs(container: string): Promise<string> {
  try {
    const { stdout, stderr } = await execFileAsync('docker', ['logs', container]);
    return stdout + stderr;
  } catch (err) {
    const e = err as { stdout?: string; stderr?: string };
    return (e.stdout ?? '') + (e.stderr ?? '');
  }
}

export async function dockerInspectStatus(container: string): Promise<string> {
  const out = await docker(['inspect', '--format', '{{.State.Status}}', container]);
  return out.trim();
}
