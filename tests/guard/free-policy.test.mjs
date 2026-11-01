// node --test tests/guard/free-policy.test.mjs   (loopback mock of the FreeLLMAPI/OmniRoute admin APIs; no credentials)
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { main, auditFreellmapiModels, auditOmnirouteProviders } from '../../tools/free-policy.mjs';
import { loadPolicy } from '../../tools/lib/free-policy.mjs';

const policy = loadPolicy();
const TOKEN = 'zz-admin-token-must-not-print-1234567890abcdef';
const OVH = 'https://oai.endpoints.kepler.ai.cloud.ovh.net/v1';

function adminMock(initialModels, keys = []) {
  const models = structuredClone(initialModels); const calls = [];
  const srv = http.createServer((req, res) => {
    let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
      calls.push(`${req.method} ${req.url}`);
      const j = (o, c = 200) => { res.writeHead(c, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
      if (req.url === '/api/auth/login') return j({ token: TOKEN });
      if (req.headers.authorization !== `Bearer ${TOKEN}`) return j({ error: 'no' }, 401);
      if (req.method === 'GET' && req.url === '/api/models') return j(models);
      if (req.method === 'GET' && req.url === '/api/keys') return j(keys);
      const m = req.url.match(/^\/api\/models\/(\d+)$/);
      if (req.method === 'PATCH' && m) { models.find((x) => x.id === Number(m[1])).enabled = JSON.parse(b).enabled; return j({ success: true }); }
      if (req.method === 'PATCH' && req.url.startsWith('/api/keys/platform/')) { for (const k of keys) if (`/api/keys/platform/${k.platform}` === req.url) k.enabled = false; return j({ success: true }); }
      if (req.method === 'GET' && req.url === '/api/providers') return j({ connections: [{ provider: 'groq' }, { provider: 'openai' }, { provider: 'cohere', isActive: false }] });
      return j({}, 404);
    });
  });
  return new Promise((r) => srv.listen(0, '127.0.0.1', () => r({ srv, models, calls, port: srv.address().port })));
}
const M = (id, platform, modelId, enabled = true, keyId = 1) => ({ id, platform, modelId, enabled, keyId });
const sample = () => [
  M(1, 'groq', 'openai/gpt-oss-20b'), M(2, 'groq', 'llama-3.3-70b-versatile'), M(3, 'cloudflare', '@cf/moonshotai/kimi-k2.6'),
  M(4, 'openrouter', 'openai/gpt-oss-20b:free'), M(5, 'openrouter', 'openrouter/owl-alpha'), M(6, 'cohere', 'command-a-03-2025'),
  M(7, 'custom', 'gpt-oss-20b', true, 9), M(8, 'custom', 'gpt-4o', true, 10), M(9, 'google', 'gemini-2.5-pro', false),
];
const keys = [{ id: 9, platform: 'custom', baseUrl: OVH, enabled: true }, { id: 10, platform: 'custom', baseUrl: 'https://api.example.com/v1', enabled: true }, { id: 11, platform: 'cohere', enabled: true }];

test('audit finds exactly the non-free enabled models; disabled models are ignored', () => {
  const bad = auditFreellmapiModels(policy, sample(), keys).map((v) => v.id).sort();
  assert.deepEqual(bad, [2, 3, 5, 6, 8]);
});

test('custom endpoint passes only for a listed free base URL (OVH keyless) and only for allowed model ids', () => {
  assert.ok(!auditFreellmapiModels(policy, [M(7, 'custom', 'gpt-oss-20b', true, 9)], keys).length);
  assert.ok(auditFreellmapiModels(policy, [M(8, 'custom', 'gpt-4o', true, 9)], keys).length, 'paid model id on the OVH URL is still blocked');
  assert.ok(auditFreellmapiModels(policy, [M(8, 'custom', 'gpt-oss-20b', true, 10)], keys).length, 'unknown base URL is blocked');
});

test('apply disables violations + uncovered platform keys, never enables anything, then reports clean (exit 0)', async () => {
  const mock = await adminMock(sample(), structuredClone(keys)); const out = [];
  try {
    const code = await main(['freellmapi', 'apply', '--base-url', `http://127.0.0.1:${mock.port}`], { FREELLMAPI_ADMIN_TOKEN: TOKEN }, (s) => out.push(s));
    assert.equal(code, 0, out.join('\n'));
    assert.deepEqual(mock.models.filter((m) => m.enabled).map((m) => m.id).sort(), [1, 4, 7]);
    assert.equal(mock.models.find((m) => m.id === 9).enabled, false, 'apply must never enable a model');
    assert.ok(mock.calls.some((c) => c === 'PATCH /api/keys/platform/cohere'));
    assert.ok(!mock.calls.some((c) => c === 'PATCH /api/keys/platform/custom'), 'custom keys are judged per model, not wholesale');
    assert.ok(!out.join('\n').includes(TOKEN));
  } finally { mock.srv.close(); }
});

test('audit exits 1 and writes the kill flag on violations; removes it when clean', async () => {
  const flag = join(mkdtempSync(join(tmpdir(), 'fp-')), 'flag'); const mock = await adminMock(sample(), structuredClone(keys)); const out = (() => {});
  try {
    const a = ['freellmapi', 'audit', '--base-url', `http://127.0.0.1:${mock.port}`, '--flag-file', flag];
    assert.equal(await main(a, { FREELLMAPI_ADMIN_TOKEN: TOKEN }, out), 1);
    assert.ok(existsSync(flag));
    await main(['freellmapi', 'apply', '--base-url', `http://127.0.0.1:${mock.port}`], { FREELLMAPI_ADMIN_TOKEN: TOKEN }, out);
    assert.equal(await main(a, { FREELLMAPI_ADMIN_TOKEN: TOKEN }, out), 0);
    assert.ok(!existsSync(flag), 'flag removed once clean');
  } finally { mock.srv.close(); }
});

