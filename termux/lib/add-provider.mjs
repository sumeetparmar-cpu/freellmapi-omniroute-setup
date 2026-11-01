#!/usr/bin/env node
// Add ONE free-tier provider key (Groq or Gemini) to the local gateways through their own APIs. Idempotent. Never prints the key.
// The key is read from the environment variable PROVIDER_KEY (set only for this one process; never on a command line).
//   PROVIDER_KEY=... node add-provider.mjs --provider groq|gemini [--gateway both|freellmapi|omniroute]
//        [--fl-base http://127.0.0.1:3001] [--or-base http://127.0.0.1:20128] [--cred-file F] [--env-file F]
// FreeLLMAPI: POST /api/keys {platform: groq|google}; its default-enabled models are then pruned to the policy by `free-guard.sh audit`.
// OmniRoute: POST /api/providers {provider: groq|gemini, apiKey} and activate the connection (it is created inactive).
import { readFileSync, existsSync } from 'node:fs';

const a = process.argv.slice(2);
const opt = (k, d) => { const i = a.indexOf(`--${k}`); return i >= 0 ? a[i + 1] : d; };
const provider = opt('provider'); const gateway = opt('gateway', 'both');
const flBase = String(opt('fl-base', 'http://127.0.0.1:3001')).replace(/\/+$/, ''); const orBase = String(opt('or-base', 'http://127.0.0.1:20128')).replace(/\/+$/, '');
const credFile = opt('cred-file'); const envFile = opt('env-file');
const key = (process.env.PROVIDER_KEY ?? '').trim(); delete process.env.PROVIDER_KEY;
const log = (m) => process.stdout.write(`${m}\n`);
const die = (m) => { process.stderr.write(`add-provider: ${m}\n`); process.exit(1); };

const MAP = { groq: { fl: 'groq', or: 'groq', label: 'Groq', shape: /^gsk_[A-Za-z0-9]{20,}$/ }, gemini: { fl: 'google', or: 'gemini', label: 'Gemini', shape: /^AIza[A-Za-z0-9_-]{20,}$/ } };
const P = MAP[provider];
if (!P || !['both', 'freellmapi', 'omniroute'].includes(gateway)) die('usage: --provider groq|gemini [--gateway both|freellmapi|omniroute]');
for (const b of [flBase, orBase]) if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(b)) die('gateway URLs must be loopback http');
if (!key) die('no key given (PROVIDER_KEY is empty)');
if (!P.shape.test(key)) die(`that does not look like a ${P.label} API key (wrong prefix or length). Nothing was changed. Copy the key again from the provider's dashboard.`);

const kv = (f) => { const o = {}; if (f && existsSync(f)) for (const l of readFileSync(f, 'utf8').split('\n')) { const m = /^([A-Z0-9_]+)=(.*)$/.exec(l.trim()); if (m) o[m[1]] = m[2]; } return o; };
async function http(base, method, p, { token, cookie, body } = {}) {
  const headers = { accept: 'application/json' };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (token) headers.authorization = `Bearer ${token}`;
  if (cookie) headers.cookie = cookie;
  let res;
  try { res = await fetch(`${base}${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(90_000), redirect: 'manual' }); }
  catch (e) { die(`${method} ${p}: gateway not reachable (${e.cause?.code ?? e.name}). Start the gateways: bash gateways.sh start`); }
  const text = await res.text(); let json = null; try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: res.status, json, headers: res.headers };
}
const safe = (s) => String(s ?? '').split(key).join('[key]').slice(0, 140);   // never echo the key back, even inside an error message

async function toFreellmapi() {
  const c = kv(credFile); const email = c.FREELLMAPI_ADMIN_EMAIL ?? process.env.FREELLMAPI_ADMIN_EMAIL; const password = c.FREELLMAPI_ADMIN_PASSWORD ?? process.env.FREELLMAPI_ADMIN_PASSWORD;
  if (!password) die('FreeLLMAPI login not available (expected the credentials file written by the bootstrap)');
  const lg = await http(flBase, 'POST', '/api/auth/login', { body: { email, password } });
  const token = lg.json?.token; if (!token) die('FreeLLMAPI rejected the stored login');
  const list = await http(flBase, 'GET', '/api/keys', { token }); const keys = Array.isArray(list.json) ? list.json : (list.json?.keys ?? []);
  if (keys.some((k) => k.platform === P.fl)) { log(`freellmapi: a ${P.label} key is already configured (kept; nothing changed)`); return; }
  const r = await http(flBase, 'POST', '/api/keys', { token, body: { platform: P.fl, key, label: `termux-${provider}` } });
  if (r.status >= 300) die(`FreeLLMAPI refused the ${P.label} key (HTTP ${r.status}: ${safe(r.json?.error?.message ?? r.json?.error)})`);
  log(`freellmapi: ${P.label} key added (stored encrypted by the gateway; ${r.json?.modelsAvailable ?? '?'} models available before the policy prune)`);
}
async function toOmniroute() {
  const pw = [process.env.OMNIROUTE_ADMIN_PASSWORD, kv(envFile).INITIAL_PASSWORD].filter(Boolean);
  if (!pw.length) die('OmniRoute admin password not available (expected the env file written by the bootstrap)');
  let cookie = '';
  for (const p of pw) { const lg = await http(orBase, 'POST', '/api/auth/login', { body: { password: p } }); cookie = (lg.headers.getSetCookie?.() ?? []).map((x) => x.split(';')[0]).join('; '); if (lg.status < 300 && cookie) break; cookie = ''; }
  if (!cookie) die('OmniRoute login failed (the admin password may have been changed; run again with OMNIROUTE_ADMIN_PASSWORD set)');
  const conns = async () => (await http(orBase, 'GET', '/api/providers', { cookie })).json?.connections ?? [];
  let conn = (await conns()).find((x) => x.provider === P.or);
  if (!conn) {
    const r = await http(orBase, 'POST', '/api/providers', { cookie, body: { provider: P.or, name: P.label, apiKey: key } });
    if (r.status >= 300) die(`OmniRoute refused the ${P.label} key (HTTP ${r.status}: ${safe(r.json?.error?.message ?? r.json?.error)})`);
    conn = (await conns()).find((x) => x.provider === P.or);
    if (!conn) die('the OmniRoute connection was not created');
    log(`omniroute: ${P.label} connection created (key stored encrypted by the gateway)`);
  } else log(`omniroute: a ${P.label} connection already exists (kept; key not changed)`);
  if (!conn.isActive) {
    const r = await http(orBase, 'PATCH', `/api/providers/${conn.id}`, { cookie, body: { isActive: true } });
    if (r.status >= 300) die(`could not activate the ${P.label} connection (HTTP ${r.status})`);
    log(`omniroute: ${P.label} connection activated`);
  }
}
if (gateway !== 'omniroute') await toFreellmapi();
if (gateway !== 'freellmapi') await toOmniroute();
