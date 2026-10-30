// node --test tests/guard/security.test.mjs   Adversarial tests: every case asserts what the UPSTREAM actually received.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGuard, mintClientKey } from '../../tools/free-guard.mjs';
import { loadPolicy } from '../../tools/lib/free-policy.mjs';

const policy = loadPolicy();
const listen = (s) => new Promise((r) => s.listen(0, '127.0.0.1', () => r(s.address().port)));
const CLIENTTOK = ['zz', 'client', 'tok', '4567'].join('-');
const GWTOK = ['zz', 'gw', 'tok', '0123'].join('-');
const GOOD = 'groq/openai/gpt-oss-20b';
const chat = (model, extra = {}) => ({ model, messages: [{ role: 'user', content: 'hi' }], ...extra });

async function rig(gateway = 'omniroute', opts = {}, upstreamImpl) {
  const seen = [];
  const up = http.createServer((q, s) => {
    let b = ''; q.on('data', (c) => (b += c)); q.on('end', () => {
      seen.push({ method: q.method, url: q.url, headers: q.headers, body: b });
      if (upstreamImpl) return upstreamImpl(q, s, b);
      s.writeHead(200, { 'content-type': 'application/json' });
      s.end(q.url === '/v1/models' ? JSON.stringify({ data: [{ id: 'auto' }, { id: 'fusion' }, { id: 'gpt-oss-120b' }] }) : '{"choices":[{"message":{"content":"ok"}}]}');
    });
  });
  const upPort = await listen(up);
  const g = createGuard({ gateway, upstream: `http://127.0.0.1:${upPort}`, policy, quiet: true, ...opts });
  const port = await listen(g.server);
  const call = (method, path, body, headers = {}) => new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body);
    // Explicit framing: Node's client sends GET/DELETE bodies with NO Content-Length/chunking, which desyncs a keep-alive connection (client bug, not the guard's).
    const framing = data === undefined ? {} : { 'content-length': Buffer.byteLength(data) };
    const r = http.request({ host: '127.0.0.1', port, path, method, headers: { 'content-type': 'application/json', ...framing, ...headers } }, (res) => {
      let t = ''; res.on('data', (c) => (t += c)); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: t, json: (() => { try { return JSON.parse(t); } catch { return null; } })() }));
    });
    r.on('error', reject); if (data) r.write(data); r.end();
  });
  // raw TCP for malformed/odd requests
  const raw = (text) => new Promise((resolve) => { const c = net.connect(port, '127.0.0.1', () => c.write(text)); let t = ''; c.on('data', (d) => (t += d)); c.on('close', () => resolve(t)); setTimeout(() => c.destroy(), 800); });
  return { call, raw, seen, g, port, close: async () => { g.server.close(); up.close(); up.closeAllConnections?.(); g.server.closeAllConnections?.(); } };
}

test('inference is impossible without going through the policy: 40 paid/odd model strings never reach upstream', async () => {
  const r = await rig();
  try {
    const bad = ['', 'auto', 'fusion', 'openai/gpt-4o', 'gpt-4o', 'anthropic/claude-3', 'groq/llama-3.3-70b-versatile', 'groq/', 'groq', '/groq/openai/gpt-oss-20b',
      'GROQ/openai/gpt-oss-20b', 'groq/OPENAI/gpt-oss-20b', 'groq/openai/gpt-oss-20b ', ' groq/openai/gpt-oss-20b', 'groq/openai/gpt-oss-20b\n', 'groq/openai/gpt-oss-20b\u0000',
      'groq/openai/gpt-oss-20b,openai/gpt-4o', 'groq/openai/gpt-oss-20b;openai/gpt-4o', 'groq/openai/gpt-oss-20b|x', 'groq/openai/../../gpt-4o', 'groq/%6fpenai/gpt-oss-20b',
      'grоq/openai/gpt-oss-20b' /* cyrillic o */, 'groq/openai/gpt-oss-20b​', 'openrouter/openai/gpt-4o', 'openrouter/x:free:online', 'openrouter/x:free:nitro', 'openrouter/x:floor',
      'openrouter/owl-alpha', 'openrouter/auto', 'openrouter/free', 'cf/@cf/moonshotai/kimi-k2.6', 'cloudflare-ai/@cf/zai-org/glm-5.3', 'cf/@cf/deepseek-ai/deepseek-v4-pro-0813',
      'gemini/gemini-4-argon', 'gemini/gemini-3.1-pro-preview', 'gemini/gemini-2.5-flash-image', 'ovh/Qwen3Guard-Gen-0.6B', 'ovh/stable-diffusion-xl-base-v10',
      'cohere/command-a-03-2025', 'huggingface/x', 'my-combo', 'combo:free-first'];
    for (const m of bad) {
      const x = await r.call('POST', '/v1/chat/completions', chat(m));
      assert.equal(x.status, 403, JSON.stringify(m));
    }
    for (const m of [['x'], { a: 1 }, 7, true, null]) assert.equal((await r.call('POST', '/v1/chat/completions', chat(m))).status, 403, JSON.stringify(m));
    // duplicate "model" keys: JSON.parse takes the last one, exactly like the gateway's parser, and the guard forwards the SAME bytes
    const dup = `{"model":"${GOOD}","model":"openai/gpt-4o","messages":[]}`;
    assert.equal((await r.call('POST', '/v1/chat/completions', dup)).status, 403);
    assert.equal(r.seen.length, 0, 'nothing may reach the gateway');
  } finally { await r.close(); }
});

