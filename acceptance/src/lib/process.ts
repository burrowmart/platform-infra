import { ChildProcess, spawn } from 'child_process';

export interface BackgroundProcess {
  child: ChildProcess;
  stdout: string;
  stderr: string;
  stop: () => Promise<void>;
}

/** Spawns a long-running process (e.g. `opa run --server`), buffering its
 * output for report evidence, and returns a handle to stop it later. */
export function spawnBackground(cmd: string, args: string[], opts: { cwd?: string } = {}): BackgroundProcess {
  const child = spawn(cmd, args, { cwd: opts.cwd });
  const state = { stdout: '', stderr: '' };
  child.stdout?.on('data', (d) => (state.stdout += d.toString()));
  child.stderr?.on('data', (d) => (state.stderr += d.toString()));

  const stop = () =>
    new Promise<void>((resolve) => {
      if (child.exitCode !== null || child.killed) return resolve();
      child.once('exit', () => resolve());
      child.kill('SIGTERM');
      setTimeout(() => {
        if (child.exitCode === null) child.kill('SIGKILL');
      }, 3000);
    });

  return {
    child,
    get stdout() {
      return state.stdout;
    },
    get stderr() {
      return state.stderr;
    },
    stop,
  } as BackgroundProcess;
}