test('audit can log in with email+password from the environment and never prints credentials', async () => {
  const mock = await adminMock([M(1, 'groq', 'openai/gpt-oss-20b')], []); const out = [];
  try {
    const code = await main(['freellmapi', 'audit', '--base-url', `http://127.0.0.1:${mock.port}`], { FREELLMAPI_ADMIN_EMAIL: 'a@b.invalid', FREELLMAPI_ADMIN_PASSWORD: 'pw-secret-zzz' }, (s) => out.push(s));
    assert.equal(code, 0); assert.ok(!out.join('').includes('pw-secret-zzz') && !out.join('').includes(TOKEN));
  } finally { mock.srv.close(); }
});

test('no credential or non-loopback URL: refuses (exit 2) without making a request', async () => {
  const out = [];
  assert.equal(await main(['freellmapi', 'audit', '--base-url', 'http://127.0.0.1:1'], {}, (s) => out.push(s)), 2);
  assert.equal(await main(['freellmapi', 'audit', '--base-url', 'http://example.com'], { FREELLMAPI_ADMIN_TOKEN: TOKEN }, (s) => out.push(s)), 2);
  assert.ok(out.some((l) => /loopback/.test(l)));
});

test('omniroute audit flags connected providers outside the policy and cannot apply', async () => {
  const mock = await adminMock([], []); const out = [];
  try {
    const code = await main(['omniroute', 'audit', '--base-url', `http://127.0.0.1:${mock.port}`], { OMNIROUTE_MGMT_TOKEN: TOKEN }, (s) => out.push(s));
    assert.equal(code, 1);
    assert.ok(out.some((l) => l.includes('VIOLATION openai')) && !out.some((l) => l.includes('groq:')));
  } finally { mock.srv.close(); }
  assert.deepEqual(auditOmnirouteProviders(policy, { connections: [{ provider: 'groq' }, { provider: 'openai' }, { provider: 'cohere', isActive: false }] }), [{ provider: 'openai', reason: 'not in the verified-free policy' }]);
  assert.equal(await main(['omniroute', 'apply', '--base-url', 'http://127.0.0.1:1'], { OMNIROUTE_MGMT_TOKEN: TOKEN }, () => {}), 2);
});

test('check command', async () => {
  const out = [];
  assert.equal(await main(['check', 'omniroute', 'groq/openai/gpt-oss-20b'], {}, (s) => out.push(s)), 0);
  assert.equal(await main(['check', 'omniroute', 'openai/gpt-4o'], {}, (s) => out.push(s)), 1);
  assert.match(out[0], /^ALLOW/); assert.match(out[1], /^BLOCK/);
});

test('OmniRoute custom nodes: only the listed prefix pointing at the listed free endpoint passes; anything else is a violation', () => {
  const ok = { id: 'openai-compatible-chat-1', prefix: 'ovhanon', baseUrl: `${OVH}/` };
  assert.deepEqual(auditOmnirouteProviders(policy, { connections: [{ provider: ok.id, isActive: true }] }, { nodes: [ok] }), []);
  const wrongUrl = { ...ok, baseUrl: 'https://api.example.com/v1' };
  assert.equal(auditOmnirouteProviders(policy, { connections: [{ provider: ok.id }] }, { nodes: [wrongUrl] }).length, 1);
  const wrongPrefix = { ...ok, prefix: 'paid' };
  assert.equal(auditOmnirouteProviders(policy, { connections: [] }, { nodes: [wrongPrefix] }).length, 1);
  assert.equal(auditOmnirouteProviders(policy, { connections: [{ provider: 'openai-compatible-chat-zzz' }] }, { nodes: [] }).length, 1);
});

test('classify: OmniRoute ovhanon/<model> follows the OVH allowlist; unknown custom prefixes are blocked', async () => {
  const { classify } = await import('../../tools/lib/free-policy.mjs');
  assert.equal(classify(policy, 'omniroute', 'ovhanon/gpt-oss-20b').ok, true);
  assert.equal(classify(policy, 'omniroute', 'ovhanon/gpt-4o').ok, false);
  assert.equal(classify(policy, 'omniroute', 'ovhanon/Qwen3Guard-Gen-0.6B').ok, false);
  assert.equal(classify(policy, 'omniroute', 'mynode/gpt-oss-20b').ok, false);
});

test('audit --auto-fix disables drift (never enables), clears the kill flag, and plain audit does not modify anything', async () => {
  const flag = join(mkdtempSync(join(tmpdir(), 'fp-')), 'flag'); const mock = await adminMock(sample(), structuredClone(keys)); const out = () => {};
  try {
    const base = ['freellmapi', 'audit', '--base-url', `http://127.0.0.1:${mock.port}`, '--flag-file', flag];
    assert.equal(await main(base, { FREELLMAPI_ADMIN_TOKEN: TOKEN }, out), 1);
    assert.ok(!mock.calls.some((c) => c.startsWith('PATCH')), 'plain audit is read-only');
    assert.equal(await main([...base, '--auto-fix'], { FREELLMAPI_ADMIN_TOKEN: TOKEN }, out), 0);
    assert.deepEqual(mock.models.filter((m) => m.enabled).map((m) => m.id).sort(), [1, 4, 7]);
    assert.ok(!existsSync(flag));
  } finally { mock.srv.close(); }
});