test('only application/json POST bodies are accepted (no parser differential with the gateway)', async () => {
  const r = await rig();
  try {
    const body = JSON.stringify(chat(GOOD));
    for (const ct of ['text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data; boundary=x', 'application/json-patch+json', '']) {
      const x = await r.call('POST', '/v1/chat/completions', body, { 'content-type': ct });
      assert.equal(x.status, 415, `content-type '${ct}'`);
    }
    assert.equal((await r.call('POST', '/v1/chat/completions', body, { 'content-type': 'application/json; charset=utf-8' })).status, 200);
    assert.equal((await r.call('POST', '/v1/chat/completions', '﻿' + body)).status, 400, 'BOM => invalid JSON, rejected');
    assert.equal((await r.call('POST', '/v1/chat/completions', body, { 'content-encoding': 'gzip' })).status, 200);
    assert.ok(!('content-encoding' in r.seen.at(-1).headers), 'content-encoding is never forwarded');
  } finally { await r.close(); }
});

test('path tricks cannot reach non-whitelisted routes or change what is forwarded', async () => {
  const r = await rig();
  try {
    for (const p of ['/v1/chat/completions/../../api/keys', '/v1/chat%2Fcompletions', '//v1/chat/completions', '/V1/chat/completions', '/v1/chat/completions;x=1',
      '/v1/chat/completions%00', '/v1/./images/generations', '/v1/t/sometoken/chat/completions', '/v1/chat/completions/extra', '/api/chat', '/api/generate', '/api/settings/api-key',
      '/v1/messages', '/v1/responses', '/v1/completions', '/v1beta/models/gemini-2.5-flash:generateContent', '/v1/images/generations', '/v1/audio/transcriptions', '/v1/audio/speech',
      '/v1/moderations', '/v1/files', '/v1/batches', '/v1/fine_tuning/jobs', '/mcp', '/api/keys', '/api/auth/login', '/dashboard', '/']) {
      const x = await r.call('POST', p, chat(GOOD));
      assert.ok([403, 400].includes(x.status), `${p} -> ${x.status}`);
    }
    assert.equal(r.seen.length, 0);
    // query string is dropped, so it cannot smuggle parameters to the gateway
    assert.equal((await r.call('POST', '/v1/chat/completions?model=openai/gpt-4o&stream=true', chat(GOOD))).status, 200);
    assert.equal(r.seen[0].url, '/v1/chat/completions');
    // trailing slash is accepted by the route check
    assert.equal((await r.call('POST', '/v1/chat/completions/', chat(GOOD))).status, 200);
  } finally { await r.close(); }
});

