#!/usr/bin/env node
// Free-only policy CLI.
//   node tools/free-policy.mjs check <freellmapi|omniroute> <model-id>
//   node tools/free-policy.mjs freellmapi audit|apply --base-url http://127.0.0.1:3001 [--flag-file F]   (env FREELLMAPI_ADMIN_TOKEN | FREELLMAPI_ADMIN_EMAIL+PASSWORD)
//     --flag-file F: created when an audit finds violations (free-guard --kill-file F then refuses inference), removed when clean.
//     (v0.16.12 always groups same-named models behind one id; that is safe only because 'apply' leaves just free members enabled.)
//   node tools/free-policy.mjs omniroute  audit       --base-url http://127.0.0.1:20128 [--flag-file F]   (env OMNIROUTE_MGMT_TOKEN | OMNIROUTE_ADMIN_PASSWORD; read-only)
// 'apply' (FreeLLMAPI only) disables every catalog model that is not verified free and every key on a platform the
// policy does not cover. It never deletes anything, never enables anything and never prints a credential.
// Exit codes: 0 compliant, 1 violations remain, 2 usage/connection error.
import { writeFileSync, rmSync } from 'node:fs';
import { loadPolicy, classify } from './lib/free-policy.mjs';

const providerOfPlatform = (policy, platform) =>
  Object.entries(policy.providers).find(([, r]) => r.ids.includes(platform))?.[0] ?? null;

export function auditFreellmapiModels(policy, models, keys = []) {
  const violations = [];
  const baseOfKey = new Map(keys.map((k) => [k.id, k.baseUrl]));
  for (const m of models) {
    if (!(m.enabled === true || m.enabled === 1)) continue;
    const v = classify(policy, 'freellmapi', m.modelId);
    // Custom endpoints are free only when their base URL is a known free endpoint (e.g. OVH's keyless host).
    const owner = m.platform === 'custom'
      ? (policy.customEndpoints?.[String(baseOfKey.get(m.keyId) ?? '').replace(/\/+$/, '')] ?? null)
      : providerOfPlatform(policy, m.platform);
    if (!v.ok) violations.push({ id: m.id, platform: m.platform, model: m.modelId, reason: v.reason });
    else if (owner !== v.provider) violations.push({ id: m.id, platform: m.platform, model: m.modelId, reason: `platform '${m.platform}' is not covered by the policy (custom endpoints must use a base URL listed in customEndpoints)` });
  }
  return violations;
}

const trimSlash = (u) => String(u ?? '').replace(/\/+$/, '');

export function auditOmnirouteProviders(policy, payload, nodesPayload = []) {
  const list = Array.isArray(payload) ? payload : payload?.connections ?? payload?.providers ?? payload?.data ?? [];
  const nodes = Array.isArray(nodesPayload) ? nodesPayload : nodesPayload?.nodes ?? [];
  const bad = [];
  const nodeOk = (n) => {
    const prov = policy.customNodePrefixes?.[n.prefix];
    return !!prov && policy.customEndpoints?.[trimSlash(n.baseUrl)] === prov;
  };
  const nodeById = new Map(nodes.map((n) => [n.id, n]));
  for (const n of nodes) if (!nodeOk(n)) bad.push({ provider: `custom node '${n.prefix}'`, reason: 'prefix/base URL is not a listed free endpoint (see customNodePrefixes + customEndpoints)' });
  for (const p of list) {
    const id = p?.provider ?? p?.id ?? p?.name;
    if (!id || p.isActive === false || p.enabled === false) continue;
    if (nodeById.has(id)) continue; // judged above via its node
    if (/^openai-compatible-|^anthropic-compatible-/.test(String(id))) { bad.push({ provider: String(id), reason: 'compatible connection without a known node' }); continue; }
    if (!Object.values(policy.providers).some((r) => r.ids.includes(String(id)))) bad.push({ provider: String(id), reason: 'not in the verified-free policy' });
  }
  return bad;
}

