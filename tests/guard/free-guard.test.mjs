// node --test tests/guard/free-guard.test.mjs   (loopback mocks only; no network, no credentials)
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createGuard } from '../../tools/free-guard.mjs';
import { loadPolicy, classify } from '../../tools/lib/free-policy.mjs';

const CANARY = 'zz-canary-must-never-be-logged-0123456789';
const policy = loadPolicy();

function listen(server) { return new Promise((r) => server.listen(0, '127.0.0.1', () => r(server.address().port))); }

async function rig(gateway, { upstreamStatus = 200, upstreamHeaders = {}, ...opts } = {}) {
  const seen = [];
  const up = http.createServer((req, res) => {
    let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
      seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body: b });
      res.writeHead(upstreamStatus, { 'content-type': 'application/json', ...upstreamHeaders });
      res.end(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }));
    });
  });
  const upPort = await listen(up);
  let clock = Date.UTC(2026, 9, 30, 12, 0, 0); const logs = [];
  const g = createGuard({ gateway, upstream: `http://127.0.0.1:${upPort}`, policy, now: () => clock, quiet: true, ...opts });
  const origErr = process.stderr.write.bind(process.stderr);
  const port = await listen(g.server);
  const call = (method, path, body, headers = {}) => new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body);
    const r = http.request({ host: '127.0.0.1', port, path, method, headers: { 'content-type': 'application/json', authorization: `Bearer ${CANARY}`, ...headers } }, (res) => {
      let t = ''; res.on('data', (c) => (t += c)); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: t, json: (() => { try { return JSON.parse(t); } catch { return null; } })() }));
    });
    r.on('error', reject); if (data) r.write(data); r.end();
  });
  return { call, seen, advance: (ms) => { clock += ms; }, g, logs, close: async () => { g.server.close(); up.close(); up.closeAllConnections?.(); g.server.closeAllConnections?.(); void origErr; } };
}

const chat = (model, extra = {}) => ({ model, messages: [{ role: 'user', content: 'hi' }], ...extra });

test('allowed free model passes and the auth header is forwarded untouched', async () => {
  const r = await rig('omniroute');
  try {
    const x = await r.call('POST', '/v1/chat/completions', chat('groq/openai/gpt-oss-20b'));
    assert.equal(x.status, 200);
    assert.equal(r.seen.length, 1);
    assert.equal(r.seen[0].auth, `Bearer ${CANARY}`);
  } finally { await r.close(); }
});

test('paid / unverified / ambiguous models never reach the upstream', async () => {
  const r = await rig('omniroute');
  try {
    for (const m of ['auto', 'my-combo', 'openrouter/openai/gpt-4o', 'openrouter/x/y:free:online', 'openrouter/owl-alpha',
      'cf/@cf/moonshotai/kimi-k2.6', 'groq/llama-3.3-70b-versatile', 'openai/gpt-4o', 'anthropic/claude-x', 'gemini/gemini-4-argon']) {
      const x = await r.call('POST', '/v1/chat/completions', chat(m));
      assert.equal(x.status, 403, m);
      assert.equal(x.json.error.free_guard, true, m);
    }
    const none = await r.call('POST', '/v1/chat/completions', { messages: [] });
    assert.equal(none.status, 403);
    assert.equal(r.seen.length, 0, 'nothing may be forwarded for blocked requests');
  } finally { await r.close(); }
});

test('FreeLLMAPI: auto is blocked unless explicitly enabled; paid ids are blocked', async () => {
  let r = await rig('freellmapi');
  try {
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('auto'))).status, 403);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('@cf/moonshotai/kimi-k2.6'))).status, 403);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('openai/gpt-oss-120b'))).status, 200);
  } finally { await r.close(); }
  r = await rig('freellmapi', { allowAuto: true });
  try { assert.equal((await r.call('POST', '/v1/chat/completions', chat('auto'))).status, 200); } finally { await r.close(); }
});

test('fallback / paid-feature body fields and server tools are rejected', async () => {
  const r = await rig('omniroute');
  try {
    for (const extra of [{ models: ['a', 'b'] }, { route: 'fallback' }, { plugins: [{ id: 'web' }] }, { provider: { allow_fallbacks: true } },
      { tools: [{ type: 'web_search' }] }, { tools: [{ type: 'function' }, { type: 'code_interpreter' }] }]) {
      const x = await r.call('POST', '/v1/chat/completions', chat('groq/openai/gpt-oss-20b', extra));
      assert.equal(x.status, 403, JSON.stringify(extra));
    }
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('groq/openai/gpt-oss-20b', { tools: [{ type: 'function', function: { name: 'f' } }] }))).status, 200);
  } finally { await r.close(); }
});

test('only whitelisted routes are served; the rest is blocked locally', async () => {
  const r = await rig('omniroute');
  try {
    for (const [m, p] of [['POST', '/v1/images/generations'], ['POST', '/v1/audio/speech'], ['GET', '/api/settings'], ['DELETE', '/v1/models'], ['POST', '/v1/batches']]) {
      assert.equal((await r.call(m, p, m === 'POST' ? {} : undefined)).status, 403, `${m} ${p}`);
    }
    assert.equal((await r.call('GET', '/v1/models')).status, 200);
    assert.equal(r.seen.length, 1);
  } finally { await r.close(); }
});