test('only allowlisted headers reach the gateway (routing/pinning/session/cookie/forwarding headers are stripped)', async () => {
  const r = await rig();
  try {
    await r.call('POST', '/v1/chat/completions', chat(GOOD), {
      authorization: `Bearer ${CLIENTTOK}`, 'x-omniroute-connection': 'conn-paid', 'x-omniroute-no-cache': '1', 'x-freellm-cache': 'force', 'x-freellm-compress': 'on',
      'x-session-id': 'abc', cookie: 'auth=stolen', 'x-forwarded-for': '9.9.9.9', 'x-forwarded-host': 'evil', 'x-http-method-override': 'DELETE', 'x-goog-api-key': 'g', 'user-agent': 'ua/1', 'idempotency-key': 'k1',
    });
    const h = r.seen[0].headers;
    for (const bad of ['x-omniroute-connection', 'x-omniroute-no-cache', 'x-freellm-cache', 'x-freellm-compress', 'x-session-id', 'cookie', 'x-forwarded-for', 'x-forwarded-host', 'x-http-method-override', 'x-goog-api-key']) {
      assert.ok(!(bad in h), `${bad} must not be forwarded`);
    }
    assert.equal(h.authorization, `Bearer ${CLIENTTOK}`); assert.equal(h['user-agent'], 'ua/1'); assert.equal(h['idempotency-key'], 'k1');
  } finally { await r.close(); }
});

test('Host header must be a known name (DNS rebinding); extra vhosts only via --allow-host', async () => {
  let r = await rig();
  try {
    assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD), { host: 'evil.example.com' })).status, 421);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD), { host: 'localhost' })).status, 200);
    assert.equal(r.seen.length, 1);
  } finally { await r.close(); }
  r = await rig('omniroute', { allowedHosts: ['llm.example.com'] });
  try { assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD), { host: 'llm.example.com' })).status, 200); } finally { await r.close(); }
});

test('status endpoint is not exposed through a reverse proxy; request smuggling/oversize/malformed are rejected', async () => {
  const r = await rig();
  try {
    assert.equal((await r.call('GET', '/__guard/status')).status, 200);
    for (const h of ['x-forwarded-for', 'forwarded', 'x-real-ip', 'via']) assert.equal((await r.call('GET', '/__guard/status', undefined, { [h]: '1.2.3.4' })).status, 403, h);
    // CL.TE smuggling attempt: both Content-Length and Transfer-Encoding
    const smug = await r.raw(`POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nPOST /v1/images/generations HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n`);
    assert.ok(/400|411|HTTP\/1\.1 4/.test(smug.split('\r\n')[0]) || smug === '', `smuggling attempt got: ${smug.split('\r\n')[0]}`);
    assert.ok(!r.seen.some((s) => s.url.includes('images')), 'smuggled request never reached upstream');
    assert.equal((await r.call('POST', '/v1/chat/completions', 'x'.repeat(2 * 1024 * 1024))).status, 413);
    assert.match((await r.raw('GARBAGE\r\n\r\n')).split('\r\n')[0], /400|^$/);
  } finally { await r.close(); }
});

test('streaming passes through incrementally and counts as exactly one request', async () => {
  const r = await rig('omniroute', {}, (q, s) => { s.writeHead(200, { 'content-type': 'text/event-stream' }); s.write('data: {"a":1}\n\n'); setTimeout(() => { s.write('data: [DONE]\n\n'); s.end(); }, 150); });
  try {
    const chunks = await new Promise((resolve) => {
      const out = []; const rq = http.request({ host: '127.0.0.1', port: r.port, path: '/v1/chat/completions', method: 'POST', headers: { 'content-type': 'application/json' } }, (res) => {
        res.on('data', (c) => out.push({ t: Date.now(), s: String(c) })); res.on('end', () => resolve(out));
      }); rq.end(JSON.stringify(chat(GOOD, { stream: true })));
    });
    assert.ok(chunks.length >= 2 && chunks.at(-1).t - chunks[0].t >= 100, 'chunks arrive over time, not buffered');
    assert.equal((await r.call('GET', '/__guard/status')).json.requestsToday.groq, 1);
  } finally { await r.close(); }
});

test('n>1, extra_body, best_of, tools of any non-function type, and every fallback field are blocked', async () => {
  const r = await rig();
  try {
    for (const extra of [{ n: 2 }, { n: '1' }, { best_of: 3 }, { extra_body: { provider: { order: ['x'] } } }, { provider: {} }, { models: [] }, { route: 'x' }, { fallbacks: [] }, { fallback_models: [] },
      { plugins: [] }, { web_search_options: {} }, { transforms: [] }, { tools: [{ type: 'code_interpreter' }] }, { tools: [{ type: 'web_search_preview' }] }, { tools: [{ type: 'mcp' }] }, { tools: [{}] }]) {
      assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD, extra))).status, 403, JSON.stringify(extra));
    }
    assert.equal(r.seen.length, 0);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD, { n: 1, temperature: 0.2, max_tokens: 5, stream: false, tools: [{ type: 'function', function: { name: 'f' } }] }))).status, 200);
    // multimodal INPUT to a chat model is just a chat request; multimodal/other endpoints are separate routes and stay blocked (see path test)
    assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD, { messages: [{ role: 'user', content: [{ type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } }] }] }))).status, 200);
  } finally { await r.close(); }
});

