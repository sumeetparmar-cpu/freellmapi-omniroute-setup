#!/usr/bin/env node
// Does this guarded gateway give a CODING AGENT what it needs? Five real requests (OVH anonymous tier, 2 requests/minute/model, so they are paced):
//   1 streaming (SSE)   2 tool call   3 tool-call round trip (result goes back, answer uses it)   4 structured output (JSON mode)   5 long context (needle in ~12k tokens)
// Prints, per check: PASS/FAIL, HTTP status, which model ANSWERED (the gateway's own report) and token usage. Never prints a key. Loopback only.
//   node agent-compat-check.mjs --name FreeLLMAPI --base http://127.0.0.1:3101/v1 --key-file F --model gpt-oss-20b [--pause 32]
import { readFileSync } from 'node:fs';
const a = process.argv.slice(2);
const opt = (k, d) => { const i = a.indexOf(`--${k}`); return i >= 0 ? a[i + 1] : d; };
const name = opt('name', 'gateway'); const base = String(opt('base')).replace(/\/+$/, ''); const model = opt('model'); const pauseMs = Number(opt('pause', '32')) * 1000;
const key = readFileSync(opt('key-file'), 'utf8').trim();
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(`${base}/`)) { console.error('--base must be loopback'); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let last = 0;
async function call(body, { stream = false } = {}) {
  for (let n = 1; n <= 4; n++) {
    const wait = last + pauseMs - Date.now(); if (wait > 0) await sleep(wait); last = Date.now();   // stay under OVH's 2 requests/minute/model
    let res;
    try { res = await fetch(`${base}/chat/completions`, { method: 'POST', signal: AbortSignal.timeout(150_000), headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` }, body: JSON.stringify({ model, ...body }) }); }
    catch (e) { return { http: 0, error: `request failed (${e.cause?.code ?? e.name})` }; }
    if (res.status === 429 && n < 4) { await sleep((Math.min(Number(res.headers.get('retry-after')) || 30, 75) + 1) * 1000); continue; }
    if (!stream) { const j = await res.json().catch(() => null); return { http: res.status, json: j, hdr: res.headers }; }
    const text = await res.text(); return { http: res.status, sse: text, hdr: res.headers };
  }
}
const ask = (content, extra = {}) => ({ max_tokens: 700, messages: [{ role: 'user', content }], ...extra });
const results = [];
const record = (title, ok, r, extra = '') => {
  const j = r?.json; const usage = j?.usage ? `${j.usage.prompt_tokens}/${j.usage.completion_tokens}/${j.usage.total_tokens}` : 'n/a';
  const via = j?._routed_via ? `${j._routed_via.platform}/${j._routed_via.model}` : (r?.hdr?.get?.('x-omniroute-decision')?.match(/provider=([^;\s]+)/)?.[1] ?? '');
  results.push(ok);
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${title.padEnd(34)} HTTP ${r?.http ?? 'n/a'}  answered-by: ${j?.model ?? model}${via ? ` (via ${via.replace(/openai-compatible-chat-[0-9a-f-]+/, 'custom-node')})` : ''}  tokens(p/c/t): ${usage}${extra ? `  ${extra}` : ''}${r?.error ? `  ${r.error}` : ''}`);
};

console.log(`== ${name}: ${base}  model ${model}  (paced: ~${Math.round(pauseMs / 1000)} s between requests)`);
// 1 streaming
let r = await call(ask('Count from 1 to 5, separated by spaces.', { stream: true }), { stream: true });
const frames = String(r.sse ?? '').split('\n').filter((l) => l.startsWith('data: ') && !l.includes('[DONE]'));
const deltas = frames.filter((l) => { try { const d = JSON.parse(l.slice(6)).choices?.[0]?.delta; return d?.content || d?.reasoning_content || d?.reasoning; } catch { return false; } }).length;
record('streaming (SSE chunks)', r.http === 200 && deltas > 1 && String(r.sse).includes('[DONE]'), r, `chunks=${deltas}`);
// 2 tool call
const tools = [{ type: 'function', function: { name: 'read_file', description: 'Read a text file from disk', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } } }];
r = await call(ask('Use the read_file tool to read /tmp/notes.txt. Do not answer from memory.', { tools, tool_choice: 'auto' }));
const tc = r.json?.choices?.[0]?.message?.tool_calls?.[0];
let args = {}; try { args = JSON.parse(tc?.function?.arguments ?? '{}'); } catch { /* malformed arguments */ }
record('tool call (function calling)', r.http === 200 && tc?.function?.name === 'read_file' && /notes\.txt/.test(args.path ?? ''), r, tc ? `called ${tc.function.name}(${JSON.stringify(args).slice(0, 50)})` : 'no tool call returned');
// 3 tool round trip
const callId = tc?.id ?? 'call_1';
r = await call({ max_tokens: 700, tools, messages: [
  { role: 'user', content: 'Use the read_file tool to read /tmp/notes.txt, then tell me exactly what it says.' },
  { role: 'assistant', content: null, tool_calls: [{ id: callId, type: 'function', function: { name: 'read_file', arguments: '{"path":"/tmp/notes.txt"}' } }] },
  { role: 'tool', tool_call_id: callId, content: 'MAGIC-TOKEN-7431' }] });
record('tool result used in the answer', r.http === 200 && /MAGIC-TOKEN-7431/.test(r.json?.choices?.[0]?.message?.content ?? ''), r);
// 4 structured output
r = await call(ask('Reply with a JSON object with keys "ok" (true) and "n" (the number 3). JSON only.', { response_format: { type: 'json_object' } }));
let parsed = null; try { parsed = JSON.parse(r.json?.choices?.[0]?.message?.content ?? ''); } catch { /* not JSON */ }
record('structured output (JSON mode)', r.http === 200 && parsed?.ok === true && parsed?.n === 3, r);
// 5 long context
const filler = Array.from({ length: 900 }, (_, i) => `Paragraph ${i + 1}: the quick brown fox number ${i * 7} jumps over the lazy dog near the old stone bridge.`).join('\n');
const needle = 'The secret deployment code is ZEBRA-9182.';
const doc = `${filler.slice(0, filler.length / 2)}\n${needle}\n${filler.slice(filler.length / 2)}`;
r = await call(ask(`${doc}\n\nWhat is the secret deployment code? Answer with the code only.`));
record(`long context (~${Math.round(doc.length / 4000)}k tokens)`, r.http === 200 && /ZEBRA-9182/.test(r.json?.choices?.[0]?.message?.content ?? ''), r);
const pass = results.filter(Boolean).length;
console.log(`== ${name}: ${pass}/${results.length} agent-capability checks passed`);
process.exit(pass === results.length ? 0 : 1);