test('local rate limit stops hammering: OVH 2/min per model, then recovers', async () => {
  const r = await rig('omniroute');
  try {
    const m = chat('ovh/gpt-oss-20b');
    assert.equal((await r.call('POST', '/v1/chat/completions', m)).status, 200);
    assert.equal((await r.call('POST', '/v1/chat/completions', m)).status, 200);
    const x = await r.call('POST', '/v1/chat/completions', m);
    assert.equal(x.status, 429); assert.equal(x.json.error.type, 'local_rate_limit'); assert.ok(Number(x.headers['retry-after']) >= 1);
    assert.equal(r.seen.length, 2, 'third request must not reach upstream');
    r.advance(61_000);
    assert.equal((await r.call('POST', '/v1/chat/completions', m)).status, 200);
    // a different model has its own bucket
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('ovh/gpt-oss-120b'))).status, 200);
  } finally { await r.close(); }
});

test('upstream 429 starts a cooldown honoured locally (Retry-After), and expires', async () => {
  const r = await rig('omniroute', { upstreamStatus: 429, upstreamHeaders: { 'retry-after': '90' } });
  try {
    const m = chat('groq/openai/gpt-oss-20b');
    assert.equal((await r.call('POST', '/v1/chat/completions', m)).status, 429); // passed through
    const x = await r.call('POST', '/v1/chat/completions', m);
    assert.equal(x.json.error.type, 'cooldown');
    assert.equal(r.seen.length, 1);
    r.advance(91_000);
    assert.equal((await r.call('POST', '/v1/chat/completions', m)).json.error?.type, undefined);
    assert.equal(r.seen.length, 2);
  } finally { await r.close(); }
});

test('self-imposed daily cap blocks locally and resets at 00:00 UTC', async () => {
  const p2 = structuredClone(policy); p2.providers.groq.limits = { rpm: 1000, rpd: 3 };
  const seen = []; const up = http.createServer((q, s) => { q.resume(); q.on('end', () => { seen.push(1); s.writeHead(200); s.end('{}'); }); });
  const upPort = await listen(up); let clock = Date.UTC(2026, 9, 30, 23, 0, 0);
  const g = createGuard({ gateway: 'omniroute', upstream: `http://127.0.0.1:${upPort}`, policy: p2, now: () => clock, quiet: true });
  const port = await listen(g.server);
  const post = () => new Promise((res) => { const r = http.request({ host: '127.0.0.1', port, path: '/v1/chat/completions', method: 'POST' }, (x) => { x.resume(); x.on('end', () => res(x.statusCode)); }); r.end(JSON.stringify(chat('groq/openai/gpt-oss-20b'))); });
  try {
    assert.deepEqual([await post(), await post(), await post(), await post()], [200, 200, 200, 429]);
    clock += 2 * 3600_000;
    assert.equal(await post(), 200);
  } finally { g.server.close(); up.close(); up.closeAllConnections?.(); g.server.closeAllConnections?.(); }
});

test('unreachable gateway returns 502 and nothing else is tried', async () => {
  const g = createGuard({ gateway: 'omniroute', upstream: 'http://127.0.0.1:1', policy, quiet: true });
  const port = await listen(g.server);
  try {
    const code = await new Promise((res) => { const r = http.request({ host: '127.0.0.1', port, path: '/v1/chat/completions', method: 'POST' }, (x) => { x.resume(); res(x.statusCode); }); r.end(JSON.stringify(chat('groq/openai/gpt-oss-20b'))); });
    assert.equal(code, 502);
  } finally { g.server.close(); g.server.closeAllConnections?.(); }
});

test('status endpoint exposes counters but never credentials; upstream must be loopback', async () => {
  const r = await rig('omniroute');
  try {
    await r.call('POST', '/v1/chat/completions', chat('groq/openai/gpt-oss-20b'));
    const s = await r.call('GET', '/__guard/status');
    assert.equal(s.json.requestsToday.groq, 1);
    assert.ok(!s.text.includes(CANARY));
  } finally { await r.close(); }
  assert.throws(() => createGuard({ gateway: 'omniroute', upstream: 'http://example.com:80', policy }), /loopback/);
});

test('policy classify: documented paid-only Cloudflare and non-free OpenRouter models are blocked for both gateways', () => {
  for (const gw of ['freellmapi', 'omniroute']) {
    const pre = gw === 'omniroute' ? 'cf/' : '';
    for (const m of ['@cf/moonshotai/kimi-k2.6', '@cf/zai-org/glm-5.3-flash', '@cf/deepseek-ai/deepseek-v4-pro-0813']) assert.equal(classify(policy, gw, pre + m).ok, false, `${gw} ${m}`);
  }
  assert.equal(classify(policy, 'freellmapi', 'google/gemma-4-31b-it:free').ok, true);
  assert.equal(classify(policy, 'freellmapi', 'openrouter/owl-alpha').ok, false);
});

test('guard log lines never contain the Authorization value', async () => {
  const lines = [];
  const orig = process.stderr.write;
  process.stderr.write = (c) => { lines.push(String(c)); return true; };
  const r = await rig('omniroute', { quiet: false });
  try {
    await r.call('POST', '/v1/chat/completions', chat('groq/openai/gpt-oss-20b'));
    await r.call('POST', '/v1/chat/completions', chat('openai/gpt-4o'));
  } finally { process.stderr.write = orig; await r.close(); }
  assert.ok(lines.length >= 2);
  assert.ok(!lines.join('').includes(CANARY));
});
