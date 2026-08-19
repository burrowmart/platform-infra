/** Criterion 4: "Only cloudflared has an outbound edge connection; there is
 * no LoadBalancer and no public inbound in the manifests."
 *
 * Renders every service's real Helm chart (all 12 — 6 domain services + 6
 * BFF/edge units) and greps the rendered manifests for LoadBalancer/NodePort
 * Services. Also audits the Terraform tree that owns cloudflared + the
 * internal ingress controller.
 *
 * Terraform caveat (documented, not hidden): every provider block in this
 * tree (kubernetes/helm) is configured from `data.aws_eks_cluster.this`, a
 * lookup against a real pre-existing EKS cluster — see terraform/data.tf's
 * own header comment ("provisioned elsewhere, out of scope for this
 * session"). That data source is read during `terraform plan` itself, before
 * any resource graph is built, so a live plan is not obtainable without real
 * AWS + Cloudflare credentials and an actual cluster — neither is available
 * in this sandbox. `terraform validate` (pure static check, no credentials)
 * runs for real here; standing in for the live plan's manifest content is a
 * static audit of the same .tf resource declarations `plan` would have shown
 * for these not-yet-created resources anyway (their `type =` / resource
 * blocks are literal in the HCL, not computed).
 */

import * as fs from 'fs';
import * as path from 'path';
import { sh } from '../lib/sh';
import { evidence } from '../lib/types';
import type { CheckResult } from '../lib/types';

const BACKEND_ROOT = path.resolve(__dirname, '..', '..', '..', '..');
const PLATFORM_INFRA = path.resolve(BACKEND_ROOT, 'platform-infra');

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

interface RenderedChart {
  service: string;
  yaml: string;
  ok: boolean;
  err?: string;
}

async function renderChart(service: string): Promise<RenderedChart> {
  const chartDir = path.join(BACKEND_ROOT, service, 'helm');
  let res = await sh('helm', ['template', service, chartDir], { cwd: PLATFORM_INFRA, timeoutMs: 30_000 });
  if (res.code !== 0 && /found in Chart.yaml, but missing in charts|no cached repo|dependenc/i.test(res.stderr)) {
    // Dependency tarball resolution fallback — file:// dep, no network needed.
    await sh('helm', ['dependency', 'build', chartDir], { cwd: PLATFORM_INFRA, timeoutMs: 30_000 });
    res = await sh('helm', ['template', service, chartDir], { cwd: PLATFORM_INFRA, timeoutMs: 30_000 });
  }
  return { service, yaml: res.stdout, ok: res.code === 0, err: res.code === 0 ? undefined : res.stderr };
}

function findForbiddenServiceTypes(yaml: string): string[] {
  const hits: string[] = [];
  // Walk `kind: Service` documents and check their `type:` field specifically
  // (a blunt whole-file grep for "LoadBalancer" would also false-positive on
  // unrelated strings; this scopes to actual Service manifests).
  const docs = yaml.split(/^---$/m);
  for (const doc of docs) {
    if (!/^kind:\s*Service\s*$/m.test(doc)) continue;
    const typeMatch = doc.match(/^\s*type:\s*(\S+)/m);
    const type = typeMatch?.[1] ?? 'ClusterIP';
    if (type === 'LoadBalancer' || type === 'NodePort') hits.push(type);
  }
  return hits;
}

