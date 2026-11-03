// node --test tests/guard/anthropic.test.mjs   The Anthropic Messages routes (what Claude Code calls) through free-guard.
// Loopback stand-in gateway only; every case asserts what the UPSTREAM actually received.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGuard, mintClientKey } from '../../tools/free-guard.mjs';
import { loadPolicy } from '../../tools/lib/free-policy.mjs';

const policy = loadPolicy();
const listen = (s) => new Promise((r) => s.listen(0, '127.0.0.1', () => r(s.address().port)));
const GWTOK = ['zz', 'gw', 'tok', '0123'].join('-');
const OVH = 'ovhanon/gpt-oss-120b';   // OVH keyless route via the OmniRoute custom node: 2 requests/minute in the policy
const msg = (model, extra = {}) => ({ model, max_tokens: 64, messages: [{ role: 'user', content: 'hi' }], ...extra });
// Claude Code's own tools are plain client tools: name + input_schema, no type.
const ccTool = { name: 'Edit', description: 'edit a file', input_schema: { type: 'object', properties: { file_path: { type: 'string' } } } };

async function rig(gateway = 'omniroute', opts = {}, upstreamImpl) {
  const seen = [];
  const up = http.createServer((q, s) => {
    let b = ''; q.on('data', (c) => (b += c)); q.on('end', () => {
      seen.push({ method: q.method, url: q.url, headers: q.headers, body: b });
      if (upstreamImpl) return upstreamImpl(q, s, b);
      s.writeHead(200, { 'content-type': 'application/json' });
      s.end(JSON.stringify({ type: 'message', role: 'assistant', content: [{ type: 'text', text: 'ok' }], stop_reason: 'end_turn' }));
    });
  });
  const upPort = await listen(up);
  let clock = Date.UTC(2026, 10, 3, 12, 0, 0);
  const g = createGuard({ gateway, upstream: `http://127.0.0.1:${upPort}`, policy, quiet: true, now: () => clock, ...opts });
  const port = await listen(g.server);
  const call = (method, path, body, headers = {}) => new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body);
    const r = http.request({ host: '127.0.0.1', port, path, method, headers: { 'content-type': 'application/json', 'anthropic-version': '2023-06-01', ...headers } }, (res) => {
      let t = ''; res.on('data', (c) => (t += c)); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: t, json: (() => { try { return JSON.parse(t); } catch { return null; } })() }));
    });
    r.on('error', reject); if (data) r.write(data); r.end();
  });
  return { call, seen, advance: (ms) => { clock += ms; }, close: () => { g.server.close(); up.close(); up.closeAllConnections?.(); g.server.closeAllConnections?.(); } };
}

test('a Claude Code request (custom tools, ?beta=true) passes; only allowlisted headers reach the gateway', async () => {
  const r = await rig();
  try {
    const x = await r.call('POST', '/v1/messages?beta=true', msg(OVH, { tools: [ccTool, { ...ccTool, name: 'Read', type: 'custom' }], stream: false }),
      { 'anthropic-beta': 'context-1m-2025-08-07', 'x-omniroute-provider': 'openai', cookie: 'a=b' });
    assert.equal(x.status, 200);
    assert.equal(r.seen.length, 1);
    assert.equal(r.seen[0].url, '/v1/messages', 'query string is dropped');
    const h = r.seen[0].headers;
    assert.equal(h['anthropic-version'], '2023-06-01');
    for (const k of ['anthropic-beta', 'x-omniroute-provider', 'cookie']) assert.ok(!(k in h), `${k} must not be forwarded`);
    assert.equal(JSON.parse(r.seen[0].body).model, OVH, 'model is never rewritten');
  } finally { r.close(); }
});

test('paid, aliased and Claude model names are refused with an Anthropic-shaped error; nothing is forwarded', async () => {
  const r = await rig();
  try {
    for (const m of ['claude-sonnet-4-5', 'anthropic/claude-sonnet-4-5', 'auto', 'openai/gpt-4o', 'ovhanon/gpt-4o', 'openrouter/openai/gpt-4o', '']) {
      const x = await r.call('POST', '/v1/messages', msg(m));
      assert.equal(x.status, 403, m);
      assert.equal(x.json.type, 'error', m);
      assert.equal(x.json.error.type, 'permission_error', m);
      assert.equal(x.json.error.free_guard, true, m);
    }
    assert.equal(r.seen.length, 0);
  } finally { r.close(); }
});

test('Anthropic server/built-in tools and server-side features are blocked', async () => {
  const r = await rig();
  try {
    for (const type of ['web_search_20250305', 'web_fetch_20250910', 'code_execution_20250825', 'bash_20250124', 'text_editor_20250728', 'computer_20250124', 'memory_20250818', 'function']) {
      const x = await r.call('POST', '/v1/messages', msg(OVH, { tools: [ccTool, { type, name: 'x' }] }));
      assert.equal(x.status, 403, type); assert.match(x.json.error.message, /tool type/, type);
    }
    for (const extra of [{ mcp_servers: [{ type: 'url', url: 'https://example.invalid/mcp', name: 'x' }] }, { container: 'c' }, { tools: { a: 1 } }, { tools: ['x'] }, { tools: [null] }, { fallbacks: [] }]) {
      const x = await r.call('POST', '/v1/messages', msg(OVH, extra));
      assert.equal(x.status, 403, JSON.stringify(extra));
    }
    assert.equal(r.seen.length, 0);
  } finally { r.close(); }
});

