// node --test tests/guard/free-status.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { evaluate, main } from '../../tools/free-status.mjs';
import { loadPolicy } from '../../tools/lib/free-policy.mjs';

const policy = loadPolicy();
const levels = (r) => Object.fromEntries(r.map(([l, n]) => [n, l]));

test('evaluate: healthy, near-cap, capped, cooldown and kill-switch states', () => {
  const base = { killSwitch: false, cooldownsSec: {}, requestsToday: {} };
  assert.deepEqual(levels(evaluate(base, policy)), { 'kill-switch': 'OK', cooldowns: 'OK' });
  const rpd = policy.providers.groq.limits.rpd;
  assert.equal(levels(evaluate({ ...base, requestsToday: { groq: Math.floor(rpd * 0.5) } }, policy))['quota.groq'], 'OK');
  assert.equal(levels(evaluate({ ...base, requestsToday: { groq: Math.ceil(rpd * 0.85) } }, policy))['quota.groq'], 'WARN');
  assert.match(evaluate({ ...base, requestsToday: { groq: rpd } }, policy).find((r) => r[1] === 'quota.groq')[2], /cap reached/);
  assert.equal(levels(evaluate({ ...base, cooldownsSec: { 'groq:x': 30 } }, policy)).cooldowns, 'WARN');
  assert.equal(levels(evaluate({ ...base, killSwitch: true }, policy))['kill-switch'], 'CRIT');
});

async function mockGuard(doc, code = 200) {
  const s = http.createServer((q, r) => { r.writeHead(code, { 'content-type': 'application/json' }); r.end(JSON.stringify(doc)); });
  await new Promise((r) => s.listen(0, '127.0.0.1', r)); return { s, url: `http://127.0.0.1:${s.address().port}` };
}

test('main: exit codes 0/1/2, TSV output, unreachable guard is CRIT, non-loopback refused', async () => {
  const out = [];
  let g = await mockGuard({ killSwitch: false, cooldownsSec: {}, requestsToday: {} });
  try { assert.equal(await main(['--url', g.url], (s) => out.push(s)), 0); assert.match(out[0], /^OK\tkill-switch\toff$/); } finally { g.s.close(); }
  g = await mockGuard({ killSwitch: false, cooldownsSec: { a: 5 }, requestsToday: {} });
  try { assert.equal(await main(['--url', g.url], () => {}), 1); } finally { g.s.close(); }
  g = await mockGuard({ killSwitch: true, cooldownsSec: {}, requestsToday: {} });
  try { assert.equal(await main(['--url', g.url], () => {}), 2); } finally { g.s.close(); }
  out.length = 0;
  assert.equal(await main(['--url', 'http://127.0.0.1:1'], (s) => out.push(s)), 2); assert.match(out[0], /^CRIT\tguard\tnot answering/);
  out.length = 0;
  assert.equal(await main(['--url', 'http://example.com'], (s) => out.push(s)), 2); assert.match(out[0], /non-loopback/);
});