test('FreeLLMAPI grouped ids: fusion and unserved ids stay blocked even when catalog-audited', async () => {
  const r = await rig('freellmapi', { catalogAudited: true });
  try {
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('fusion'), { authorization: 'Bearer k' })).status, 403);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('gpt-4o'), { authorization: 'Bearer k' })).status, 403);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('gpt-oss-120b'), { authorization: 'Bearer k' })).status, 200);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('auto'), { authorization: 'Bearer k' })).status, 200);
  } finally { await r.close(); }
});

test('client keys: no key / wrong key => 401 before anything is parsed or forwarded; valid key => gateway key swapped in; hashes only on disk', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'fgk-')); const keys = join(dir, 'clients'); const upk = join(dir, 'upstream.key');
  writeFileSync(upk, GWTOK + '\n', { mode: 0o600 });
  const k1 = mintClientKey(keys, 'laptop'); const k2 = mintClientKey(keys, 'n8n');
  const disk = readFileSync(keys, 'utf8');
  assert.ok(!disk.includes(k1) && !disk.includes(k2), 'raw keys are never stored');
  assert.match(disk, /^[0-9a-f]{64} laptop /);
  const r = await rig('omniroute', { clientKeysFile: keys, upstreamKeyFile: upk });
  try {
    for (const h of [{}, { authorization: 'Bearer wrong-wrong-wrong-wrong' }, { authorization: 'Basic abc' }, { authorization: `Bearer ${k1}x` }, { authorization: `bearer ${k1}` }, { authorization: `Bearer ${GWTOK}` }, { 'x-api-key': k1 }]) {
      const x = await r.call('POST', '/v1/chat/completions', chat(GOOD), h);
      assert.equal(x.status, 401, JSON.stringify(h)); assert.equal(x.headers['www-authenticate'], 'Bearer');
    }
    assert.equal((await r.call('GET', '/v1/models')).status, 401);
    assert.equal(r.seen.length, 0);
    for (const k of [k1, k2]) {
      const x = await r.call('POST', '/v1/chat/completions', chat(GOOD), { authorization: `Bearer ${k}` });
      assert.equal(x.status, 200); assert.ok(!x.text.includes(GWTOK));
      const h = r.seen.at(-1).headers; assert.equal(h.authorization, `Bearer ${GWTOK}`); assert.ok(!('x-api-key' in h));
    }
    assert.ok(!JSON.stringify((await r.call('GET', '/__guard/status')).json).includes(GWTOK));
  } finally { await r.close(); }
  assert.throws(() => createGuard({ gateway: 'omniroute', upstream: 'http://127.0.0.1:1', policy, clientKeysFile: keys }), /together/);
});

test('in-flight cap protects the free tier and the box (503), and slots are released', async () => {
  let release; const gate = new Promise((r) => (release = r));
  const r = await rig('omniroute', { maxInflight: 2 }, async (q, s) => { await gate; s.writeHead(200, { 'content-type': 'application/json' }); s.end('{}'); });
  try {
    const p1 = r.call('POST', '/v1/chat/completions', chat('ovh/gpt-oss-20b')); const p2 = r.call('POST', '/v1/chat/completions', chat('ovh/gpt-oss-120b'));
    await new Promise((x) => setTimeout(x, 100));
    const busy = await r.call('POST', '/v1/chat/completions', chat('mistral/mistral-small-latest'));
    assert.equal(busy.status, 503);
    release(); await Promise.all([p1, p2]);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat('mistral/mistral-small-latest'))).status, 200);
  } finally { await r.close(); }
});

