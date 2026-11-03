// Anthropic /v1/messages checks (the endpoint Claude Code uses) against a gateway whose upstream is the local MOCK
// (mock-openai-tools.mjs). Mock-only: this proves the gateway's Anthropic translation layer, NOT any real provider.
//   GWKEY=<client key> node anthropic-check.mjs <baseUrl> <pinned-model-id> [prefix=/v1]
// Key comes from env GWKEY and is never printed. Optional env MAIN_MODEL / HAIKU_MODEL override the Claude names sent
// (default claude-sonnet-4-5 / claude-3-5-haiku-20241022). Exit code is 1 if any check fails.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path';
const [base, pinned, prefix = '/v1'] = process.argv.slice(2);
const key = process.env.GWKEY || ''; const MAIN = process.env.MAIN_MODEL || 'claude-sonnet-4-5'; const HAIKU = process.env.HAIKU_MODEL || 'claude-3-5-haiku-20241022';
const H = (style) => ({ 'content-type': 'application/json', 'anthropic-version': '2023-06-01', ...(style === 'x-api-key' ? { 'x-api-key': key } : style === 'bearer' ? { authorization: 'Bearer ' + key } : {}) });
const post = (p, body, style = 'x-api-key') => fetch(base + prefix + p, { method: 'POST', headers: H(style), body: JSON.stringify(body) });
let pass = 0, fail = 0;
const ck = (name, ok, detail = '') => { ok ? pass++ : fail++; console.log((ok ? 'PASS' : 'FAIL') + ' - ' + name + (detail ? '  [' + detail + ']' : '')); };
async function sse(res) {
  const events = []; const txt = await res.text(); let ev = null;
  for (const line of txt.split('\n')) { if (line.startsWith('event:')) ev = line.slice(6).trim(); else if (line.startsWith('data:')) { try { events.push({ ev, d: JSON.parse(line.slice(5)) }); } catch { /* ignore */ } } }
  return events;
}
const tool = { name: 'edit_file', description: 'replace text in a file', input_schema: { type: 'object', properties: { file_path: { type: 'string' }, old: { type: 'string' }, new: { type: 'string' } }, required: ['file_path', 'old', 'new'] } };
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'edit-')); const target = path.join(tmp, 'hello.txt'); fs.writeFileSync(target, 'hello world\n');
const args = JSON.stringify({ file_path: target, old: 'world', new: 'sandbox' });

// auth
let r = await post('/messages', { model: MAIN, max_tokens: 16, messages: [{ role: 'user', content: 'hi' }] }, 'none');
ck('anonymous /v1/messages rejected', r.status === 401 || r.status === 403, 'HTTP ' + r.status);
r = await post('/messages', { model: MAIN, max_tokens: 16, messages: [{ role: 'user', content: 'hi' }] }, 'x-api-key');
let j = r.ok ? await r.json() : null;
ck('x-api-key accepted, non-stream message (claude-sonnet-4-5)', r.status === 200 && j?.type === 'message' && j?.content?.[0]?.text === 'OK', 'HTTP ' + r.status + (j ? ' text=' + JSON.stringify(j.content?.[0]?.text) + ' stop=' + j.stop_reason : ''));
r = await post('/messages', { model: MAIN, max_tokens: 16, messages: [{ role: 'user', content: 'hi' }] }, 'bearer');
ck('Bearer token accepted', r.status === 200, 'HTTP ' + r.status);
// streaming
r = await post('/messages', { model: MAIN, max_tokens: 16, stream: true, messages: [{ role: 'user', content: 'hi' }] });
const ev = r.ok ? await sse(r) : [];
const names = ev.map((e) => e.ev || e.d?.type);
const streamText = ev.filter((e) => e.d?.type === 'content_block_delta').map((e) => e.d.delta?.text || '').join('');
ck('streaming: SSE event sequence', r.status === 200 && names[0] === 'message_start' && names.includes('content_block_delta') && names.includes('message_stop'), 'HTTP ' + r.status + ' events=' + [...new Set(names)].join(','));
ck('streaming: reassembled text', streamText === 'OK', JSON.stringify(streamText));
// tool call non-stream
const userTurn = { role: 'user', content: 'edit please ARGS=' + args };
r = await post('/messages', { model: MAIN, max_tokens: 64, tools: [tool], messages: [userTurn] });
j = r.ok ? await r.json() : null; const tu = j?.content?.find((c) => c.type === 'tool_use');
ck('tool call: tool_use block, stop_reason tool_use', r.status === 200 && !!tu && tu.name === 'edit_file' && j.stop_reason === 'tool_use' && tu.input?.file_path === target, 'HTTP ' + r.status + (tu ? ' name=' + tu.name : ''));
// tool call stream
r = await post('/messages', { model: MAIN, max_tokens: 64, stream: true, tools: [tool], messages: [userTurn] });
const ev2 = r.ok ? await sse(r) : [];
const start = ev2.find((e) => e.d?.type === 'content_block_start' && e.d.content_block?.type === 'tool_use');
const partial = ev2.filter((e) => e.d?.delta?.type === 'input_json_delta').map((e) => e.d.delta.partial_json).join('');
let parsed = null; try { parsed = JSON.parse(partial); } catch { /* ignore */ }
const sr = ev2.find((e) => e.d?.type === 'message_delta')?.d?.delta?.stop_reason;
ck('tool call (stream): tool_use start + input_json_delta reassembles to valid JSON', !!start && parsed?.new === 'sandbox' && sr === 'tool_use', 'start=' + !!start + ' json_ok=' + !!parsed + ' stop=' + sr);
// file edit round trip: client applies tool_use, returns tool_result
if (tu) {
  const input = tu.input; const before = fs.readFileSync(input.file_path, 'utf8');
  fs.writeFileSync(input.file_path, before.replace(input.old, input.new));
  r = await post('/messages', { model: MAIN, max_tokens: 64, tools: [tool], messages: [userTurn, { role: 'assistant', content: j.content }, { role: 'user', content: [{ type: 'tool_result', tool_use_id: tu.id, content: 'edited' }] }] });
  const j2 = r.ok ? await r.json() : null;
  ck('file edit round trip: tool_result accepted, final text returned', r.status === 200 && /DONE:edited/.test(j2?.content?.[0]?.text || ''), 'HTTP ' + r.status + (j2 ? ' text=' + JSON.stringify(j2.content?.[0]?.text) : ''));
}
ck('file actually edited on disk by the client from the gateway tool_use', fs.readFileSync(target, 'utf8') === 'hello sandbox\n', JSON.stringify(fs.readFileSync(target, 'utf8')));
// routing
r = await post('/messages', { model: pinned, max_tokens: 16, messages: [{ role: 'user', content: 'hi' }] });
ck('pinned non-Claude model id accepted', r.status === 200, 'HTTP ' + r.status + ' model=' + pinned);
r = await post('/messages', { model: HAIKU, max_tokens: 16, messages: [{ role: 'user', content: 'hi' }] });
ck('haiku-family name accepted', r.status === 200, 'HTTP ' + r.status);
r = await post('/messages/count_tokens', { model: MAIN, messages: [{ role: 'user', content: 'hello there' }] });
j = r.ok ? await r.json() : null;
ck('count_tokens returns input_tokens', r.status === 200 && Number.isFinite(j?.input_tokens), 'HTTP ' + r.status + (j ? ' input_tokens=' + j.input_tokens : ''));
console.log(`SUMMARY pass=${pass} fail=${fail}`);
process.exit(fail ? 1 : 0);
