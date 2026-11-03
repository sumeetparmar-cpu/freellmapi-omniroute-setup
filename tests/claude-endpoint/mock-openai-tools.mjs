// TEST-ONLY OpenAI-compatible mock with streaming and tool calls. Loopback only, no secrets. (tests/mock-openai-server.mjs is the simpler non-streaming one.)
// node mock-openai-tools.mjs <port> <logfile>
// Behaviour: last message role=tool -> final text "DONE:<tool content>".
//            tools present and user text contains ARGS=<json> -> tool call (first tool's name, that JSON as arguments).
//            otherwise text "OK". stream:true -> SSE chunks (tool args split in two deltas).
import http from 'node:http';
import fs from 'node:fs';
const port = Number(process.argv[2] || 18703);
const logf = process.argv[3] || '/dev/null';
const send = (res, code, body) => { res.writeHead(code, { connection: 'close', 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
const text = (m) => (typeof m?.content === 'string' ? m.content : (m?.content || []).map((p) => p.text || '').join(''));
http.createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => (raw += c));
  req.on('end', () => {
    if (req.url.endsWith('/models')) return send(res, 200, { object: 'list', data: [{ id: 'mock-model', object: 'model' }, { id: 'mock-model-b', object: 'model' }] });
    if (!req.url.endsWith('/chat/completions')) return send(res, 404, { error: { message: 'not found' } });
    let b = {}; try { b = JSON.parse(raw); } catch { /* ignore */ }
    const msgs = b.messages || [];
    const last = msgs[msgs.length - 1] || {};
    const userText = text([...msgs].reverse().find((m) => m.role === 'user'));
    let tool = null; let content = 'OK';
    if (last.role === 'tool') content = 'DONE:' + text(last);
    else if ((b.tools || []).length) {
      const m = /ARGS=(\{.*\})/.exec(userText);
      if (m) tool = { id: 'call_mock1', name: b.tools[0].function?.name || b.tools[0].name, args: m[1] };
    }
    fs.appendFileSync(logf, JSON.stringify({ t: Date.now(), model: b.model, stream: !!b.stream, tools: (b.tools || []).length, auth: !!req.headers.authorization, tool_result_turn: last.role === 'tool' }) + '\n');
    const usage = { prompt_tokens: 7, completion_tokens: 3, total_tokens: 10 };
    if (!b.stream) {
      const message = tool ? { role: 'assistant', content: null, tool_calls: [{ id: tool.id, type: 'function', function: { name: tool.name, arguments: tool.args } }] } : { role: 'assistant', content };
      return send(res, 200, { id: 'mock-1', object: 'chat.completion', model: b.model, choices: [{ index: 0, message, finish_reason: tool ? 'tool_calls' : 'stop' }], usage });
    }
    res.writeHead(200, { connection: 'close', 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    const ch = (delta, fin) => res.write('data: ' + JSON.stringify({ id: 'mock-1', object: 'chat.completion.chunk', model: b.model, choices: [{ index: 0, delta, finish_reason: fin || null }] }) + '\n\n');
    ch({ role: 'assistant', content: '' });
    if (tool) {
      const half = Math.floor(tool.args.length / 2);
      ch({ tool_calls: [{ index: 0, id: tool.id, type: 'function', function: { name: tool.name, arguments: '' } }] });
      ch({ tool_calls: [{ index: 0, function: { arguments: tool.args.slice(0, half) } }] });
      ch({ tool_calls: [{ index: 0, function: { arguments: tool.args.slice(half) } }] });
      ch({}, 'tool_calls');
    } else {
      const mid = Math.max(1, Math.floor(content.length / 2));
      ch({ content: content.slice(0, mid) }); ch({ content: content.slice(mid) }); ch({}, 'stop');
    }
    res.write('data: ' + JSON.stringify({ id: 'mock-1', object: 'chat.completion.chunk', model: b.model, choices: [], usage }) + '\n\n');
    res.write('data: [DONE]\n\n'); res.end();
  });
}).listen(port, '127.0.0.1', () => console.log('mock-rich on', port));
