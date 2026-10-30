// node --test tests/quota/quota-report.test.mjs      (no network beyond loopback mocks, no real credentials)
import test from 'node:test';
import assert from 'node:assert/strict';
import { main, makeClient, ALLOWED_GET_PATHS, LABELS, scrub } from '../../tools/quota-report.mjs';
import { startMock, CANARY } from './mock-gateways.mjs';

const FOUR = new Set(Object.values(LABELS));
const ENV_FL = { FREELLMAPI_KEY: CANARY.unified };
const ENV_OM = { OMNIROUTE_MGMT_TOKEN: CANARY.mgmt };

async function run(gateway, scenario, env, extra = []) {
  const m = await startMock(gateway, scenario);
  try {
    const text = (await main(['--gateway', gateway, '--base-url', `http://127.0.0.1:${m.port}`, ...extra], env)).text;
    const json = JSON.parse((await main(['--gateway', gateway, '--base-url', `http://127.0.0.1:${m.port}`, '--json', ...extra], env)).text);
    return { text, json, requests: m.requests };
  } finally { await m.close(); }
}
const lines = (text, tag) => text.split('\n').filter((l) => l.startsWith(`[${tag}]`));
const noSecrets = (s) => { for (const v of Object.values(CANARY)) assert.ok(!s.includes(v), 'a credential leaked into output'); assert.ok(!/C4N4RY|ST0REDK3Y/.test(s), 'canary fragment leaked'); };

function assertSafety(r, gateway) {
  assert.ok(r.requests.length > 0);
  for (const q of r.requests) {
    assert.equal(q.method, 'GET', 'only GET is allowed');
    assert.ok(ALLOWED_GET_PATHS[gateway].includes(q.path), `non-allowlisted path requested: ${q.path}`);
    assert.ok(!/chat|completions|refresh|sync|probe/i.test(q.path), 'a generation/refresh path was requested');
  }
  for (const item of r.json.items) assert.ok(FOUR.has(item.label), `item has no valid label: ${item.label}`);
  assert.equal(r.json.readOnly, true);
  assert.equal(r.json.modelRequestsSent, 0);
  noSecrets(r.text); noSecrets(JSON.stringify(r.json));
}

// ------------------------------------------------------------------ FreeLLMAPI
test('FreeLLMAPI: success path, correct labels and values', async () => {
  const r = await run('freellmapi', 'ok', ENV_FL);
  assertSafety(r, 'freellmapi');
  assert.match(r.text, /\[GATEWAY\] month \d{4}-\d\d: requests 152, tokens 104,000/);
  assert.match(r.text, /key "phone" on "groq".*10,000 left under that cap.*not provider quota/);
  assert.match(r.text, /key "laptop" on "google" \[disabled\].*no token cap set/);
  const prov = lines(r.text, 'PROVIDER');
  assert.ok(prov.some((l) => /pool groq::account: requests used 600, remaining 400, limit 1,000 \(40% left\); resets/.test(l)));
  assert.ok(prov.some((l) => /groq: 40% of the provider-reported request window/.test(l)));
  assert.ok(lines(r.text, 'UNKNOWN').some((l) => /google::flash: provider reported no remaining\/limit/.test(l)), 'null pool must be unknown');
  assert.ok(lines(r.text, 'UNKNOWN').some((l) => /old::daily: window already reset.*stale/.test(l)), 'expired window must be stale/unknown');
  assert.ok(!r.text.includes('old::daily: requests'), 'stale figures must not be printed as data');
  assert.match(r.text, /ready now 1, exhausted \(all matching keys blocked\) 1, needs a key 1/);
  assert.match(r.text, /ready models \(first 25; use --list-models for all\): groq-llama/);
  assert.match(r.text, /which provider serves each model, and whether each model is free, is not exposed/);
  assert.match(r.text, /No totals are computed across providers/);
  assert.ok(!/rate_per_min|exhaustion/i.test(r.text), 'projections are not reported');
});

test('FreeLLMAPI: provider cooldown and scrubbed health error', async () => {
  const r = await run('freellmapi', 'ok', ENV_FL);
  assert.match(r.text, /Google \[google\]: status rate_limited, enabled keys 1, cooling down until/);
  assert.match(r.text, /last health error: "quota exceeded for key \[redacted\]"/);
});

