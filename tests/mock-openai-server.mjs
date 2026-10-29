// Minimal OpenAI-compatible mock used by the toolkit tests. No network, no secrets.
//   node tests/mock-openai-server.mjs <port> [mode]    mode: ok | quota (429) | empty | auth
// With mode "auth" every request needs "Authorization: Bearer mock-key".
import http from 'node:http';
const port = Number(process.argv[2] || 18080);
const mode = process.argv[3] || 'ok';
const json = (res, code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    if (mode === 'auth' && req.headers.authorization !== 'Bearer mock-key') return json(res, 401, { error: { message: 'bad key' } });
    if (req.url.endsWith('/models')) return json(res, 200, { object: 'list', data: [{ id: 'mock-model', object: 'model' }] });
    if (req.url.endsWith('/chat/completions')) {
      if (mode === 'quota') return json(res, 429, { error: { message: 'quota exhausted' } });
      if (mode === 'empty') return json(res, 200, { choices: [] });
      let model = 'mock-model';
      try { model = JSON.parse(body).model || model; } catch { /* ignore */ }
      return json(res, 200, { id: 'mock-1', object: 'chat.completion', model,
        choices: [{ index: 0, message: { role: 'assistant', content: 'OK' }, finish_reason: 'stop' }],
        usage: { prompt_tokens: 5, completion_tokens: 1, total_tokens: 6 } });
    }
    json(res, 404, { error: { message: 'not found' } });
  });
}).listen(port, '127.0.0.1', () => console.log(`mock listening on ${port} mode=${mode}`));
