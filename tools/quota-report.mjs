#!/usr/bin/env node
// Read-only quota / usage / availability report for FreeLLMAPI and OmniRoute.
//
//   node tools/quota-report.mjs --gateway freellmapi|omniroute --base-url http://127.0.0.1:PORT
//        [--json] [--list-models] [--max-age-min N] [--timeout-ms N]
//
// Credentials come ONLY from the environment (never argv, never printed, never written):
//   FREELLMAPI_KEY         FreeLLMAPI unified key           (for /v1/usage, /v1/providers, /v1/quota-forecast, /v1/models)
//   OMNIROUTE_MGMT_TOKEN   OmniRoute READ-scope access token (oma_live_...) from Settings -> Access Tokens
//
// Safety properties (enforced in code and covered by tests/quota/quota-report.test.mjs):
//   * HTTP GET only, to a fixed per-gateway allowlist of documented read-only paths; no redirects followed.
//   * Never calls /v1/chat/completions or any other generation / mutation / refresh (POST) endpoint.
//   * Response bodies are never echoed; errors are reduced to status classes. Credentials are redacted from any output.
//   * Every line carries exactly one label. Missing, stale, malformed or errored data is "Unknown / unavailable".
//   * Nothing is summed across providers, keys or pools (they overlap); documented estimates are never added to
//     provider-reported quota.

export const LABELS = Object.freeze({
  PROVIDER: 'Provider-reported quota',
  GATEWAY: 'Gateway-counted usage',
  ESTIMATE: 'Documented estimate',
  UNKNOWN: 'Unknown / unavailable',
});
const TAG = { PROVIDER: 'PROVIDER', GATEWAY: 'GATEWAY', ESTIMATE: 'ESTIMATE', UNKNOWN: 'UNKNOWN' };

// Documented read-only endpoints, per gateway. Anything else is refused before a socket is opened.
export const ALLOWED_GET_PATHS = Object.freeze({
  freellmapi: ['/api/ping', '/v1/usage', '/v1/providers', '/v1/quota-forecast', '/v1/models'],
  omniroute: ['/api/health/ping', '/api/monitoring/health', '/api/providers', '/api/usage/provider-limits', '/api/usage/analytics', '/api/free-tier/summary'],
});

// ---------------------------------------------------------------- helpers
const num = (v) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : null);
const str = (v, max = 120) => (typeof v === 'string' && v.length > 0 ? v.slice(0, max) : null);
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const dateOf = (v) => { if (typeof v !== 'string') return null; const t = Date.parse(v); return Number.isNaN(t) ? null : new Date(t); };
const fmtN = (n) => (n === null ? 'unknown' : Number.isInteger(n) ? n.toLocaleString('en-US') : String(Math.round(n * 100) / 100));

/** Remove anything that looks like a credential from text we might print. */
export function scrub(text, secrets = []) {
  let s = String(text);
  for (const sec of secrets) if (sec && sec.length >= 6) s = s.split(sec).join('[redacted]');
  return s
    .replace(/\b(sk|gsk|oma_live|freellmapi|xox[abprs]|ghp|gho|github_pat)[-_][A-Za-z0-9_-]{8,}/gi, '[redacted]')
    .replace(/AIza[0-9A-Za-z_-]{20,}/g, '[redacted]')
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, 'Bearer [redacted]')
    .replace(/\b[A-Fa-f0-9]{32,}\b/g, '[redacted]');
}

/** Classify a failed request without ever including the response body. */
function classify(status, retryAfter) {
  if (status === 0) return 'network error / timeout (gateway unreachable?)';
  if (status === 401 || status === 403) return `authentication rejected (HTTP ${status})`;
  if (status === 404) return 'endpoint not available on this version (HTTP 404)';
  if (status === 429) return `rate limited by the gateway (HTTP 429${retryAfter ? `, Retry-After ${scrub(retryAfter, []).slice(0, 20)}` : ''}); not retried`;
  if (status >= 500) return `gateway error (HTTP ${status})`;
  return `unexpected HTTP ${status}`;
}

