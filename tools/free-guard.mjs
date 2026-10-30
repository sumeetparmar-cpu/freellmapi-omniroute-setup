#!/usr/bin/env node
// free-guard: loopback reverse proxy that makes a gateway "free-only".
//   client -> free-guard (policy, rate limit, cooldown, quota) -> FreeLLMAPI | OmniRoute
// It never retries, never rewrites the model and never falls back: a blocked or throttled request
// gets a local 4xx and nothing is sent upstream. Authorization headers are forwarded but never logged.
// Zero dependencies (Node >= 20).
//
//   node free-guard.mjs --gateway freellmapi|omniroute --upstream http://127.0.0.1:3001 --listen 127.0.0.1:3101
//        [--client-keys-file F --upstream-key-file G]   clients present a guard key; the guard swaps in the gateway key (clients never see it)
//        [--allow-host name]...                          extra Host header values (e.g. the Caddy vhost); loopback names are always allowed
//        node free-guard.mjs --new-client-key LABEL --client-keys-file F    mint a client key (printed once; only its SHA-256 is stored)
//        [--policy file] [--state file] [--log file] [--catalog-audited] [--kill-file file] [--max-body-kb 1024] [--no-rate-limit]
// --catalog-audited (FreeLLMAPI only): the operator ran 'free-policy freellmapi apply' so every ENABLED catalog model is free;
//   'auto' and grouped model ids that the gateway itself serves are then accepted. --kill-file: while that file exists every
//   inference request is refused (written by 'free-policy ... audit --flag-file' when drift is detected).
import http from 'node:http';
import { readFileSync, writeFileSync, renameSync, appendFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { existsSync } from 'node:fs';
import { loadPolicy, classify, limitsFor, routeAllowed, inspectBody } from './lib/free-policy.mjs';

export function parseArgs(argv) {
  const o = { 'max-body-kb': '1024' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new Error(`unexpected argument ${a}`);
    const k = a.slice(2);
    if (['catalog-audited', 'no-rate-limit'].includes(k)) o[k] = true;
    else if (k === 'allow-host') (o['allow-host'] ??= []).push(argv[++i]);
    else o[k] = argv[++i];
  }
  return o;
}

function readClientHashes(file) {
  return readFileSync(file, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'))
    .map((l) => l.split(/\s+/)[0]).filter((h) => /^[0-9a-f]{64}$/.test(h)).map((h) => Buffer.from(h, 'hex'));
}

/** Mint a client key; only its SHA-256 (plus a label) is written to the file. The key itself is returned once. */
export function mintClientKey(file, label) {
  const key = `fg_${randomBytes(24).toString('base64url')}`;
  const hash = createHash('sha256').update(key).digest('hex');
  mkdirSync(path.dirname(file), { recursive: true });
  appendFileSync(file, `${hash} ${String(label).replace(/[^A-Za-z0-9._-]/g, '_')} ${new Date().toISOString()}\n`, { mode: 0o600 });
  return key;
}

export function createGuard(opts) {
  const policy = opts.policy ?? loadPolicy(opts.policyFile);
  const gateway = opts.gateway;
  if (!['freellmapi', 'omniroute'].includes(gateway)) throw new Error('--gateway must be freellmapi or omniroute');
  const up = new URL(opts.upstream);
  if (!['127.0.0.1', 'localhost', '::1'].includes(up.hostname) && !opts.allowRemoteUpstream) {
    throw new Error('upstream must be loopback (the guard is a local control, not a public proxy)');
  }
  const now = opts.now ?? (() => Date.now());
  const maxBody = Number(opts.maxBodyKb ?? 1024) * 1024;
  const state = { day: utcDay(now()), counts: {}, cooldowns: {}, blocked: 0, passed: 0, ...(readState(opts.stateFile) ?? {}) };
  state.windows ??= {};      // key -> timestamps (ms); persisted so a restart cannot be used to reset the rate limit
  const windows = new Map(Object.entries(state.windows));
  let dirty = false;
  let inflight = 0;
  const maxInflight = Number(opts.maxInflight ?? 16);
  const allowedHosts = new Set(['127.0.0.1', 'localhost', '[::1]', ...(opts.allowedHosts ?? [])].map((h) => h.toLowerCase()));
  // Client keys: hashes only. Clients authenticate to the guard; the gateway key lives in a 0600 file the clients cannot read.
  const clientHashes = opts.clientKeysFile ? readClientHashes(opts.clientKeysFile) : null;
  const upstreamAuth = opts.upstreamKeyFile ? `Bearer ${readFileSync(opts.upstreamKeyFile, 'utf8').trim()}` : null;
  if (!!clientHashes !== !!upstreamAuth) throw new Error('--client-keys-file and --upstream-key-file must be used together');
  if (clientHashes && clientHashes.length === 0) throw new Error('client keys file has no keys (use --new-client-key)');
  function clientOk(authHeader) {
    const m = /^Bearer ([A-Za-z0-9_-]{16,200})$/.exec(authHeader ?? '');
    if (!m) return false;
    const h = createHash('sha256').update(m[1]).digest();
    let ok = false;
    for (const x of clientHashes) if (timingSafeEqual(h, x)) ok = true; // no early exit: constant work per key
    return ok;
  }
  const served = new Map(); // sha256(auth) -> { at, ids:Set }
  async function servedModels(auth) {
    const k = createHash('sha256').update(auth ?? '').digest('hex'); const c = served.get(k);
    if (c && now() - c.at < 60_000) return c.ids;
    const ids = await new Promise((resolve) => {
      const r = http.request({ hostname: up.hostname, port: up.port, path: '/v1/models', method: 'GET', headers: auth ? { authorization: auth } : {}, timeout: 10_000 }, (x) => {
        let t = ''; x.on('data', (d) => (t += d)); x.on('end', () => { try { resolve(new Set(JSON.parse(t).data.map((m) => m.id))); } catch { resolve(null); } });
      });
      r.on('error', () => resolve(null)); r.on('timeout', () => r.destroy()); r.end();
    });
    if (ids) served.set(k, { at: now(), ids });
    return ids;
  }

  function utcDay(ms) { return new Date(ms).toISOString().slice(0, 10); }
  function readState(f) { try { return f ? JSON.parse(readFileSync(f, 'utf8')) : null; } catch { return null; } }
  function persist() {
    if (!opts.stateFile || !dirty) return;
    mkdirSync(path.dirname(opts.stateFile), { recursive: true });
    const tmp = `${opts.stateFile}.${process.pid}.tmp`;
    const t = now(); state.windows = {};
    for (const [k, w] of windows) { const f = w.filter((x) => t - x < 60_000); if (f.length) state.windows[k] = f; }
    writeFileSync(tmp, JSON.stringify(state), { mode: 0o600 });
    renameSync(tmp, opts.stateFile);
    dirty = false;
  }
  function rollDay() {
    const d = utcDay(now());
    if (d !== state.day) { state.day = d; state.counts = {}; dirty = true; }
  }
  function log(rec) {
    const line = JSON.stringify({ t: new Date(now()).toISOString(), ...rec });
    if (opts.logFile) { try { appendFileSync(opts.logFile, line + '\n', { mode: 0o600 }); } catch { /* logging must never break serving */ } }
    else if (!opts.quiet) process.stderr.write(line + '\n');
  }
  function deny(res, status, type, message, extra = {}, headers = {}) {
    state.blocked++; dirty = true;
    const body = JSON.stringify({ error: { message, type, code: type, free_guard: true } });
    res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body), ...headers });
    res.end(body);
    log({ ev: 'deny', status, type, ...extra });
  }
  function throttle(key, rpm) {
    const t = now(); const w = (windows.get(key) ?? []).filter((x) => t - x < 60_000);
    if (w.length >= rpm) { windows.set(key, w); return Math.ceil((60_000 - (t - w[0])) / 1000); }
    w.push(t); windows.set(key, w); return 0;
  }
  function cooldownLeft(key) { const c = state.cooldowns[key]; return c && c.until > now() ? Math.ceil((c.until - now()) / 1000) : 0; }
  function startCooldown(key, retryAfterSec) {
    const prev = state.cooldowns[key];
    const strikes = prev && prev.until + 600_000 > now() ? prev.strikes + 1 : 1;
    const secs = retryAfterSec ?? Math.min(900, 30 * 2 ** (strikes - 1));
    state.cooldowns[key] = { until: now() + secs * 1000, strikes }; dirty = true; persist();
    return secs;
  }

  function status() {
    rollDay();
    const cd = Object.fromEntries(Object.entries(state.cooldowns).filter(([, c]) => c.until > now()).map(([k, c]) => [k, Math.ceil((c.until - now()) / 1000)]));
    return { gateway, day: state.day, passed: state.passed, blocked: state.blocked, requestsToday: state.counts, cooldownsSec: cd,
      caps: Object.fromEntries(Object.keys(policy.providers).map((p) => [p, limitsFor(policy, p)])), catalogAudited: !!opts.catalogAudited, killSwitch: !!(opts.killFile && existsSync(opts.killFile)) };
  }

  const server = http.createServer((req, res) => {
    let url;
    try { url = new URL(req.url, 'http://x'); } catch { return deny(res, 400, 'bad_url', 'bad request URL'); }
    // DNS-rebinding / wrong-vhost defence: only names we expect.
    const host = String(req.headers.host ?? '').toLowerCase().replace(/:\d+$/, '');
    if (!allowedHosts.has(host)) { req.resume(); return deny(res, 421, 'bad_host', 'Host header not allowed'); }
    if (url.pathname === '/__guard/status') {
      const ra = req.socket.remoteAddress ?? '';
      const proxied = ['x-forwarded-for', 'forwarded', 'x-real-ip', 'via', 'x-forwarded-host'].some((h) => h in req.headers);
      if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(ra) || proxied) return deny(res, 403, 'forbidden', 'status is local-only (not reachable through a reverse proxy)');
      res.writeHead(200, { 'content-type': 'application/json' }); return res.end(JSON.stringify(status()));
    }
    if (!routeAllowed(policy, req.method, url.pathname)) {
      req.resume();
      return deny(res, 403, 'route_blocked', `${req.method} ${url.pathname} is not allowed by the free-only policy`, { path: url.pathname });
    }
    if (clientHashes && !clientOk(req.headers.authorization)) {
      req.resume();
      return deny(res, 401, 'unauthorized', 'missing or invalid free-guard client key', {}, { 'www-authenticate': 'Bearer' });
    }
    if (inflight >= maxInflight) { req.resume(); return deny(res, 503, 'busy', 'too many in-flight requests', {}, { 'retry-after': '2' }); }
    inflight++; let released = false;
    const release = () => { if (!released) { released = true; inflight--; } };
    res.on('close', release);
    const chunks = []; let size = 0; let aborted = false;
    req.on('data', (c) => {
      size += c.length;
      if (size > maxBody && !aborted) { aborted = true; deny(res, 413, 'body_too_large', 'request body too large'); req.destroy(); }
      else if (!aborted) chunks.push(c);
    });
    req.on('end', async () => {
      if (aborted) return;
      const raw = Buffer.concat(chunks);
      let meta = { provider: undefined, model: undefined };
      if (req.method === 'POST') {
        if (!/^application\/json(\s*;.*)?$/i.test(String(req.headers['content-type'] ?? ''))) {
          return deny(res, 415, 'unsupported_media_type', 'POST bodies must be application/json (other types are parsed differently by the gateway)');
        }
        let body;
        try { body = raw.length ? JSON.parse(raw.toString('utf8')) : {}; } catch { return deny(res, 400, 'bad_json', 'body must be JSON'); }
        const bad = inspectBody(policy, body);
        if (bad) return deny(res, 403, 'param_blocked', bad);
        if (opts.killFile && existsSync(opts.killFile)) return deny(res, 503, 'kill_switch', 'free-only audit failed; inference is suspended until `free-policy audit` passes');
        if (body.model !== undefined && (typeof body.model !== 'string' || (body.model !== '' && !/^[\x21-\x7e]+$/.test(body.model)))) {
          return deny(res, 403, 'model_blocked', 'model must be a plain printable-ASCII string');
        }
        let v = classify(policy, gateway, body.model, { allowAuto: !!opts.catalogAudited });
        if (!v.ok && gateway === 'freellmapi' && opts.catalogAudited && typeof body.model === 'string' && body.model && !(policy.blockedGroupedIds ?? []).includes(body.model)) {
          const ids = await servedModels(upstreamAuth ?? req.headers.authorization);
          if (ids?.has(body.model)) v = { ok: true, provider: 'freellmapi', model: body.model };
        }
        if (!v.ok) return deny(res, 403, 'model_blocked', `model blocked by free-only policy: ${v.reason}`, { model: String(body.model ?? ''), provider: v.provider });
        meta = v;
      }
      forward(req, res, url, raw, meta);
    });
  });

  function forward(req, res, url, raw, meta) {
    rollDay();
    const pKey = meta.provider ?? 'meta';
    const mKey = meta.model ? `${pKey}:${meta.model}` : pKey;
    if (meta.provider && meta.provider !== 'auto') {
      const cd = cooldownLeft(mKey) || cooldownLeft(pKey);
      if (cd) return deny(res, 429, 'cooldown', `provider cooling down after upstream errors; retry in ${cd}s`, { provider: pKey, model: meta.model }, { 'retry-after': String(cd) });
      const lim = limitsFor(policy, pKey);
      if (!opts.noRateLimit) {
        const w = throttle(mKey, lim.rpm);
        if (w) return deny(res, 429, 'local_rate_limit', `local rate limit for ${mKey} (${lim.rpm}/min); retry in ${w}s`, { provider: pKey, model: meta.model }, { 'retry-after': String(w) });
        if ((state.counts[pKey] ?? 0) >= lim.rpd) return deny(res, 429, 'daily_cap', `self-imposed daily cap for ${pKey} reached (${lim.rpd}/day, resets 00:00 UTC)`, { provider: pKey }, { 'retry-after': '3600' });
      }
      state.counts[pKey] = (state.counts[pKey] ?? 0) + 1; dirty = true;
      persist(); // write-through: a crash or restart right after a request must not give the quota back
    }
    // Forward an ALLOWLIST of headers only: routing/pinning headers (x-omniroute-*, x-freellm-*, session ids, cookies,
    // forwarding headers) never reach the gateway, so a client cannot steer it around the model we validated.
    const headers = { host: up.host, 'content-length': String(raw.length) };
    for (const h of ['content-type', 'accept', 'user-agent', 'x-request-id', 'idempotency-key']) if (req.headers[h]) headers[h] = req.headers[h];
    if (upstreamAuth) headers.authorization = upstreamAuth;
    else { if (req.headers.authorization) headers.authorization = req.headers.authorization; if (req.headers['x-api-key']) headers['x-api-key'] = req.headers['x-api-key']; }
    const t0 = now();
    const preq = http.request({ hostname: up.hostname, port: up.port, path: url.pathname, method: req.method, headers }, (pres) => {
      state.passed++; dirty = true;
      if (meta.provider && (pres.statusCode === 429 || pres.statusCode >= 500)) {
        const ra = Number.parseInt(pres.headers['retry-after'], 10);
        const secs = startCooldown(mKey, Number.isFinite(ra) ? Math.min(ra, 3600) : undefined);
        log({ ev: 'cooldown', provider: pKey, model: meta.model, upstream: pres.statusCode, secs });
      }
      log({ ev: 'pass', provider: pKey, model: meta.model, status: pres.statusCode, ms: now() - t0 });
      res.writeHead(pres.statusCode, pres.headers); pres.pipe(res);
    });
    res.on('close', () => { if (!res.writableFinished) preq.destroy(); }); // client went away: stop the upstream work
    preq.on('error', (e) => deny(res, 502, 'upstream_unreachable', `gateway unreachable (${e.code ?? 'error'}); no fallback is attempted`, { provider: pKey }));
    preq.setTimeout(Number(opts.timeoutMs ?? 120_000), () => preq.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })));
    preq.end(raw);
  }

  server.headersTimeout = 15_000; server.requestTimeout = 60_000; server.maxHeadersCount = 64; server.keepAliveTimeout = 5_000;
  const timer = setInterval(persist, 5000); timer.unref();
  server.on('close', () => { clearInterval(timer); persist(); });
  return { server, status, persist };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const a = parseArgs(process.argv.slice(2));
    if (a['new-client-key']) {
      if (!a['client-keys-file']) throw new Error('--new-client-key needs --client-keys-file');
      process.stdout.write(mintClientKey(a['client-keys-file'], a['new-client-key']) + '\n');
      process.exit(0);
    }
    if (!a.gateway || !a.upstream) throw new Error('--gateway and --upstream are required');
    const [host, port] = (a.listen ?? '127.0.0.1:3101').split(/:(?=[^:]*$)/);
    if (!['127.0.0.1', 'localhost', '::1'].includes(host)) throw new Error('--listen must be loopback; put Caddy/Tailscale in front if you need remote access');
    const g = createGuard({ gateway: a.gateway, upstream: a.upstream, policyFile: a.policy, stateFile: a.state, logFile: a.log,
      catalogAudited: !!a['catalog-audited'], killFile: a['kill-file'], noRateLimit: !!a['no-rate-limit'], maxBodyKb: a['max-body-kb'],
      clientKeysFile: a['client-keys-file'], upstreamKeyFile: a['upstream-key-file'], allowedHosts: a['allow-host'] ?? [] });
    g.server.listen(Number(port), host, () => process.stderr.write(`free-guard ${a.gateway} ${host}:${port} -> ${a.upstream}\n`));
    for (const s of ['SIGINT', 'SIGTERM']) process.on(s, () => g.server.close(() => process.exit(0)));
  } catch (e) { process.stderr.write(`free-guard: ${e.message}\n`); process.exit(2); }
}