test('FreeLLMAPI: missing quota data is unknown, never invented', async () => {
  const r = await run('freellmapi', 'missing', ENV_FL);
  assertSafety(r, 'freellmapi');
  assert.ok(lines(r.text, 'UNKNOWN').some((l) => /no provider has reported a quota window yet \(absence does not mean unlimited/.test(l)));
  assert.equal(lines(r.text, 'PROVIDER').filter((l) => /pool /.test(l)).length, 0);
});

test('FreeLLMAPI: authentication errors (wrong key and server-side 401)', async () => {
  const wrong = await run('freellmapi', 'ok', { FREELLMAPI_KEY: 'definitely-wrong-key' });
  assertSafety(wrong, 'freellmapi');
  assert.equal(lines(wrong.text, 'GATEWAY').filter((l) => /requests \d/.test(l)).length, 0);
  assert.ok(lines(wrong.text, 'UNKNOWN').filter((l) => /authentication rejected \(HTTP 401\)/.test(l)).length >= 4);
  assert.ok(lines(wrong.text, 'GATEWAY').some((l) => /liveness probe answered/.test(l)), 'public health still reported');
  const all401 = await run('freellmapi', 'auth', ENV_FL);
  assertSafety(all401, 'freellmapi');
});

test('FreeLLMAPI: no credential supplied -> skipped, names the variable, no request made for it', async () => {
  const r = await run('freellmapi', 'ok', {});
  assert.match(r.text, /no credential supplied \(FREELLMAPI_KEY not set\)/);
  assert.deepEqual([...new Set(r.requests.map((q) => q.path))], ['/api/ping']);
});

test('FreeLLMAPI: rate limit -> unknown with Retry-After, no retries, body never echoed', async () => {
  const r = await run('freellmapi', 'ratelimit', ENV_FL);
  assertSafety(r, 'freellmapi');
  assert.match(r.text, /rate limited by the gateway \(HTTP 429, Retry-After 30\); not retried/);
  assert.equal(r.requests.length / 2, 5, 'exactly one request per endpoint per run (5 endpoints, 2 runs)');
});

test('FreeLLMAPI: malformed JSON and wrong shapes are unknown', async () => {
  for (const sc of ['malformed', 'wrongtypes']) {
    const r = await run('freellmapi', sc, ENV_FL);
    assertSafety(r, 'freellmapi');
    assert.match(r.text, /malformed (JSON in response|response)/);
    assert.equal(lines(r.text, 'PROVIDER').length, 0);
    assert.equal(lines(r.text, 'GATEWAY').filter((l) => /requests \d/.test(l)).length, 0);
  }
});

test('FreeLLMAPI: stale usage ledger is withheld', async () => {
  const r = await run('freellmapi', 'stale', ENV_FL);
  assert.match(r.text, /stale: ledger month 2020-01 ended .*values withheld/);
  assert.ok(!/tokens 99/.test(r.text));
});

test('FreeLLMAPI: redirects are refused, never followed', async () => {
  const r = await run('freellmapi', 'redirect', ENV_FL);
  assert.match(r.text, /redirect refused/);
  assertSafety(r, 'freellmapi');
});

test('FreeLLMAPI: unreachable gateway -> all unknown, no crash', async () => {
  const out = (await main(['--gateway', 'freellmapi', '--base-url', 'http://127.0.0.1:1', '--timeout-ms', '800'], ENV_FL)).text;
  assert.match(out, /network error \/ timeout/);
  assert.equal(lines(out, 'PROVIDER').length + lines(out, 'GATEWAY').length, 0);
  noSecrets(out);
});

test('FreeLLMAPI: --list-models lists every ready model', async () => {
  const r = await run('freellmapi', 'ok', ENV_FL, ['--list-models']);
  assert.match(r.text, /ready models: groq-llama/);
  assert.ok(!r.text.includes('first 25'));
});

// ------------------------------------------------------------------ OmniRoute
test('OmniRoute: success path, provider-reported quota kept apart from estimates', async () => {
  const r = await run('omniroute', 'ok', ENV_OM);
  assertSafety(r, 'omniroute');
  const prov = lines(r.text, 'PROVIDER');
  assert.ok(prov.some((l) => /ollama-cloud "cloud" \/ Monthly: 87.5% remaining, used 12.5, remaining 87.5, of 100; resets \d{4}-/.test(l)));
  assert.ok(prov.some((l) => /Session: reported unlimited/.test(l)));
  const unk = lines(r.text, 'UNKNOWN');
  assert.ok(unk.some((l) => /groq "main": provider returned no quota windows \(message: "no quota API"\)/.test(l)), 'null quotas -> unknown');
  assert.ok(unk.some((l) => /old-provider "stale": stale, last fetched .*figures withheld/.test(l)), 'old cache -> stale');
  assert.ok(unk.some((l) => /connection conn-myster.*provider not identified/.test(l)), 'unmapped connection is not guessed');
  assert.ok(unk.some((l) => /Weekly: window reset time .* in the past/.test(l)), 'past reset -> stale');
  assert.ok(unk.some((l) => /no usable numbers in this quota window/.test(l)), 'negative / non-numeric -> unknown');
  assert.ok(!/remaining 7|used 3/.test(r.text), 'stale window numbers must not appear');
  assert.match(r.text, /breaker for ollama-cloud "cloud": OPEN, failures 4, retry after 30s/);
  assert.match(r.text, /\[GATEWAY\] rolling last 30 days: requests 8, tokens 24 \(prompt 20, completion 4\).*flat-rate estimates.*no reset time applies/);
  assert.match(r.text, /provider "MockLocal": requests 4, tokens 24 over the same 30 days \(a view of the totals above/);
  assert.match(r.text, /calendar-month tokens counted by OmniRoute: 4,200/);
});

test('OmniRoute: estimates are labelled ESTIMATE, deduplicated per pool, and never merged with quota', async () => {
  const r = await run('omniroute', 'ok', ENV_OM);
  const est = lines(r.text, 'ESTIMATE');
  assert.ok(est.some((l) => /catalog-wide documented recurring free allowance: ~1,623,225,000 tokens\/month if EVERY listed provider were connected.*NOT your quota/.test(l)));
  const groq = est.filter((l) => /groq pool "groq"/.test(l));
  assert.equal(groq.length, 1, 'one row per shared pool');
  assert.match(groq[0], /~15,000,000 tokens\/month.*shared by 2 model entries — counted once per pool/);
  assert.ok(!r.text.includes('30,000,000'), 'pool members must not be summed');
  assert.ok(!est.some((l) => /mistral/.test(l)), 'unconnected providers get no per-provider estimate');
  assert.ok(!r.text.includes('1,623,220,800') && !r.text.includes('1623220800'), "upstream 'remaining' (estimate minus usage) must not be shown");
  for (const l of lines(r.text, 'PROVIDER')) assert.ok(!/documented|~\d/.test(l), 'provider lines carry no estimates');
  for (const l of est) assert.ok(!/% remaining/.test(l), 'estimate lines carry no remaining quota');
});

test('OmniRoute: missing quota data is unknown', async () => {
  const r = await run('omniroute', 'missing', ENV_OM);
  assertSafety(r, 'omniroute');
  assert.ok(lines(r.text, 'UNKNOWN').some((l) => /no connection has cached provider-limit data \(.*absence does not mean unlimited/.test(l)));
  assert.equal(lines(r.text, 'PROVIDER').length, 0);
  assert.ok(lines(r.text, 'UNKNOWN').some((l) => /month-to-date usage is withheld by OmniRoute unless a dashboard session authenticates/.test(l)), 'null usedThisMonth -> unknown');
});

test('OmniRoute: stale threshold is adjustable (--max-age-min)', async () => {
  const r = await run('omniroute', 'ok', ENV_OM, ['--max-age-min', '5']);
  assert.ok(lines(r.text, 'UNKNOWN').some((l) => /ollama-cloud "cloud": stale/.test(l)));
  assert.ok(!lines(r.text, 'PROVIDER').some((l) => /Monthly/.test(l)));
});

test('OmniRoute: authentication errors and missing token', async () => {
  const wrong = await run('omniroute', 'ok', { OMNIROUTE_MGMT_TOKEN: 'oma_live_wrong' });
  assertSafety(wrong, 'omniroute');
  assert.ok(lines(wrong.text, 'UNKNOWN').filter((l) => /authentication rejected \(HTTP 401\)/.test(l)).length >= 3);
  assert.equal(lines(wrong.text, 'PROVIDER').length, 0);
  const none = await run('omniroute', 'ok', {});
  assert.match(none.text, /no credential supplied \(OMNIROUTE_MGMT_TOKEN not set\)/);
  assert.ok(lines(none.text, 'GATEWAY').some((l) => /overall status healthy/.test(l)), 'public health still reported');
  assert.ok(none.requests.every((q) => ['/api/health/ping', '/api/monitoring/health'].includes(q.path)));
});

test('OmniRoute: rate limit, malformed and wrong-type responses are unknown', async () => {
  const rl = await run('omniroute', 'ratelimit', ENV_OM);
  assertSafety(rl, 'omniroute');
  assert.match(rl.text, /HTTP 429, Retry-After 30\); not retried/);
  for (const sc of ['malformed', 'wrongtypes']) {
    const r = await run('omniroute', sc, ENV_OM);
    assertSafety(r, 'omniroute');
    assert.equal(lines(r.text, 'PROVIDER').length + lines(r.text, 'ESTIMATE').length, 0);
    assert.match(r.text, /malformed/);
  }
});

test('OmniRoute: model availability is reported unknown (no verified read-only readiness endpoint)', async () => {
  const r = await run('omniroute', 'ok', ENV_OM);
  assert.match(r.text, /no documented read-only endpoint verified for per-model readiness/);
  assert.ok(!r.requests.some((q) => q.path.startsWith('/v1/')));
});

// ------------------------------------------------------------------ client guarantees
test('client refuses non-allowlisted paths (generation, refresh, mutation endpoints)', async () => {
  const c = makeClient({ kind: 'freellmapi', baseUrl: 'http://127.0.0.1:1', secrets: { unified: 'k' } });
  for (const p of ['/v1/chat/completions', '/api/free-tier', '/v1/messages', '/api/backups']) await assert.rejects(() => c.get(p), /non-allowlisted/);
  const o = makeClient({ kind: 'omniroute', baseUrl: 'http://127.0.0.1:1', secrets: { mgmt: 't' } });
  for (const p of ['/v1/chat/completions', '/api/providers/test', '/api/pricing/sync', '/api/keys']) await assert.rejects(() => o.get(p), /non-allowlisted/);
});

test('client rejects non-http base URLs and sends only GET', async () => {
  assert.throws(() => makeClient({ kind: 'freellmapi', baseUrl: 'file:///etc/passwd' }), /http/);
  const seen = [];
  const c = makeClient({ kind: 'freellmapi', baseUrl: 'http://example.test', secrets: { unified: 'k' }, fetchImpl: async (u, init) => { seen.push(init.method); return new Response('{}', { status: 200 }); } });
  await c.get('/v1/usage', { auth: 'unified' });
  assert.deepEqual(seen, ['GET']);
});

test('scrub removes credential-shaped text and explicit secrets', () => {
  const s = scrub(`Bearer abcdefghijklmnop sk-${'a1'.repeat(12)} ${'ab'.repeat(20)} mysecretvalue`, ['mysecretvalue']);
  assert.ok(!/abcdefghijklmnop|a1a1a1|abab|mysecretvalue/.test(s));
});

test('argument validation', async () => {
  await assert.rejects(() => main(['--gateway', 'nope', '--base-url', 'http://x'], {}), /--gateway/);
  await assert.rejects(() => main(['--gateway', 'omniroute'], {}), /--base-url/);
  await assert.rejects(() => main(['--gateway', 'omniroute', '--base-url', 'http://x', '--bogus'], {}), /unknown option/);
  await assert.rejects(() => main(['--gateway', 'omniroute', '--base-url', 'http://x', '--max-age-min', '0'], {}), /max-age-min/);
});
