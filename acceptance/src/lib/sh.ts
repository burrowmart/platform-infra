import { spawn } from 'child_process';

export interface ShResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

/** Runs a command, always resolving (never rejecting on non-zero exit) so
 * callers can inspect stderr/code for evidence even on expected failures
 * (e.g. `terraform plan` without cloud credentials). */
export function sh(cmd: string, args: string[], opts: { cwd?: string; env?: NodeJS.ProcessEnv; input?: string; timeoutMs?: number } = {}): Promise<ShResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd: opts.cwd, env: opts.env ?? process.env });
    let stdout = '';
    let stderr = '';
    const timer = opts.timeoutMs
      ? setTimeout(() => {
          child.kill('SIGKILL');
        }, opts.timeoutMs)
      : undefined;
    child.stdout.on('data', (d) => (stdout += d.toString()));
    child.stderr.on('data', (d) => (stderr += d.toString()));
    child.on('error', (err) => {
      if (timer) clearTimeout(timer);
      reject(err);
    });
    child.on('close', (code) => {
      if (timer) clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
    if (opts.input !== undefined) child.stdin.write(opts.input);
    child.stdin?.end();
  });
}