test('client keys: Bearer or x-api-key on the Anthropic routes; the gateway only ever sees its own key', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'fga-')); const keys = join(dir, 'clients'); const upk = join(dir, 'upstream.key');
  writeFileSync(upk, GWTOK + '\n', { mode: 0o600 });
  const k = mintClientKey(keys, 'claude-code');
  const r = await rig('omniroute', { clientKeysFile: keys, upstreamKeyFile: upk });
  try {
    for (const h of [{}, { 'x-api-key': `${k}x` }, { 'x-api-key': GWTOK }, { authorization: `Bearer ${GWTOK}` }, { 'x-api-key': '' }]) {
      const x = await r.call('POST', '/v1/messages', msg(OVH), h);
      assert.equal(x.status, 401, JSON.stringify(h)); assert.equal(x.json.error.type, 'authentication_error');
    }
    assert.equal(r.seen.length, 0);
    for (const h of [{ 'x-api-key': k }, { authorization: `Bearer ${k}` }]) {
      const x = await r.call('POST', '/v1/messages', msg(OVH), h);
      assert.equal(x.status, 200, JSON.stringify(Object.keys(h)));
      const up = r.seen.at(-1).headers;
      assert.equal(up.authorization, `Bearer ${GWTOK}`); assert.ok(!('x-api-key' in up), 'the client key never reaches the gateway');
      r.advance(61_000);   // stay under the 2/min OVH limit
    }
    // x-api-key stays an Anthropic-route feature: the OpenAI routes still need Bearer
    assert.equal((await r.call('POST', '/v1/chat/completions', msg(OVH), { 'x-api-key': k })).status, 401);
  } finally { r.close(); }
});

test('count_tokens: model still checked, but it is not metered against the provider limit', async () => {
  const r = await rig();
  try {
    assert.equal((await r.call('POST', '/v1/messages/count_tokens', msg('openai/gpt-4o'))).status, 403);
    for (let i = 0; i < 5; i++) assert.equal((await r.call('POST', '/v1/messages/count_tokens', msg(OVH))).status, 200, `count ${i}`);
    assert.equal((await r.call('POST', '/v1/messages', msg(OVH))).status, 200);
    assert.equal((await r.call('POST', '/v1/messages', msg(OVH))).status, 200);
    const third = await r.call('POST', '/v1/messages', msg(OVH));
    assert.equal(third.status, 429, 'the 2/min OVH limit still applies to real requests');
    assert.equal(third.json.error.type, 'rate_limit_error');
    assert.ok(Number(third.headers['retry-after']) > 0, 'retry-after lets Claude Code back off');
    assert.equal(r.seen.length, 7);
  } finally { r.close(); }
});

test('streamed responses pass through byte for byte; upstream 429 starts a cooldown', async () => {
  const sse = 'event: message_start\ndata: {"type":"message_start"}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n';
  let mode = 'sse';
  const r = await rig('omniroute', {}, (q, s) => {
    if (mode === 'sse') { s.writeHead(200, { 'content-type': 'text/event-stream' }); s.write(sse.slice(0, 20)); setTimeout(() => s.end(sse.slice(20)), 20); }
    else { s.writeHead(429, { 'content-type': 'application/json', 'retry-after': '300' }); s.end('{"type":"error","error":{"type":"rate_limit_error","message":"upstream"}}'); }
  });
  try {
    const x = await r.call('POST', '/v1/messages', msg(OVH, { stream: true }));
    assert.equal(x.status, 200); assert.equal(x.headers['content-type'], 'text/event-stream'); assert.equal(x.text, sse);
    mode = '429'; r.advance(61_000);
    assert.equal((await r.call('POST', '/v1/messages', msg(OVH))).status, 429);
    r.advance(61_000);
    const cd = await r.call('POST', '/v1/messages', msg(OVH));
    assert.equal(cd.status, 429); assert.equal(cd.json.error.code, 'cooldown'); assert.equal(r.seen.length, 2, 'a cooling-down model is not retried upstream');
  } finally { r.close(); }
});

test('the kill switch also stops the Anthropic route', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'fgk-')); const kill = join(dir, 'kill'); writeFileSync(kill, 'x');
  const r = await rig('omniroute', { killFile: kill });
  try {
    const x = await r.call('POST', '/v1/messages', msg(OVH));
    assert.equal(x.status, 503); assert.equal(x.json.type, 'error'); assert.equal(x.json.error.code, 'kill_switch');
    assert.equal(r.seen.length, 0);
  } finally { r.close(); }
});
