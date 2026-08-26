/** Criterion 5: "Every service pod runs the app + Envoy PEP sidecar;
 * requests are authorized via OPA ext_authz."
 *
 * Two parts:
 *  (1) Static — render every service's real Helm chart and assert the pod
 *      spec has exactly the `app` and `envoy-pep` containers, wired to OPA
 *      via ext_authz (base-service chart's configmap.yaml).
 *  (2) Live — T5.2 demo: run the real opa-policies/bundle against a real
 *      `opa run --server`, mint real RS256 JWTs with
 *      opa-policies/demo/mint-token.js (the same demo keypair
 *      envoy.rego verifies against bundle/jwks), and get one allow + one
 *      deny decision through the actual `data.envoy.authz.allow` ext_authz
 *      bridge entrypoint — not the Rego unit tests, an HTTP decision from a
 *      running PDP.
 */

import * as fs from 'fs';
import * as path from 'path';
import { sh } from '../lib/sh';
import { spawnBackground } from '../lib/process';
import { pollUntil } from '../../../integration-tests/src/support/poll';
import { evidence } from '../lib/types';
import type { CheckResult } from '../lib/types';

const BACKEND_ROOT = path.resolve(__dirname, '..', '..', '..', '..');
const PLATFORM_INFRA = path.resolve(BACKEND_ROOT, 'platform-infra');
const OPA_POLICIES = path.join(BACKEND_ROOT, 'opa-policies');
const OPA_PORT = 18181;
const OPA_URL = `http://localhost:${OPA_PORT}`;

const SERVICES = [
  'user-service',
  'catalog-service',
  'order-service',
  'payment-service',
  'notification-service',
  'chat-service',
  'user-bff',
  'catalog-bff',
  'order-bff',
  'cart-bff',
  'payment-bff',
  'ws-gateway',
];

// NOTE: `helm template` does not resolve chart dependencies — it renders
// whatever is already in <chart>/charts/. That directory is gitignored (the
// packaged base-service is a build artifact), so
// platform-infra/scripts/vendor-base-chart.sh must have been run first, or
// every render below fails with "found in Chart.yaml, but missing in charts/".
// runAcceptance() invokes it; see the call site.
async function renderChart(service: string): Promise<{ service: string; yaml: string; ok: boolean }> {
  const chartDir = path.join(BACKEND_ROOT, service, 'helm');
  const res = await sh('helm', ['template', service, chartDir], { cwd: PLATFORM_INFRA, timeoutMs: 30_000 });
  return { service, yaml: res.stdout, ok: res.code === 0 };
}

function containerNames(yaml: string): string[] {
  const deploymentDoc = yaml.split(/^---$/m).find((d) => /^kind:\s*Deployment\s*$/m.test(d));
  if (!deploymentDoc) return [];
  return [...deploymentDoc.matchAll(/^\s*- name:\s*(app|envoy-pep)\s*$/gm)].map((m) => m[1]);
}

async function mintToken(email: string, roles: string): Promise<string> {
  const res = await sh('node', ['demo/mint-token.js', email, roles], { cwd: OPA_POLICIES, timeoutMs: 10_000 });
  if (res.code !== 0) throw new Error(`mint-token.js failed: ${res.stderr}`);
  return res.stdout.trim();
}

async function envoyDecision(token: string, method: string, urlPath: string): Promise<{ allow: boolean; raw: unknown }> {
  const input = { input: { attributes: { request: { http: { method, path: urlPath, headers: { authorization: `Bearer ${token}` } } } } } };
  const res = await fetch(`${OPA_URL}/v1/data/envoy/authz/allow`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(input),
  });
  const body = (await res.json()) as { result?: boolean };
  return { allow: body.result === true, raw: body };
}