/**
 * GET-only client. `kind` is the gateway name used to pick the allowlist. Resolves to
 * { ok:true, data } or { ok:false, reason } — it never throws and never exposes bodies.
 */
export function makeClient({ kind, baseUrl, secrets = {}, timeoutMs = 15000, fetchImpl = globalThis.fetch }) {
  const base = new URL(baseUrl);
  if (base.protocol !== 'http:' && base.protocol !== 'https:') throw new Error('base URL must be http(s)');
  const allow = new Set(ALLOWED_GET_PATHS[kind]);
  const secretValues = Object.values(secrets).filter(Boolean);
  const log = [];
  async function get(path, { auth } = {}) {
    const p = path.split('?')[0];
    if (!allow.has(p)) throw new Error(`refusing non-allowlisted path ${p}`); // programming error, not a runtime condition
    const token = auth ? secrets[auth] : null;
    if (auth && !token) return { ok: false, reason: `no credential supplied (${auth === 'unified' ? 'FREELLMAPI_KEY' : 'OMNIROUTE_MGMT_TOKEN'} not set)`, skipped: true };
    const url = new URL(path, base); // path is relative, so the origin can never change
    if (url.origin !== base.origin) throw new Error('origin mismatch');
    const headers = { accept: 'application/json' };
    if (token) headers.authorization = `Bearer ${token}`;
    log.push({ method: 'GET', path: p });
    let res;
    try {
      res = await fetchImpl(url, { method: 'GET', headers, redirect: 'manual', signal: AbortSignal.timeout(timeoutMs) });
    } catch { return { ok: false, reason: classify(0), status: 0 }; }
    if (res.status >= 300 && res.status < 400) return { ok: false, reason: `redirect refused (HTTP ${res.status}); credentials are never forwarded`, status: res.status };
    if (res.status !== 200) return { ok: false, reason: classify(res.status, res.headers.get('retry-after')), status: res.status };
    let text;
    try { text = await res.text(); } catch { return { ok: false, reason: 'response body unreadable', status: 200 }; }
    if (text.length > 5_000_000) return { ok: false, reason: 'response too large; ignored', status: 200 };
    try { return { ok: true, data: JSON.parse(text), status: 200 }; } catch { return { ok: false, reason: 'malformed JSON in response', status: 200 }; }
  }
  return { get, log, secretValues };
}

// ---------------------------------------------------------------- report builder
function newReport(gateway, baseUrl, now) {
  const items = [];
  return {
    gateway, baseUrl, generatedAt: now.toISOString(), items,
    add(section, label, text, source, data) { items.push({ section, label: LABELS[label], tag: TAG[label], text, source, ...(data ? { data } : {}) }); },
    unknown(section, text, source) { items.push({ section, label: LABELS.UNKNOWN, tag: TAG.UNKNOWN, text, source }); },
  };
}

function windowText(resetAt, now) {
  const d = dateOf(resetAt);
  if (!d) return 'reset time not exposed';
  const secs = Math.round((d - now) / 1000);
  return secs > 0 ? `resets ${d.toISOString()} (in ${Math.floor(secs / 3600)}h ${Math.floor((secs % 3600) / 60)}m)` : null; // null = already past => stale
}