async function api(base, token, method, path, body) {
  const r = await fetch(new URL(path, base), {
    method, redirect: 'error', signal: AbortSignal.timeout(20_000),
    headers: { accept: 'application/json', authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) throw new Error(`${method} ${path} -> HTTP ${r.status}`);
  return r.json();
}

export async function main(argv, env = process.env, out = (s) => process.stdout.write(s + '\n')) {
  const policy = loadPolicy(env.FREE_POLICY_FILE);
  const [cmd, a, b] = argv;
  const opt = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  if (cmd === 'check') {
    const v = classify(policy, a, b, { allowAuto: argv.includes('--allow-auto') });
    out(`${v.ok ? 'ALLOW' : 'BLOCK'} ${a} ${b ?? '(none)'}${v.provider ? ` provider=${v.provider}` : ''}${v.reason ? ` reason=${v.reason}` : ''}`);
    return v.ok ? 0 : 1;
  }
  const base = opt('--base-url');
  if (!['freellmapi', 'omniroute'].includes(cmd) || !['audit', 'apply'].includes(a) || !base) { out('usage: see header of tools/free-policy.mjs'); return 2; }
  const u = new URL(base);
  if (!['127.0.0.1', 'localhost', '::1'].includes(u.hostname)) { out('refusing non-loopback --base-url'); return 2; }
  const flagFile = opt('--flag-file');
  const flag = (code) => { if (flagFile) { if (code === 1) writeFileSync(flagFile, `audit failed ${new Date().toISOString()}\n`, { mode: 0o600 }); else if (code === 0) rmSync(flagFile, { force: true }); } return code; };
  try {
    if (cmd === 'freellmapi') {
      let token = env.FREELLMAPI_ADMIN_TOKEN;
      if (!token && env.FREELLMAPI_ADMIN_EMAIL && env.FREELLMAPI_ADMIN_PASSWORD) {
        // Short-lived dashboard session obtained per run, so no long-lived token has to be stored.
        const r = await fetch(new URL('/api/auth/login', base), { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(20_000),
          headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: env.FREELLMAPI_ADMIN_EMAIL, password: env.FREELLMAPI_ADMIN_PASSWORD }) });
        if (!r.ok) { out(`dashboard login failed (HTTP ${r.status})`); return 2; }
        token = (await r.json()).token;
      }
      if (!token) { out('no FREELLMAPI_ADMIN_TOKEN or FREELLMAPI_ADMIN_EMAIL+FREELLMAPI_ADMIN_PASSWORD set; cannot audit'); return 2; }
      const getKeys = async () => { const k = await api(base, token, 'GET', '/api/keys'); return Array.isArray(k) ? k : k.keys ?? []; };
      let models = await api(base, token, 'GET', '/api/models');
      let bad = auditFreellmapiModels(policy, models, await getKeys());
      if (a === 'apply') {
        for (const v of bad) await api(base, token, 'PATCH', `/api/models/${v.id}`, { enabled: false });
        const keys = await getKeys();
        const covered = new Set([...Object.values(policy.providers).flatMap((r) => r.ids), 'custom']);
        const platforms = new Set(keys.filter((k) => k.enabled !== false && k.enabled !== 0).map((k) => k.platform));
        for (const p of platforms) if (!covered.has(p)) { await api(base, token, 'PATCH', `/api/keys/platform/${encodeURIComponent(p)}`, { enabled: false }); out(`disabled keys for uncovered platform: ${p}`); }
        out(`disabled ${bad.length} non-free model(s)`);
        models = await api(base, token, 'GET', '/api/models');
        bad = auditFreellmapiModels(policy, models, await getKeys());
      }
      const enabled = models.filter((m) => m.enabled === true || m.enabled === 1).length;
      out(`freellmapi: ${enabled} enabled model(s), ${bad.length} violation(s)`);
      for (const v of bad.slice(0, 50)) out(`  VIOLATION ${v.platform}/${v.model}: ${v.reason}`);
      return flag(bad.length ? 1 : 0);
    }
    if (a === 'apply') { out('omniroute: apply is not supported (read-only audit; remove providers in the dashboard). Enforcement is by free-guard.'); return 2; }
    const token = env.OMNIROUTE_MGMT_TOKEN;
    let headersFn = null;
    if (!token && env.OMNIROUTE_ADMIN_PASSWORD) {
      const r = await fetch(new URL('/api/auth/login', base), { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(20_000),
        headers: { 'content-type': 'application/json' }, body: JSON.stringify({ password: env.OMNIROUTE_ADMIN_PASSWORD }) });
      if (!r.ok) { out(`dashboard login failed (HTTP ${r.status})`); return 2; }
      const cookie = (r.headers.getSetCookie?.() ?? []).map((c) => c.split(';')[0]).join('; ');
      headersFn = { cookie };
    }
    if (!token && !headersFn) { out('no OMNIROUTE_MGMT_TOKEN (or OMNIROUTE_ADMIN_PASSWORD) set; cannot audit connected providers'); return 2; }
    const get = async (p) => {
      const r = await fetch(new URL(p, base), { redirect: 'error', signal: AbortSignal.timeout(20_000), headers: { accept: 'application/json', ...(token ? { authorization: `Bearer ${token}` } : headersFn) } });
      if (r.status === 404) return null;
      if (!r.ok) throw new Error(`GET ${p} -> HTTP ${r.status}`);
      return r.json();
    };
    const bad = auditOmnirouteProviders(policy, await get('/api/providers') ?? [], await get('/api/provider-nodes') ?? []);
    out(`omniroute: ${bad.length} connected provider(s) outside the policy`);
    for (const v of bad) out(`  VIOLATION ${v.provider}: ${v.reason}`);
    return flag(bad.length ? 1 : 0);
  } catch (e) { out(`error: ${String(e.message).replace(/Bearer\s+\S+/g, 'Bearer [redacted]')}`); return 2; }
}

if (import.meta.url === `file://${process.argv[1]}`) main(process.argv.slice(2)).then((c) => process.exit(c));