export async function checkEnvoyOpa(): Promise<CheckResult> {
  const startedAt = new Date();
  const ev: CheckResult['evidence'] = [];
  const assertions: string[] = [];
  let pass = true;
  let error: string | undefined;
  let opa: ReturnType<typeof spawnBackground> | undefined;

  try {
    // ── Part 1: static — app + envoy-pep sidecar in every rendered chart ────
    const rendered = await Promise.all(SERVICES.map(renderChart));
    const perService: Record<string, string[]> = {};
    for (const r of rendered) perService[r.service] = r.ok ? containerNames(r.yaml) : [];
    const missing = Object.entries(perService).filter(([, names]) => !(names.includes('app') && names.includes('envoy-pep')));
    assertions.push(assert('every service chart\'s Deployment has both app + envoy-pep containers', missing.length === 0, JSON.stringify(missing.map(([s]) => s))));

    const extAuthzWired = rendered.filter((r) => r.ok).map((r) => ({ service: r.service, wired: r.yaml.includes('envoy.filters.http.ext_authz') }));
    const unwired = extAuthzWired.filter((x) => !x.wired);
    assertions.push(assert('every rendered chart\'s Envoy config has the ext_authz filter', unwired.length === 0, JSON.stringify(unwired.map((x) => x.service))));

    // ── Part 2: live — real OPA server, real bundle, real signed JWTs ──────
    if (!fs.existsSync(path.join(OPA_POLICIES, 'demo', '.keys', 'private-key.pem'))) {
      await sh('node', ['demo/gen-keys.js'], { cwd: OPA_POLICIES, timeoutMs: 10_000 });
    }

    opa = spawnBackground('opa', ['run', '--server', '--addr', `:${OPA_PORT}`, '--bundle', 'bundle'], { cwd: OPA_POLICIES });
    await pollUntil(
      async () => {
        try {
          const res = await fetch(`${OPA_URL}/health`);
          return res.status;
        } catch {
          return 0;
        }
      },
      (status) => status === 200,
      { timeoutMs: 15_000, description: 'OPA server /health to return 200' },
    );

    // admin role -> RBAC wildcard ("*","*") -> allow, independent of OPAL/data.users.
    const adminToken = await mintToken('acceptance-admin@example.com', 'admin');
    const allowDecision = await envoyDecision(adminToken, 'GET', '/users');
    assertions.push(assert('LIVE ALLOW: admin GET /users -> allow=true (RBAC wildcard)', allowDecision.allow === true, JSON.stringify(allowDecision.raw)));

    // buyer role has no user:read RBAC grant, and without OPAL running
    // data.users is empty so ownership/department/verified ABAC rules can't
    // fire either -> deny. Real signature verification, real deny decision.
    const buyerToken = await mintToken('acceptance-buyer@example.com', 'buyer');
    const denyDecision = await envoyDecision(buyerToken, 'GET', '/users');
    assertions.push(assert('LIVE DENY: buyer GET /users -> allow=false (no RBAC/ABAC grant)', denyDecision.allow === false, JSON.stringify(denyDecision.raw)));

    // Tampered/invalid token must also deny (signature verification is real).
    const forgedDecision = await envoyDecision(`${adminToken}tampered`, 'GET', '/users');
    assertions.push(assert('LIVE DENY: tampered signature -> allow=false', forgedDecision.allow === false, JSON.stringify(forgedDecision.raw)));

    pass = assertions.every((a) => a.startsWith('PASS'));

    ev.push(evidence('Containers per rendered chart (app, envoy-pep)', SERVICES.map((s) => `${s}: [${perService[s]?.join(', ') ?? '(render failed)'}]`).join('\n')));
    ev.push(evidence('mint-token.js output (RS256 JWTs, demo keypair)', [`admin token: ${adminToken}`, `buyer token: ${buyerToken}`].join('\n')));
    ev.push(evidence('opa run --server startup log', opa.stdout || opa.stderr));
    ev.push(evidence('POST /v1/data/envoy/authz/allow — decisions', [`admin/GET /users -> ${JSON.stringify(allowDecision.raw)}`, `buyer/GET /users -> ${JSON.stringify(denyDecision.raw)}`, `tampered/GET /users -> ${JSON.stringify(forgedDecision.raw)}`].join('\n')));
    ev.push(evidence('Assertions', assertions.join('\n')));
  } catch (err) {
    pass = false;
    error = err instanceof Error ? `${err.message}\n${err.stack}` : String(err);
    ev.push(evidence('Assertions before failure', assertions.join('\n')));
    if (opa) ev.push(evidence('opa run --server output (at failure time)', opa.stdout + '\n' + opa.stderr));
  } finally {
    if (opa) await opa.stop();
  }

  const finishedAt = new Date();
  return {
    id: 'check-5-envoy-opa',
    title: 'Every service = app + envoy-pep sidecar; live OPA ext_authz allow/deny',
    criterion: 'Every service pod runs the app + Envoy PEP sidecar; requests are authorized via OPA ext_authz.',
    pass,
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAt.getTime(),
    evidence: ev,
    summary: pass ? 'All 12 rendered charts carry app+envoy-pep with ext_authz wired to OPA; a live opa run --server loaded with the real bundle returned a correct allow (admin) and two correct denies (unauthorized buyer, tampered signature) via data.envoy.authz.allow.' : 'One or more assertions failed or the scenario errored — see evidence.',
    error,
  };
}

function assert(label: string, ok: boolean, detail: string): string {
  return `${ok ? 'PASS' : 'FAIL'}: ${label} (${detail})`;
}
