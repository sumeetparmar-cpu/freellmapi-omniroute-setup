// Minimal stand-in for FreeLLMAPI / OmniRoute used by the systemd test. Records every request it receives.
//   node mock-gateway.mjs PORT DIR
// DIR/seen.jsonl      one JSON line per request: method, url, authorization, x-routing headers, body
// DIR/providers.json  served at GET /api/providers (OmniRoute audit)       default {"connections":[]}
// DIR/models.json     served at GET /api/models, PATCHed at /api/models/:id (FreeLLMAPI audit)   default []
import http from 'node:http';
import { appendFileSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const [port, dir] = [Number(process.argv[2]), process.argv[3]];
const read = (f, d) => { try { return JSON.parse(readFileSync(join(dir, f), 'utf8')); } catch { return d; } };

http.createServer((q, s) => {
  let b = ''; q.on('data', (c) => (b += c)); q.on('end', () => {
    appendFileSync(join(dir, 'seen.jsonl'), JSON.stringify({ method: q.method, url: q.url, authorization: q.headers.authorization ?? null,
      routing: Object.keys(q.headers).filter((h) => /^x-(omniroute|freellm)/.test(h)), body: b.slice(0, 500) }) + '\n');
    const json = (o, c = 200) => { s.writeHead(c, { 'content-type': 'application/json' }); s.end(JSON.stringify(o)); };
    if (q.url === '/api/ping' || q.url === '/api/health/ping') return json({ status: 'ok' });
    if (q.url === '/api/providers') return json(read('providers.json', { connections: [] }));
    if (q.url === '/api/provider-nodes') return json({ nodes: [] });
    if (q.url === '/api/keys') return json([]);
    if (q.url === '/api/models') return json(read('models.json', []));
    const m = q.url.match(/^\/api\/models\/(\d+)$/);
    if (q.method === 'PATCH' && m) {
      const models = read('models.json', []); const x = models.find((y) => y.id === Number(m[1]));
      if (x) x.enabled = JSON.parse(b).enabled; writeFileSync(join(dir, 'models.json'), JSON.stringify(models)); return json({ success: true });
    }
    if (q.url === '/v1/models') return json({ data: [{ id: 'auto' }] });
    if (q.url === '/v1/chat/completions') {
      let body = {}; try { body = JSON.parse(b); } catch { /* ignore */ }
      if (body.stream) { s.writeHead(200, { 'content-type': 'text/event-stream' }); const t = setInterval(() => s.write('data: x\n\n'), 40); s.on('close', () => clearInterval(t)); return; }
      return json({ choices: [{ message: { content: 'mock' } }] });
    }
    return json({ error: 'not found' }, 404);
  });
}).listen(port, '127.0.0.1', () => { if (!existsSync(dir)) process.exit(2); });