// ---------------------------------------------------------------- FreeLLMAPI
export async function reportFreeLlmApi(client, { now = new Date(), listModels = false } = {}) {
  const r = newReport('FreeLLMAPI', client.baseUrlForReport, now);

  const ping = await client.get('/api/ping');
  if (ping.ok) r.add('Health', 'GATEWAY', 'liveness probe answered', 'GET /api/ping');
  else r.unknown('Health', `liveness probe failed: ${ping.reason}`, 'GET /api/ping');

  // --- usage: the gateway's own durable monthly ledger
  const u = await client.get('/v1/usage', { auth: 'unified' });
  const S = 'Usage this month';
  if (!u.ok) r.unknown(S, u.reason, 'GET /v1/usage');
  else if (!isObj(u.data)) r.unknown(S, 'malformed response (not an object)', 'GET /v1/usage');
  else {
    const reset = dateOf(u.data.resetsAt);
    const month = str(u.data.month, 7);
    const stale = reset ? reset <= now : false;
    const req = num(u.data.requests), tok = num(u.data.tokens);
    if (stale) r.unknown(S, `stale: ledger month ${month ?? '?'} ended ${reset.toISOString()}; values withheld`, 'GET /v1/usage');
    else if (req === null && tok === null) r.unknown(S, 'requests/tokens missing or invalid in response', 'GET /v1/usage');
    else r.add(S, 'GATEWAY', `month ${month ?? 'unknown'}: requests ${fmtN(req)}, tokens ${fmtN(tok)} — all providers and keys combined as counted by this gateway; ${reset ? `ledger resets ${reset.toISOString()}` : 'reset time not exposed'}`, 'GET /v1/usage', { month, requests: req, tokens: tok, resetsAt: reset?.toISOString() ?? null });
    if (!stale) {
      if (Array.isArray(u.data.byPlatform)) for (const p of u.data.byPlatform) {
        if (!isObj(p) || !str(p.platform)) continue;
        r.add(S, 'GATEWAY', `provider "${scrub(str(p.platform))}": requests ${fmtN(num(p.requests))}, tokens ${fmtN(num(p.tokens))} (a view of the totals above, not additional usage)`, 'GET /v1/usage');
      }
      if (Array.isArray(u.data.byKey)) for (const k of u.data.byKey) {
        if (!isObj(k) || !str(k.platform)) continue;
        const tcap = num(k.tokenCap), rcap = num(k.requestCap), ktok = num(k.tokens), kreq = num(k.requests);
        const capTxt = [
          tcap !== null ? `your token cap ${fmtN(tcap)}${ktok !== null ? ` (${fmtN(Math.max(0, tcap - ktok))} left under that cap)` : ''}` : 'no token cap set',
          rcap !== null ? `your request cap ${fmtN(rcap)}${kreq !== null ? ` (${fmtN(Math.max(0, rcap - kreq))} left under that cap)` : ''}` : 'no request cap set',
        ].join('; ');
        r.add(S, 'GATEWAY', `key "${scrub(str(k.label) ?? 'unlabelled')}" on "${scrub(str(k.platform))}"${k.enabled === false ? ' [disabled]' : ''}: requests ${fmtN(kreq)}, tokens ${fmtN(ktok)}; ${capTxt}. Caps are limits YOU configured in the gateway, not provider quota`, 'GET /v1/usage');
      }
    }
  }

  // --- provider status
  const pr = await client.get('/v1/providers', { auth: 'unified' });
  const P = 'Providers';
  if (!pr.ok) r.unknown(P, pr.reason, 'GET /v1/providers');
  else if (!isObj(pr.data) || !Array.isArray(pr.data.providers)) r.unknown(P, 'malformed response (no providers array)', 'GET /v1/providers');
  else if (pr.data.providers.length === 0) r.unknown(P, 'no provider has an enabled key', 'GET /v1/providers');
  else for (const p of pr.data.providers) {
    if (!isObj(p) || !str(p.platform)) continue;
    const resume = dateOf(p.resume_at);
    r.add(P, 'GATEWAY', `${scrub(str(p.name) ?? p.platform)} [${scrub(p.platform)}]: status ${scrub(str(p.status, 20) ?? 'unknown')}, enabled keys ${fmtN(num(p.keys))}${resume && resume > now ? `, cooling down until ${resume.toISOString()}` : ''}${p.last_error ? `, last health error: "${scrub(str(p.last_error, 100), [])}"` : ''}`, 'GET /v1/providers');
    const pct = num(p.requests_remaining_pct);
    if (pct !== null && pct <= 100) r.add(P, 'PROVIDER', `${scrub(p.platform)}: ${pct}% of the provider-reported request window remains (tightest key; the provider reported a request limit)`, 'GET /v1/providers');
  }

  // --- provider-observed quota windows
  const qf = await client.get('/v1/quota-forecast', { auth: 'unified' });
  const Q = 'Provider quota windows';
  if (!qf.ok) r.unknown(Q, qf.reason, 'GET /v1/quota-forecast');
  else if (!isObj(qf.data) || !Array.isArray(qf.data.pools)) r.unknown(Q, 'malformed response (no pools array)', 'GET /v1/quota-forecast');
  else if (qf.data.pools.length === 0) r.unknown(Q, 'no provider has reported a quota window yet (absence does not mean unlimited; many providers expose none)', 'GET /v1/quota-forecast');
  else for (const q of qf.data.pools) {
    if (!isObj(q) || !str(q.pool)) continue;
    const when = windowText(q.reset_at, now);
    const remaining = num(q.remaining), limit = num(q.limit), used = num(q.used);
    if (when === null) { r.unknown(Q, `${scrub(q.pool)}: window already reset (${scrub(String(q.reset_at))}); old figures withheld as stale`, 'GET /v1/quota-forecast'); continue; }
    if (remaining === null && limit === null) { r.unknown(Q, `${scrub(q.pool)}: provider reported no remaining/limit`, 'GET /v1/quota-forecast'); continue; }
    r.add(Q, 'PROVIDER', `pool ${scrub(q.pool)}: requests used ${fmtN(used)}, remaining ${fmtN(remaining)}, limit ${fmtN(limit)}${num(q.remaining_pct) !== null ? ` (${fmtN(num(q.remaining_pct))}% left)` : ''}; ${when}. Metric: requests only (token quotas are not exposed here). One row per provider pool; pools are never summed`, 'GET /v1/quota-forecast', { pool: q.pool, used, remaining, limit, resetAt: dateOf(q.reset_at)?.toISOString() ?? null });
  }

  // --- model readiness
  const m = await client.get('/v1/models', { auth: 'unified' });
  const M = 'Model availability';
  if (!m.ok) r.unknown(M, m.reason, 'GET /v1/models');
  else if (!isObj(m.data) || !Array.isArray(m.data.data)) r.unknown(M, 'malformed response (no data array)', 'GET /v1/models');
  else {
    const rows = m.data.data.filter((x) => isObj(x) && typeof x.execution_status === 'string' && str(x.id));
    if (rows.length === 0) r.unknown(M, 'no catalog rows with execution_status in response', 'GET /v1/models');
    else {
      const by = { ready: [], exhausted: [], needsKey: [] };
      let other = 0;
      for (const x of rows) (by[x.execution_status] ?? (other++, [])).push(scrub(x.id));
      r.add(M, 'GATEWAY', `catalog rows: ${rows.length}; ready now ${by.ready.length}, exhausted (all matching keys blocked) ${by.exhausted.length}, needs a key ${by.needsKey.length}${other ? `, unrecognised status ${other}` : ''}. "ready" reflects this gateway's key status, cooldowns and windows — not a guarantee the provider will accept a request`, 'GET /v1/models');
      const shown = listModels ? by.ready : by.ready.slice(0, 25);
      if (shown.length) r.add(M, 'GATEWAY', `ready models${listModels ? '' : ' (first 25; use --list-models for all)'}: ${shown.join(', ')}`, 'GET /v1/models');
      r.unknown(M, 'which provider serves each model, and whether each model is free, is not exposed by /v1/models (owned_by is always "freellmapi")', 'GET /v1/models');
    }
  }

  r.unknown('Documented free-tier budget', 'GET /api/free-tier needs a dashboard login session (not the unified key); deliberately not queried so no password is handled. Open Dashboard -> Models to see the documented budget.', 'GET /api/free-tier (not called)');
  return r;
}