test('quota cannot be reset by restarts, crashes or clients: write-through state, windows persisted, clients cannot influence the clock', async () => {
  const stateFile = join(mkdtempSync(join(tmpdir(), 'fgs-')), 'state.json');
  const p2 = structuredClone(policy); p2.providers.groq.limits = { rpm: 2, rpd: 3 };
  const clock = Date.UTC(2026, 9, 30, 12, 0, 0);
  const mk = async () => { const up = http.createServer((q, s) => { q.resume(); q.on('end', () => { s.writeHead(200); s.end('{}'); }); }); const upPort = await listen(up);
    const g = createGuard({ gateway: 'omniroute', upstream: `http://127.0.0.1:${upPort}`, policy: p2, now: () => clock, quiet: true, stateFile }); const port = await listen(g.server);
    return { up, g, port, post: (hdr = {}) => new Promise((res) => { const rq = http.request({ host: '127.0.0.1', port, path: '/v1/chat/completions', method: 'POST', headers: { 'content-type': 'application/json', ...hdr } }, (x) => { x.resume(); x.on('end', () => res(x.statusCode)); }); rq.end(JSON.stringify(chat(GOOD))); }) }; };
  let a = await mk();
  assert.deepEqual([await a.post(), await a.post()], [200, 200]);
  // "crash": no close(), no persist() call. A second process must still see the usage (write-through).
  const b = await mk();
  assert.equal(await b.post(), 429, 'per-minute window survived the crash/restart');
  assert.equal(JSON.parse(readFileSync(stateFile, 'utf8')).counts.groq, 2);
  // a client cannot roll the day or the window by sending date/forwarding headers
  assert.equal(await b.post({ date: 'Mon, 01 Jan 2035 00:00:00 GMT', 'x-forwarded-for': '1.1.1.1', 'cache-control': 'no-cache', 'x-request-id': 'new' }), 429);
  for (const x of [a, b]) { x.g.server.close(); x.up.close(); x.up.closeAllConnections?.(); x.g.server.closeAllConnections?.(); }
});

test('graceful shutdown: SIGTERM with a never-ending stream open exits within the drain window and keeps the counters', async () => {
  const { spawn } = await import('node:child_process');
  const up = http.createServer((q, s) => { q.resume(); q.on('end', () => { s.writeHead(200); const t = setInterval(() => s.write('x'), 30); s.on('close', () => clearInterval(t)); }); });
  const upPort = await listen(up); const stateFile = join(mkdtempSync(join(tmpdir(), 'fgt-')), 's.json');
  const gp = 39000 + Math.floor(Math.random() * 900);
  const child = spawn(process.execPath, [new URL('../../tools/free-guard.mjs', import.meta.url).pathname, '--gateway', 'omniroute', '--upstream', `http://127.0.0.1:${upPort}`, '--listen', `127.0.0.1:${gp}`, '--state', stateFile], { stdio: 'ignore', env: { ...process.env, GUARD_DRAIN_MS: '600' } });
  try {
    await new Promise((r) => setTimeout(r, 800));
    const rq = http.request({ host: '127.0.0.1', port: gp, path: '/v1/chat/completions', method: 'POST', headers: { 'content-type': 'application/json' } }, (res) => res.on('data', () => {}));
    rq.on('error', () => {}); rq.end(JSON.stringify(chat(GOOD)));
    await new Promise((r) => setTimeout(r, 300));
    const t0 = Date.now(); child.kill('SIGTERM');
    const code = await Promise.race([new Promise((r) => child.on('exit', (c) => r(c))), new Promise((r) => setTimeout(() => r('hung'), 4000))]);
    assert.equal(code, 0, 'guard must exit cleanly, not hang');
    assert.ok(Date.now() - t0 < 3000, `exited in ${Date.now() - t0} ms`);
    assert.equal(JSON.parse(readFileSync(stateFile, 'utf8')).counts.groq, 1);
  } finally { child.kill('SIGKILL'); up.close(); up.closeAllConnections?.(); }
});

test('the guard log is size-capped (one rotated generation) and never contains credentials', async () => {
  const { existsSync, statSync } = await import('node:fs');
  const dir = mkdtempSync(join(tmpdir(), 'fgl-')); const logFile = join(dir, 'g.log');
  const r = await rig('omniroute', { logFile, logMaxBytes: 2000, quiet: true });
  try {
    for (let i = 0; i < 60; i++) await r.call('POST', '/v1/chat/completions', chat('openai/gpt-4o'), { authorization: `Bearer ${CLIENTTOK}` });
    assert.ok(existsSync(`${logFile}.1`), 'rotated');
    assert.ok(statSync(logFile).size <= 2000 && statSync(`${logFile}.1`).size <= 2000);
    assert.ok(!readFileSync(logFile, 'utf8').includes(CLIENTTOK) && !readFileSync(`${logFile}.1`, 'utf8').includes(CLIENTTOK));
  } finally { await r.close(); }
});

