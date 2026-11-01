#!/usr/bin/env node
// One genuine chat completion through a free-guard, with a readable result block. Exit 0 only for HTTP 200 + non-empty text + token usage.
// A health check or a mocked reply cannot satisfy this. Retries (politely) on the guard's/OVH's 429 rate limit. Never prints a key.
//   node infer.mjs --name FreeLLMAPI --base http://127.0.0.1:3101/v1 --key-file F --model gpt-oss-20b [--tries 4]
import { readFileSync } from 'node:fs';
const a = process.argv.slice(2);
const opt = (k, d) => { const i = a.indexOf(`--${k}`); return i >= 0 ? a[i + 1] : d; };
const name = opt('name', 'gateway'); const base = opt('base').replace(/\/+$/, ''); const model = opt('model'); const tries = Number(opt('tries', '4'));
const key = readFileSync(opt('key-file'), 'utf8').trim();
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(`${base}/`)) { console.error('infer: --base must be loopback'); process.exit(2); }
let last;
for (let n = 1; n <= tries; n++) {
  let res, j = null;
  try {
    res = await fetch(`${base}/chat/completions`, { method: 'POST', signal: AbortSignal.timeout(120_000),
      headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
      // These are reasoning models: a small max_tokens can be spent entirely on reasoning and return empty text.
      body: JSON.stringify({ model, max_tokens: 300, messages: [{ role: 'user', content: 'Reply with exactly one word: pong' }] }) });
    j = await res.json().catch(() => null);
  } catch (e) { last = { error: `request failed (${e.cause?.code ?? e.name})` }; break; }
  if (res.status === 429 && n < tries) {
    const wait = Math.min(Number(res.headers.get('retry-after')) || 30, 75);
    console.error(`  ${name}: rate-limited (OVH anonymous allows 2 requests/minute/model); waiting ${wait}s (try ${n}/${tries})`);
    await new Promise((r) => setTimeout(r, (wait + 1) * 1000)); continue;
  }
  const text = j?.choices?.[0]?.message?.content ?? '';
  last = { http: res.status, text, usage: j?.usage, cost: j?.usage?.cost ?? j?.cost, model: j?.model, error: j?.error?.message };
  break;
}
const ok = last?.http === 200 && String(last.text).trim() !== '' && last.usage?.total_tokens > 0;
console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
console.log(`  endpoint : ${base}/chat/completions   (free-guard; no paid fallback)`);
console.log(`  model    : ${model}${last?.model && last.model !== model ? ` (answered by ${last.model})` : ''}   provider: OVHcloud AI Endpoints, anonymous tier`);
console.log(`  HTTP     : ${last?.http ?? 'n/a'}${last?.error ? `   error: ${String(last.error).slice(0, 160)}` : ''}`);
console.log(`  response : ${JSON.stringify(String(last?.text ?? '').trim().slice(0, 80))}`);
console.log(`  tokens   : ${last?.usage ? `prompt ${last.usage.prompt_tokens} / completion ${last.usage.completion_tokens} / total ${last.usage.total_tokens}` : 'n/a'}`);
console.log(`  cost     : ${last?.cost != null ? last.cost : 'not reported by the gateway; OVH anonymous tier has no billing path (no key, no account)'}`);
process.exit(ok ? 0 : 1);
