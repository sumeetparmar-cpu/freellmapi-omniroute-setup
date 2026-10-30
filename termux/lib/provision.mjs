#!/usr/bin/env node
// Configure the keyless OVH anonymous route in a freshly installed gateway, through its own local HTTP API (no dashboard clicking).
// Idempotent: safe to run again. Zero dependencies (Node >= 20). Talks to loopback only. Never prints a secret.
//
//   node provision.mjs freellmapi --base http://127.0.0.1:3001  --cred-file F --key-out F
//   node provision.mjs omniroute  --base http://127.0.0.1:20128 --env-file  F --key-out F
//
// FreeLLMAPI: creates the owner account on first run (password generated into --cred-file, mode 600), adds a custom endpoint for OVH's
//   anonymous API (no key), and stores the gateway's unified API key in --key-out.
// OmniRoute: logs in with INITIAL_PASSWORD from --env-file, adds the custom OpenAI-compatible node (prefix `ovhanon`) and ONE keyless
//   connection, activates it, and stores a new gateway API key in --key-out.
// Nothing here connects a paid provider, and nothing else is ever added.
import { readFileSync, writeFileSync, existsSync, mkdirSync, chmodSync, statSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import path from 'node:path';

const OVH = 'https://oai.endpoints.kepler.ai.cloud.ovh.net/v1';
const OVH_FL_MODEL = 'gpt-oss-20b';
const OWNER_EMAIL = 'owner@gateway.invalid';

const a = process.argv.slice(2);
const target = a[0];
const opt = (k) => { const i = a.indexOf(`--${k}`); return i >= 0 ? a[i + 1] : undefined; };
const base = (opt('base') ?? '').replace(/\/+$/, '');
const log = (m) => process.stdout.write(`${m}\n`);
const die = (m) => { process.stderr.write(`provision: ${m}\n`); process.exit(1); };

if (!['freellmapi', 'omniroute'].includes(target) || !base) die('usage: provision.mjs <freellmapi|omniroute> --base URL ...');
if (!/^http:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/.test(base)) die('--base must be a loopback http URL (this tool configures local gateways only)');

function readKv(file) {
  const o = {};
  if (!existsSync(file)) return o;
  for (const l of readFileSync(file, 'utf8').split('\n')) { const m = /^([A-Z0-9_]+)=(.*)$/.exec(l.trim()); if (m) o[m[1]] = m[2]; }
  return o;
}
function writeSecret(file, text) {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, text, { mode: 0o600 });
  chmodSync(file, 0o600);
}
async function http(method, p, { token, cookie, body } = {}) {
  const headers = { accept: 'application/json' };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (token) headers.authorization = `Bearer ${token}`;
  if (cookie) headers.cookie = cookie;
  let res;
  try { res = await fetch(`${base}${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(60_000), redirect: 'manual' }); }
  catch (e) { die(`${method} ${p}: gateway not reachable (${e.cause?.code ?? e.name})`); }
  let json = null; const text = await res.text(); try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: res.status, json, headers: res.headers };
}
const sameUrl = (x, y) => String(x ?? '').replace(/\/+$/, '') === String(y).replace(/\/+$/, '');

async function freellmapi() {
  const credFile = opt('cred-file'); const keyOut = opt('key-out');
  if (!credFile || !keyOut) die('--cred-file and --key-out are required');
  let cred = readKv(credFile);
  if (!cred.FREELLMAPI_ADMIN_PASSWORD) {
    // Passwords need upper/lower/digit/symbol; hex alone would not pass the gateway's rule.
    cred = { FREELLMAPI_ADMIN_EMAIL: OWNER_EMAIL, FREELLMAPI_ADMIN_PASSWORD: `Aa1-${randomBytes(18).toString('hex')}` };
    writeSecret(credFile, `FREELLMAPI_ADMIN_EMAIL=${cred.FREELLMAPI_ADMIN_EMAIL}\nFREELLMAPI_ADMIN_PASSWORD=${cred.FREELLMAPI_ADMIN_PASSWORD}\n`);
  }
  const creds = { email: cred.FREELLMAPI_ADMIN_EMAIL ?? OWNER_EMAIL, password: cred.FREELLMAPI_ADMIN_PASSWORD };
  const st = await http('GET', '/api/auth/status');
  if (st.json?.needsSetup) {
    const r = await http('POST', '/api/auth/setup', { body: creds });
    if (r.status >= 300) die(`could not create the FreeLLMAPI owner account (HTTP ${r.status})`);
    log('freellmapi: owner account created (credentials in the 0600 file ' + path.basename(credFile) + ')');
  }
  const lg = await http('POST', '/api/auth/login', { body: creds });
  const token = lg.json?.token;
  if (!token) die('FreeLLMAPI already has an owner account that this tool did not create. Remove ~/llm-gateways/freellmapi-data/ (only if it holds nothing you need) and re-run, or add the OVH endpoint in the dashboard (docs/FREE-ONLY.md).');
  const keys = await http('GET', '/api/keys', { token });
  const list = Array.isArray(keys.json) ? keys.json : (keys.json?.keys ?? []);
  if (list.some((k) => k.platform === 'custom' && sameUrl(k.baseUrl, OVH))) log('freellmapi: OVH anonymous endpoint already present');
  else {
    const r = await http('POST', '/api/keys/custom', { token, body: { baseUrl: OVH, label: 'OVH anonymous (keyless)', model: OVH_FL_MODEL } });
    if (r.status >= 300) die(`could not add the OVH endpoint to FreeLLMAPI (HTTP ${r.status}: ${String(r.json?.error ?? '').slice(0, 120)})`);
    log('freellmapi: added the keyless OVH anonymous endpoint');
  }
  const ak = await http('GET', '/api/settings/api-key', { token });
  const key = ak.json?.apiKey ?? ak.json?.key ?? ak.json?.unifiedKey;
  if (!key) die('could not read the FreeLLMAPI unified API key');
  writeSecret(keyOut, `${key}\n`);
  // The model must now be served through the unified key.
  for (let i = 0; i < 8; i++) {
    const m = await http('GET', '/v1/models', { token: key });
    if ((m.json?.data ?? []).some((x) => x.id === OVH_FL_MODEL)) { log(`freellmapi: model ${OVH_FL_MODEL} is served`); return; }
    await new Promise((r) => setTimeout(r, 1500));
  }
  die(`${OVH_FL_MODEL} is not served by FreeLLMAPI after configuration`);
}

async function omniroute() {
  const envFile = opt('env-file'); const keyOut = opt('key-out');
  if (!envFile || !keyOut) die('--env-file and --key-out are required');
  const pw = readKv(envFile).INITIAL_PASSWORD;
  if (!pw) die('INITIAL_PASSWORD not found in the OmniRoute env file');
  const lg = await http('POST', '/api/auth/login', { body: { password: pw } });
  const cookie = (lg.headers.getSetCookie?.() ?? []).map((c) => c.split(';')[0]).join('; ');
  if (lg.status >= 300 || !cookie) die(`OmniRoute login failed (HTTP ${lg.status}); the admin password may have been changed in the dashboard`);
  const nodesOf = async () => (await http('GET', '/api/provider-nodes', { cookie })).json?.nodes ?? [];
  let node = (await nodesOf()).find((n) => n.prefix === 'ovhanon');
  if (node) log('omniroute: node ovhanon already present');
  else {
    const r = await http('POST', '/api/provider-nodes', { cookie, body: { name: 'OVH anonymous', prefix: 'ovhanon', apiType: 'chat', baseUrl: OVH } });
    if (r.status >= 300) die(`could not create the ovhanon node (HTTP ${r.status})`);
    node = (await nodesOf()).find((n) => n.prefix === 'ovhanon');
    if (!node) die('the ovhanon node was not created');
    log('omniroute: created node ovhanon -> OVH anonymous endpoint');
  }
  if (!sameUrl(node.baseUrl, OVH)) die(`node ovhanon points at ${node.baseUrl}, not the OVH anonymous endpoint; refusing to continue (free-only policy)`);
  const connsOf = async () => (await http('GET', '/api/providers', { cookie })).json?.connections ?? [];
  let conn = (await connsOf()).find((c) => c.provider === node.id);
  if (!conn) {
    const r = await http('POST', '/api/providers', { cookie, body: { provider: node.id, name: 'OVH anonymous' } });
    if (r.status >= 300) die(`could not create the keyless connection (HTTP ${r.status})`);
    conn = (await connsOf()).find((c) => c.provider === node.id);
    if (!conn) die('the connection was not created');
    log('omniroute: created the keyless connection');
  }
  if (!conn.isActive) {
    const r = await http('PATCH', `/api/providers/${conn.id}`, { cookie, body: { isActive: true } });
    if (r.status >= 300) die(`could not activate the connection (HTTP ${r.status})`);
    log('omniroute: connection activated');
  }
  if (existsSync(keyOut) && statSync(keyOut).size > 8) log('omniroute: gateway API key already stored');
  else {
    const r = await http('POST', '/api/keys', { cookie, body: { name: 'termux-guard' } });
    const key = r.json?.key ?? r.json?.apiKey;
    if (!key) die(`could not create an OmniRoute API key (HTTP ${r.status})`);
    writeSecret(keyOut, `${key}\n`);
    log('omniroute: created a gateway API key (stored 0600)');
  }
}

await (target === 'freellmapi' ? freellmapi() : omniroute());