// ---------------------------------------------------------------- OmniRoute
const quotaRows = (obj) => (isObj(obj) ? Object.entries(obj).filter(([, v]) => isObj(v)) : []);

export async function reportOmniRoute(client, { now = new Date(), maxAgeMin = null } = {}) {
  const r = newReport('OmniRoute', client.baseUrlForReport, now);

  const ping = await client.get('/api/health/ping');
  if (ping.ok) r.add('Health', 'GATEWAY', 'liveness + database probe answered', 'GET /api/health/ping');
  else r.unknown('Health', `liveness probe failed: ${ping.reason}`, 'GET /api/health/ping');

  // identity map from the connection list (projection only: id/provider/name/active/status)
  const names = new Map();
  const conns = await client.get('/api/providers', { auth: 'mgmt' });
  const C = 'Connections';
  if (!conns.ok) r.unknown(C, conns.reason, 'GET /api/providers');
  else if (!isObj(conns.data) || !Array.isArray(conns.data.connections)) r.unknown(C, 'malformed response (no connections array)', 'GET /api/providers');
  else if (conns.data.connections.length === 0) r.unknown(C, 'no provider connections configured', 'GET /api/providers');
  else for (const c of conns.data.connections) {
    if (!isObj(c) || !str(c.id)) continue;
    const label = `${scrub(str(c.provider) ?? 'unknown provider')}${str(c.name) ? ` "${scrub(str(c.name))}"` : ''}`;
    names.set(c.id, label);
    r.add(C, 'GATEWAY', `${label} [connection ${scrub(c.id).slice(0, 12)}]: ${c.isActive === false ? 'inactive' : 'active'}, last test status ${scrub(str(c.testStatus, 20) ?? 'unknown')}`, 'GET /api/providers');
  }

  // health (public)
  const h = await client.get('/api/monitoring/health');
  const H = 'Provider health';
  if (!h.ok) r.unknown(H, h.reason, 'GET /api/monitoring/health');
  else if (!isObj(h.data)) r.unknown(H, 'malformed response', 'GET /api/monitoring/health');
  else {
    r.add(H, 'GATEWAY', `overall status ${scrub(str(h.data.status, 20) ?? 'unknown')}${str(h.data.version, 20) ? `, version ${scrub(str(h.data.version, 20))}` : ''}`, 'GET /api/monitoring/health');
    if (Array.isArray(h.data.providerBreakers)) for (const b of h.data.providerBreakers) {
      if (!isObj(b) || !str(b.provider)) continue;
      const retry = num(b.retryAfterMs);
      r.add(H, 'GATEWAY', `circuit breaker for ${names.get(b.provider) ?? scrub(b.provider)}: ${scrub(str(b.state, 12) ?? 'unknown')}, failures ${fmtN(num(b.failureCount))}${retry ? `, retry after ${Math.ceil(retry / 1000)}s` : ''}`, 'GET /api/monitoring/health');
    }
    if (isObj(h.data.quotaMonitor)) r.add(H, 'GATEWAY', `quota monitor: active ${fmtN(num(h.data.quotaMonitor.active))}, alerting ${fmtN(num(h.data.quotaMonitor.alerting))}, exhausted ${fmtN(num(h.data.quotaMonitor.exhausted))}, errors ${fmtN(num(h.data.quotaMonitor.errors))}`, 'GET /api/monitoring/health');
  }

  // provider-reported quota (cached by OmniRoute; GET does not refresh)
  const pl = await client.get('/api/usage/provider-limits', { auth: 'mgmt' });
  const Q = 'Provider quota (as cached by OmniRoute)';
  if (!pl.ok) r.unknown(Q, pl.reason, 'GET /api/usage/provider-limits');
  else if (!isObj(pl.data) || !isObj(pl.data.caches)) r.unknown(Q, 'malformed response (no caches object)', 'GET /api/usage/provider-limits');
  else {
    const interval = num(pl.data.intervalMinutes);
    const maxAge = maxAgeMin ?? (interval ? interval * 2 : 180);
    const entries = Object.entries(pl.data.caches);
    if (entries.length === 0) r.unknown(Q, 'no connection has cached provider-limit data (many providers expose no quota API; absence does not mean unlimited)', 'GET /api/usage/provider-limits');
    for (const [id, e] of entries) {
      const who = names.get(id) ?? `connection ${scrub(id).slice(0, 12)} (provider not identified: needs /api/providers access)`;
      if (!isObj(e)) { r.unknown(Q, `${who}: malformed cache entry`, 'GET /api/usage/provider-limits'); continue; }
      const fetched = dateOf(e.fetchedAt);
      if (!fetched) { r.unknown(Q, `${who}: no valid fetchedAt timestamp; figures withheld`, 'GET /api/usage/provider-limits'); continue; }
      const ageMin = Math.round((now - fetched) / 60000);
      if (ageMin > maxAge) { r.unknown(Q, `${who}: stale, last fetched ${fetched.toISOString()} (${ageMin} min ago > ${maxAge} min limit); figures withheld`, 'GET /api/usage/provider-limits'); continue; }
      const rows = quotaRows(e.quotas);
      if (rows.length === 0) { r.unknown(Q, `${who}: provider returned no quota windows${str(e.message) ? ` (message: "${scrub(str(e.message, 100))}")` : ''}`, 'GET /api/usage/provider-limits'); continue; }
      for (const [key, v] of rows) {
        const unlimited = v.unlimited === true;
        const pct = num(v.remainingPercentage), total = num(v.total), remaining = num(v.remaining), used = num(v.used);
        const reset = dateOf(v.resetAt);
        if (reset && reset <= now) { r.unknown(Q, `${who} / ${scrub(str(v.displayName, 60) ?? key)}: window reset time ${reset.toISOString()} is in the past; old figures withheld as stale`, 'GET /api/usage/provider-limits'); continue; }
        if (!unlimited && pct === null && remaining === null && used === null) { r.unknown(Q, `${who} / ${scrub(str(v.displayName, 60) ?? key)}: no usable numbers in this quota window`, 'GET /api/usage/provider-limits'); continue; }
        const bits = [
          unlimited ? 'reported unlimited' : null,
          pct !== null ? `${fmtN(pct)}% remaining` : null,
          used !== null ? `used ${fmtN(used)}` : null,
          remaining !== null ? `remaining ${fmtN(remaining)}` : null,
          total !== null ? `of ${fmtN(total)}` : null,
        ].filter(Boolean).join(', ');
        r.add(Q, 'PROVIDER', `${who} / ${scrub(str(v.displayName, 60) ?? key)}: ${bits}; ${reset ? `resets ${reset.toISOString()}` : 'reset time not exposed'}; units are provider-specific (a total of 100 is a percentage); cached ${fetched.toISOString()}${str(e.plan) ? `, plan ${scrub(str(e.plan, 30))}` : ''}`, 'GET /api/usage/provider-limits');
      }
    }
    r.add(Q, 'GATEWAY', `OmniRoute refreshes this cache every ${interval ?? 'unknown'} min; this report reads the cache and never triggers a refresh`, 'GET /api/usage/provider-limits');
  }

  // gateway-counted usage + documented estimate (kept strictly apart)
  const U = 'Usage counted by OmniRoute';
  const an = await client.get('/api/usage/analytics?range=30d', { auth: 'mgmt' });
  if (!an.ok) r.unknown(U, an.reason, 'GET /api/usage/analytics');
  else if (!isObj(an.data) || !isObj(an.data.summary)) r.unknown(U, 'malformed response (no summary object)', 'GET /api/usage/analytics');
  else {
    const s = an.data.summary;
    const reqs = num(s.totalRequests), tot = num(s.totalTokens), pt = num(s.promptTokens), ct = num(s.completionTokens);
    if (reqs === null && tot === null) r.unknown(U, 'summary has no valid request/token counts', 'GET /api/usage/analytics');
    else r.add(U, 'GATEWAY', `rolling last 30 days: requests ${fmtN(reqs)}, tokens ${fmtN(tot)} (prompt ${fmtN(pt)}, completion ${fmtN(ct)}) — all providers and keys combined as counted by OmniRoute. OmniRoute estimates tokens when a provider returns no usage figures${an.data.includesFlatRateEstimates === true ? ' (this window includes flat-rate estimates)' : ''}. A rolling window, not a quota period: no reset time applies`, 'GET /api/usage/analytics?range=30d', { requests: reqs, totalTokens: tot, promptTokens: pt, completionTokens: ct });
    if (Array.isArray(an.data.byProvider)) for (const p of an.data.byProvider) {
      if (!isObj(p) || !str(p.provider)) continue;
      r.add(U, 'GATEWAY', `provider "${scrub(str(p.provider))}": requests ${fmtN(num(p.requests))}, tokens ${fmtN(num(p.totalTokens))} over the same 30 days (a view of the totals above, not additional usage)`, 'GET /api/usage/analytics?range=30d');
    }
  }

  const ft = await client.get('/api/free-tier/summary', { auth: 'mgmt' });
  const E = 'Documented free-tier estimate';
  if (!ft.ok) r.unknown(E, ft.reason, 'GET /api/free-tier/summary');
  else if (!isObj(ft.data)) r.unknown(E, 'malformed response', 'GET /api/free-tier/summary');
  else {
    const used = num(ft.data.usedThisMonth);
    if (used !== null) r.add(U, 'GATEWAY', `calendar-month tokens counted by OmniRoute: ${fmtN(used)} (all providers and keys combined; month boundary not exposed by this endpoint)`, 'GET /api/free-tier/summary');
    else r.unknown(U, 'month-to-date usage is withheld by OmniRoute unless a dashboard session authenticates (an access token does not unlock it); use the 30-day figure above', 'GET /api/free-tier/summary');
    const steady = num(ft.data.steadyRecurringTokens);
    const src = str(ft.data.catalogSource, 30), updated = str(ft.data.catalogUpdatedAt, 40);
    if (steady !== null) r.add(E, 'ESTIMATE', `catalog-wide documented recurring free allowance: ~${fmtN(steady)} tokens/month if EVERY listed provider were connected (${fmtN(num(ft.data.poolCount))} pools, ${fmtN(num(ft.data.modelCount))} models; catalog ${src ?? 'source unknown'}${updated ? ` of ${updated}` : ''}). This is NOT your quota and is never added to provider-reported figures. OmniRoute's own "remaining" field is intentionally ignored because it subtracts counted usage from this estimate`, 'GET /api/free-tier/summary');
    else r.unknown(E, 'steadyRecurringTokens missing or invalid', 'GET /api/free-tier/summary');
    // per-connected-provider documented budget: ONE value per shared pool (max, never a sum)
    const connectedProviders = new Set([...names.values()].map((n) => n.split(' ')[0]));
    if (Array.isArray(ft.data.perModel) && connectedProviders.size) {
      const pools = new Map();
      for (const m of ft.data.perModel) {
        if (!isObj(m) || !str(m.provider) || !connectedProviders.has(m.provider)) continue;
        const key = `${m.provider}::${str(m.poolKey) ?? m.modelId}`;
        const mt = num(m.monthlyTokens);
        const prev = pools.get(key);
        if (!prev || (mt ?? -1) > (prev.mt ?? -1)) pools.set(key, { provider: m.provider, pool: str(m.poolKey) ?? 'unpooled', mt, type: str(m.freeType, 30), tos: str(m.tos, 20), models: (prev?.models ?? 0) + 1 });
        else prev.models += 1;
      }
      for (const p of pools.values()) r.add(E, 'ESTIMATE', `${scrub(p.provider)} pool "${scrub(p.pool)}": documented ${p.mt === null ? 'budget not published' : `~${fmtN(p.mt)} tokens/month`} (${p.type ?? 'type unknown'}; ToS flag ${p.tos ?? 'unknown'}) shared by ${p.models} model entr${p.models === 1 ? 'y' : 'ies'} — counted once per pool. Documentation, not a live reading`, 'GET /api/free-tier/summary');
    }
  }

  r.unknown('Model availability', 'no documented read-only endpoint verified for per-model readiness: GET /v1/models lists the catalog even with no provider connected (observed), so it is not used as proof of availability', '(none)');
  return r;
}