test('REGRESSION: JSON bodies that are not objects (null, [], 5, "x", true) are 400s and cannot crash the guard', async () => {
  const r = await rig();
  try {
    for (const b of ['null', '[]', '5', '"x"', 'true', '[{"model":"' + GOOD + '"}]']) assert.equal((await r.call('POST', '/v1/chat/completions', b)).status, 400, b);
    assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD))).status, 200, 'still serving');
    assert.equal(r.seen.length, 1);
  } finally { await r.close(); }
});

test('a hand-edited / garbage state file cannot break serving', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'fgx-'));
  for (const junk of ['{"counts":"x","cooldowns":[],"windows":5,"day":7,"passed":"a"}', '{"counts":{"groq":"many"},"cooldowns":{"groq:x":{"until":"never"}},"windows":{"k":"nope"}}', 'null', '[]', '']) {
    const stateFile = join(dir, 's.json'); writeFileSync(stateFile, junk);
    const r = await rig('omniroute', { stateFile });
    try { assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD))).status, 200, junk); assert.equal((await r.call('GET', '/__guard/status')).status, 200); } finally { await r.close(); }
  }
});

test('FUZZ: 400 random hostile requests => guard stays up, every response is sane, and nothing non-compliant reaches the gateway', async () => {
  const { classify } = await import('../../tools/lib/free-policy.mjs');
  let seed = 0x5eed1234; const rnd = () => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 2 ** 32);
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const models = [GOOD, 'ovhanon/gpt-oss-20b', 'ovh/gpt-oss-120b', 'mistral/mistral-small-latest', 'openai/gpt-4o', 'auto', '', 'groq/llama-3.3-70b-versatile', 'cf/@cf/zai-org/glm-5.3', 'openrouter/x:free', 'openrouter/x:free:online', ' ' + GOOD, GOOD + '\n', 7, null, ['a'], {}, true];
  const scalar = () => pick([null, true, false, 0, 1, -1, 1e308, '', 'x'.repeat(1 + Math.floor(rnd() * 50)), '\u0000', '😀', [], {}]);
  const value = (d = 0) => (d > 3 || rnd() < 0.4 ? scalar() : rnd() < 0.5 ? Array.from({ length: Math.floor(rnd() * 4) }, () => value(d + 1)) : Object.fromEntries(Array.from({ length: Math.floor(rnd() * 4) }, () => [pick(['model', 'messages', 'n', 'tools', 'models', 'stream', 'x', '__proto__', 'constructor']), value(d + 1)])));
  const paths = ['/v1/chat/completions', '/v1/chat/completions', '/v1/chat/completions', '/v1/embeddings', '/v1/models', '/v1/images/generations', '//v1/chat/completions', '/v1/chat/completions/', '/%2e%2e/v1/chat/completions', '/api/keys', '/__guard/status', '/', '/v1/chat/completions?model=gpt-4o', '/v1/chat/completions#x'];
  const cts = ['application/json', 'application/json', 'application/json; charset=utf-8', 'text/plain', '', 'application/x-www-form-urlencoded', 'APPLICATION/JSON'];
  const r = await rig('omniroute', { noRateLimit: true, maxInflight: 64 });
  const bad = [];
  try {
    for (let i = 0; i < 400; i++) {
      const body = rnd() < 0.55 ? chat(pick(models), rnd() < 0.5 ? Object.fromEntries([[pick(['n', 'tools', 'models', 'stream', 'extra_body', 'x']), value()]]) : {})
        : rnd() < 0.8 ? value() : pick(['', '{', '{"model":', 'null', '\u0000\u0001', 'x'.repeat(3000)]);
      const raw = typeof body === 'string' ? body : JSON.stringify(body);
      const x = await r.call(pick(['POST', 'POST', 'POST', 'GET', 'PUT', 'DELETE', 'PATCH']), pick(paths), raw, { 'content-type': pick(cts), ...(rnd() < 0.2 ? { 'x-omniroute-connection': 'c', cookie: 'a=b' } : {}) }).catch((e) => ({ status: `ERR ${e.code}` }));
      if (typeof x.status !== 'number' || x.status < 200 || x.status > 599) bad.push([i, x.status, raw.slice(0, 80)]);
    }
    assert.deepEqual(bad, [], 'every response must be a real HTTP status (no resets/crashes)');
    assert.equal((await r.call('GET', '/__guard/status')).status, 200, 'guard still alive');
    // THE invariant: whatever reached the gateway is policy-compliant and came through an allowed route
    for (const s of r.seen) {
      assert.ok((s.method === 'GET' && s.url === '/v1/models') || (s.method === 'POST' && ['/v1/chat/completions', '/v1/embeddings'].includes(s.url)), `route reached gateway: ${s.method} ${s.url}`);
      if (s.method === 'POST') {
        const b = JSON.parse(s.body); assert.equal(classify(policy, 'omniroute', b.model).ok, true, `non-compliant model reached the gateway: ${JSON.stringify(b.model)}`);
        for (const f of policy.forbiddenBodyFields) assert.ok(!(f in b), `forbidden field ${f} reached the gateway`);
        assert.ok(b.n === undefined || b.n === 1);
      }
      assert.ok(!Object.keys(s.headers).some((h) => /^x-(omniroute|freellm)/.test(h)) && !('cookie' in s.headers), 'routing/cookie header reached the gateway');
    }
    assert.ok(r.seen.length >= 5, 'generator sanity: the fuzz must also let some legitimate traffic through (' + r.seen.length + ')');
  } finally { await r.close(); }
});