export async function checkManifestAudit(): Promise<CheckResult> {
  const startedAt = new Date();
  const ev: CheckResult['evidence'] = [];
  const assertions: string[] = [];
  let pass = true;
  let error: string | undefined;

  try {
    const rendered = await Promise.all(SERVICES.map(renderChart));

    const renderFailures = rendered.filter((r) => !r.ok);
    assertions.push(assert(`all ${SERVICES.length} service charts render`, renderFailures.length === 0, renderFailures.map((r) => r.service).join(',') || 'none failed'));

    const forbiddenByService: Record<string, string[]> = {};
    for (const r of rendered) {
      if (!r.ok) continue;
      const hits = findForbiddenServiceTypes(r.yaml);
      if (hits.length) forbiddenByService[r.service] = hits;
    }
    assertions.push(assert('zero LoadBalancer/NodePort Services across all rendered charts', Object.keys(forbiddenByService).length === 0, JSON.stringify(forbiddenByService)));

    const clusterIpCounts = rendered
      .filter((r) => r.ok)
      .map((r) => ({ service: r.service, clusterIpServices: (r.yaml.match(/^\s*type:\s*ClusterIP/gm) ?? []).length }));
    const allHaveClusterIp = clusterIpCounts.every((c) => c.clusterIpServices >= 1);
    assertions.push(assert('every service declares a ClusterIP Service', allHaveClusterIp, JSON.stringify(clusterIpCounts)));

    // ── Terraform ──────────────────────────────────────────────────────────
    const tfDir = path.join(PLATFORM_INFRA, 'terraform');
    const validate = await sh('terraform', ['validate', '-json'], { cwd: tfDir, timeoutMs: 60_000 });
    let validateOk = false;
    try {
      validateOk = (JSON.parse(validate.stdout) as { valid?: boolean }).valid === true;
    } catch {
      validateOk = validate.code === 0;
    }
    assertions.push(assert('terraform validate passes (static config check, no cloud credentials needed)', validateOk, `exit=${validate.code}`));

    // Documented attempt at a live plan — expected to fail here for the
    // reason in this file's header comment; captured as evidence, not
    // treated as a check failure.
    const planAttempt = await sh(
      'terraform',
      ['plan', '-input=false', '-var=aws_region=eu-west-1', '-var=aws_account_id=111122223333', '-var=eks_cluster_name=archtenet-prod', '-var=cloudflare_account_id=0123456789abcdef0123456789abcdef', '-var=cloudflare_api_token=demo-token-not-real', '-var=cloudflare_zone_id=0123456789abcdef0123456789abcdef', '-var=base_domain=internal.archtenet.com', '-var=opa_bundle_bucket_name=archtenet-opa-bundles-111122223333', '-var=github_owner=archtenet'],
      { cwd: tfDir, timeoutMs: 30_000 },
    );

    const tfFiles = listTfFiles(path.join(PLATFORM_INFRA, 'terraform'));
    const forbiddenTypeMatches: { file: string; line: string }[] = [];
    for (const file of tfFiles) {
      const content = fs.readFileSync(file, 'utf8');
      content.split('\n').forEach((line, i) => {
        if (/type\s*=\s*"(LoadBalancer|NodePort)"/.test(line)) {
          forbiddenTypeMatches.push({ file: path.relative(PLATFORM_INFRA, file), line: `${i + 1}: ${line.trim()}` });
        }
      });
    }
    assertions.push(assert('zero LoadBalancer/NodePort resource types in Terraform HCL', forbiddenTypeMatches.length === 0, JSON.stringify(forbiddenTypeMatches)));

    const cloudflareTunnelMain = fs.readFileSync(path.join(PLATFORM_INFRA, 'terraform', 'modules', 'cloudflare-tunnel', 'main.tf'), 'utf8');
    const cloudflaredHasNoInboundService = !/resource\s+"kubernetes_service(_v1)?"/.test(cloudflareTunnelMain);
    assertions.push(assert('cloudflared module declares no inbound kubernetes_service (outbound-only)', cloudflaredHasNoInboundService, `matched=${!cloudflaredHasNoInboundService}`));

    const internalIngressMain = fs.readFileSync(path.join(PLATFORM_INFRA, 'terraform', 'modules', 'internal-ingress', 'main.tf'), 'utf8');
    const ingressPinnedClusterIp = /service\s*=\s*\{\s*\n?\s*type\s*=\s*"ClusterIP"/.test(internalIngressMain) || /type\s*=\s*"ClusterIP"/.test(internalIngressMain);
    assertions.push(assert('internal-ingress controller pinned to ClusterIP', ingressPinnedClusterIp, `pinned=${ingressPinnedClusterIp}`));

    pass = assertions.every((a) => a.startsWith('PASS'));

    ev.push(evidence('Rendered chart render status (12 service charts)', rendered.map((r) => `${r.service}: ${r.ok ? 'rendered OK' : `FAILED — ${r.err}`}`).join('\n')));
    ev.push(evidence('grep: Service `type:` across all rendered manifests', SERVICES.map((s) => {
      const r = rendered.find((x) => x.service === s);
      const types = r?.ok ? (r.yaml.match(/^\s*type:\s*(ClusterIP|LoadBalancer|NodePort)/gm) ?? []) : ['(render failed)'];
      return `${s}: ${types.map((t) => t.trim()).join(', ') || '(no Service in this chart)'}`;
    }).join('\n')));
    ev.push(evidence('terraform validate -json', validate.stdout || validate.stderr));
    ev.push(evidence(`terraform plan (expected to fail — no real AWS/Cloudflare credentials in this sandbox; documented limitation, see file header)`, `exit code: ${planAttempt.code}\n\n${(planAttempt.stderr || planAttempt.stdout).slice(0, 3000)}`));
    ev.push(evidence('Static Terraform HCL audit', [`LoadBalancer/NodePort matches: ${JSON.stringify(forbiddenTypeMatches)}`, `cloudflared module has kubernetes_service: ${!cloudflaredHasNoInboundService}`, `internal-ingress pinned ClusterIP: ${ingressPinnedClusterIp}`].join('\n')));
    ev.push(evidence('Assertions', assertions.join('\n')));
  } catch (err) {
    pass = false;
    error = err instanceof Error ? `${err.message}\n${err.stack}` : String(err);
    ev.push(evidence('Assertions before failure', assertions.join('\n')));
  }

  const finishedAt = new Date();
  return {
    id: 'check-4-manifest-audit',
    title: 'Manifest audit: zero LoadBalancer/NodePort, no public inbound, cloudflared outbound-only',
    criterion: 'Only cloudflared has an outbound edge connection; there is no LoadBalancer and no public inbound in the manifests.',
    pass,
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAt.getTime(),
    evidence: ev,
    summary: pass
      ? 'All 12 service charts render with ClusterIP-only Services (zero LoadBalancer/NodePort); terraform validate passes; static HCL audit confirms cloudflared has no inbound Service and internal-ingress is pinned to ClusterIP. Live `terraform plan` is not obtainable in this sandbox (no real AWS/Cloudflare credentials) — see evidence.'
      : 'One or more assertions failed — see evidence.',
    error,
  };
}

function listTfFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === '.terraform') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listTfFiles(full));
    else if (entry.name.endsWith('.tf')) out.push(full);
  }
  return out;
}

function assert(label: string, ok: boolean, detail: string): string {
  return `${ok ? 'PASS' : 'FAIL'}: ${label} (${detail})`;
}