// ---------------------------------------------------------------- rendering & CLI
export function render(report, { json = false, secrets = [] } = {}) {
  const counts = {};
  for (const i of report.items) counts[i.label] = (counts[i.label] ?? 0) + 1;
  if (json) return scrub(JSON.stringify({ gateway: report.gateway, baseUrl: report.baseUrl, generatedAt: report.generatedAt, readOnly: true, modelRequestsSent: 0, counts, items: report.items }, null, 2), secrets);
  const out = [];
  out.push(`${report.gateway} quota report — ${report.baseUrl} — ${report.generatedAt}`);
  out.push('Read-only: GET requests to documented status endpoints only; no model/generation requests were sent.');
  out.push(`Labels: [PROVIDER] ${LABELS.PROVIDER} | [GATEWAY] ${LABELS.GATEWAY} | [ESTIMATE] ${LABELS.ESTIMATE} | [UNKNOWN] ${LABELS.UNKNOWN}`);
  let section = null;
  for (const i of report.items) {
    if (i.section !== section) { section = i.section; out.push('', `== ${section} ==`); }
    out.push(`[${i.tag}] ${i.text}  (${i.source})`);
  }
  out.push('', `Summary: ${Object.entries(counts).map(([k, v]) => `${v} ${k}`).join('; ') || 'no data'}.`);
  out.push('No totals are computed across providers, keys or pools: they overlap, and estimates are never added to reported quota.');
  return scrub(out.join('\n'), secrets);
}