// ---- review round 5 ----
test('Content-Type charset other than utf-8 is refused (the guard always decodes UTF-8; a different charset is a parser mismatch)', async () => {
  const r = await rig();
  try {
    for (const ct of ['application/json; charset=utf-16', 'application/json;charset=utf-7', 'application/json; charset=latin1', 'application/json; boundary=x', 'application/json; charset=utf-8; charset=utf-7']) {
      const x = await r.call('POST', '/v1/chat/completions', chat(GOOD), { 'content-type': ct });
      assert.equal(x.status, 415, ct);
    }
    for (const ct of ['application/json', 'application/json; charset=utf-8', 'Application/JSON;charset=UTF-8', 'application/json;charset="utf-8"']) {
      const x = await r.call('POST', '/v1/chat/completions', chat(GOOD), { 'content-type': ct });
      assert.equal(x.status, 200, ct);
    }
    assert.equal(r.seen.length, 4, 'only the four utf-8 requests reached the upstream');
  } finally { await r.close(); }
});

test('service_tier: only auto/default/on_demand pass (flex/performance are paid-plan tiers); nothing else about the request changes', async () => {
  const r = await rig();
  try {
    for (const t of ['flex', 'performance', 'priority', 'scale', 7, null, ['auto']]) {
      const x = await r.call('POST', '/v1/chat/completions', chat(GOOD, { service_tier: t }));
      assert.equal(x.status, 403, JSON.stringify(t));
    }
    for (const t of ['auto', 'default', 'on_demand']) assert.equal((await r.call('POST', '/v1/chat/completions', chat(GOOD, { service_tier: t }))).status, 200, t);
    assert.equal(r.seen.length, 3);
  } finally { await r.close(); }
});

test('catalog-audited: unknown models cannot grow memory or hammer the gateway (bounded cache, failures are cached briefly)', async () => {
  let modelCalls = 0;
  const r = await rig('freellmapi', { catalogAudited: true }, (q, s) => {
    if (q.url === '/v1/models') { modelCalls++; s.writeHead(500); return s.end('{}'); }
    s.writeHead(200, { 'content-type': 'application/json' }); s.end('{}');
  });
  try {
    for (let i = 0; i < 40; i++) {
      const x = await r.call('POST', '/v1/chat/completions', chat('not-a-real-model'), { authorization: `Bearer attacker-${i}-aaaaaaaaaaaaaaaa` });
      assert.equal(x.status, 403);
    }
    assert.ok(modelCalls <= 3, `gateway /v1/models was called ${modelCalls} times for 40 refused requests`);
  } finally { await r.close(); }
});

test('refused model strings are truncated in the log', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'fg-log-')); const logFile = join(dir, 'g.log');
  const r = await rig('omniroute', { logFile, quiet: false });
  try {
    await r.call('POST', '/v1/chat/completions', chat('a'.repeat(50_000)));
    const line = readFileSync(logFile, 'utf8').trim().split('\n').pop();
    assert.ok(line.length < 1000, `log line is ${line.length} bytes`);
  } finally { await r.close(); }
});