function parseArgs(argv) {
  const a = { json: false, listModels: false, maxAgeMin: null, timeoutMs: 15000 };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--gateway') a.gateway = argv[++i];
    else if (k === '--base-url') a.baseUrl = argv[++i];
    else if (k === '--json') a.json = true;
    else if (k === '--list-models') a.listModels = true;
    else if (k === '--max-age-min') a.maxAgeMin = Number(argv[++i]);
    else if (k === '--timeout-ms') a.timeoutMs = Number(argv[++i]);
    else throw new Error(`unknown option ${k}`);
  }
  if (!['freellmapi', 'omniroute'].includes(a.gateway)) throw new Error('--gateway must be freellmapi or omniroute');
  if (!a.baseUrl) throw new Error('--base-url is required');
  if (a.maxAgeMin !== null && !(a.maxAgeMin > 0)) throw new Error('--max-age-min must be > 0');
  return a;
}

export async function main(argv, env = process.env, fetchImpl = globalThis.fetch) {
  const a = parseArgs(argv);
  const secrets = { unified: env.FREELLMAPI_KEY, mgmt: env.OMNIROUTE_MGMT_TOKEN };
  const client = makeClient({ kind: a.gateway, baseUrl: a.baseUrl, secrets, timeoutMs: a.timeoutMs, fetchImpl });
  client.baseUrlForReport = new URL(a.baseUrl).origin;
  const report = a.gateway === 'freellmapi'
    ? await reportFreeLlmApi(client, { listModels: a.listModels })
    : await reportOmniRoute(client, { maxAgeMin: a.maxAgeMin });
  return { text: render(report, { json: a.json, secrets: client.secretValues }), client };
}

import { fileURLToPath } from 'node:url';
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main(process.argv.slice(2)).then(({ text }) => { process.stdout.write(text + '\n'); }, (e) => { process.stderr.write(`quota-report: ${scrub(e.message)}\n`); process.exit(2); });
}
