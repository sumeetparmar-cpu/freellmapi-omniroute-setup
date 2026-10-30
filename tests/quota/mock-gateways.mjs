// Mock FreeLLMAPI / OmniRoute read-only status endpoints for tests. No network beyond loopback, no real data.
//   node tests/quota/mock-gateways.mjs <freellmapi|omniroute> <scenario> [port]
// scenarios: ok | missing | auth | ratelimit | malformed | stale | redirect
import http from 'node:http';
import { fileURLToPath } from 'node:url';

// Credentials the tests hand to the reporter. Assembled at runtime so no secret-shaped literal sits in the repo.
export const CANARY = {
  unified: ['free', 'llmapi-', 'C4N4RY'.repeat(4)].join(''),
  mgmt: ['oma', '_live_', 'C4N4RY'.repeat(4)].join(''),
  stored: ['sk', '-', 'ST0REDK3Y'.repeat(3)].join(''), // appears inside mock payloads; must never be echoed
};
const iso = (offsetMs) => new Date(Date.now() + offsetMs).toISOString();
const H = 3600e3;

function freellmapi(path, scenario) {
  switch (path) {
    case '/api/ping': return { status: 'ok' };
    case '/v1/usage': return scenario === 'stale'
      ? { month: '2020-01', resetsAt: '2020-02-01T00:00:00.000Z', requests: 9, tokens: 99, byPlatform: [], byKey: [] }
      : { object: 'usage', month: iso(0).slice(0, 7), resetsAt: iso(5 * 24 * H), requests: 152, tokens: 104000, byPlatform: [{ platform: 'groq', requests: 100, tokens: 90000 }, { platform: 'google', requests: 52, tokens: 14000 }],
          byKey: [{ keyId: 1, platform: 'groq', label: 'phone', enabled: true, requests: 100, tokens: 90000, requestCap: null, tokenCap: 100000 }, { keyId: 2, platform: 'google', label: 'laptop', enabled: false, requests: 52, tokens: 14000, requestCap: null, tokenCap: null }] };
    case '/v1/providers': return { providers: [{ platform: 'groq', name: 'Groq', status: 'healthy', keys: 1, requests_remaining_pct: 40 }, { platform: 'google', name: 'Google', status: 'rate_limited', keys: 1, resume_at: iso(H), last_error: `quota exceeded for key ${CANARY.stored}` }], counts: { healthy: 1, rate_limited: 1, invalid: 0, unknown: 0 } };
    case '/v1/quota-forecast': return scenario === 'missing' ? { generated_at: iso(0), pools: [] }
      : { generated_at: iso(0), pools: [
          { platform: 'groq', pool: 'groq::account', used: 600, remaining: 400, limit: 1000, remaining_pct: 40, reset_at: iso(3 * H), seconds_until_reset: 10800, low_balance: false, rate_per_min: 1.5, estimated_exhaustion_at: iso(H) },
          { platform: 'google', pool: 'google::flash', used: null, remaining: null, limit: null, remaining_pct: null, reset_at: null, low_balance: false },
          { platform: 'old', pool: 'old::daily', used: 5, remaining: 5, limit: 10, remaining_pct: 50, reset_at: '2020-01-01T00:00:00Z', low_balance: false }] };
    case '/v1/models': return { object: 'list', data: [
      { id: 'auto', owned_by: 'freellmapi', available: true }, { id: 'groq-llama', owned_by: 'freellmapi', available: true, execution_status: 'ready' },
      { id: 'google-flash', owned_by: 'freellmapi', available: true, execution_status: 'exhausted' }, { id: 'nokey-model', owned_by: 'freellmapi', available: false, execution_status: 'needsKey' }] };
  }
  return undefined;
}

function omniroute(path, scenario) {
  const conns = [{ id: 'conn-groq-1', provider: 'groq', name: 'main', isActive: true, testStatus: 'active', apiKey: CANARY.stored, providerSpecificData: { token: CANARY.stored } },
                 { id: 'conn-ollama-1', provider: 'ollama-cloud', name: 'cloud', isActive: true, testStatus: 'active', apiKey: CANARY.stored },
                 { id: 'conn-old-1', provider: 'old-provider', name: 'stale', isActive: false, testStatus: 'error' }];
  switch (path) {
    case '/api/health/ping': return { status: 'ok', timestamp: iso(0) };
    case '/api/monitoring/health': return { status: 'healthy', version: '3.8.52', providerBreakers: [{ provider: 'conn-groq-1', state: 'CLOSED', failureCount: 0, retryAfterMs: 0 }, { provider: 'conn-ollama-1', state: 'OPEN', failureCount: 4, retryAfterMs: 30000 }], quotaMonitor: { active: 1, alerting: 0, exhausted: 0, errors: 0 } };
    case '/api/providers': return { connections: conns, total: conns.length };
    case '/api/usage/provider-limits': return scenario === 'missing' ? { caches: {}, intervalMinutes: 70, lastAutoSyncAt: iso(-H) }
      : { intervalMinutes: 70, lastAutoSyncAt: iso(-H), caches: {
          'conn-ollama-1': { fetchedAt: iso(-10 * 60e3), plan: 'free', message: null, quotas: { monthly: { used: 12.5, total: 100, remaining: 87.5, remainingPercentage: 87.5, resetAt: iso(10 * 24 * H), unlimited: false, displayName: 'Monthly' }, session: { used: 0, total: 0, unlimited: true, displayName: 'Session' } } },
          'conn-groq-1': { fetchedAt: iso(-5 * 60e3), plan: null, message: 'no quota API', quotas: null },
          'conn-old-1': { fetchedAt: iso(-48 * H), plan: null, message: null, quotas: { daily: { used: 1, total: 10, remaining: 9, resetAt: iso(H), displayName: 'Daily' } } },
          'conn-mystery': { fetchedAt: iso(-1 * 60e3), plan: null, message: null, quotas: { weekly: { used: 3, total: 10, remaining: 7, resetAt: '2020-01-01T00:00:00Z', displayName: 'Weekly' }, junk: { used: -5, total: 'x' } } } } };
    case '/api/usage/analytics': return { range: '30d', includesFlatRateEstimates: scenario === 'ok', summary: { totalRequests: 8, promptTokens: 20, completionTokens: 4, totalTokens: 24, totalCost: 0 },
      byProvider: [{ provider: 'MockLocal', requests: 4, totalTokens: 24 }, { provider: 'Cloudflare AI Playground', requests: 2, totalTokens: 0 }] };
    case '/api/free-tier/summary': return { steadyRecurringTokens: 1623225000, modelCount: 467, poolCount: 34, catalogSource: 'baseline', catalogUpdatedAt: '2026-10-08', usedThisMonth: scenario === 'missing' ? null : 4200, remaining: 1623220800,
      perModel: [{ provider: 'groq', modelId: 'm1', poolKey: 'groq', monthlyTokens: 15000000, freeType: 'recurring-monthly', tos: 'ok' }, { provider: 'groq', modelId: 'm2', poolKey: 'groq', monthlyTokens: 15000000, freeType: 'recurring-monthly', tos: 'ok' },
                 { provider: 'mistral', modelId: 'x', poolKey: 'mistral', monthlyTokens: 1000000000, freeType: 'recurring-monthly', tos: 'caution' }] };
  }
  return undefined;
}

export function startMock(gateway, scenario = 'ok', port = 0) {
  const requests = [];
  const publicPaths = gateway === 'freellmapi' ? ['/api/ping'] : ['/api/health/ping', '/api/monitoring/health'];
  const want = gateway === 'freellmapi' ? CANARY.unified : CANARY.mgmt;
  const server = http.createServer((req, res) => {
    const path = req.url.split('?')[0];
    requests.push({ method: req.method, path, auth: req.headers.authorization ?? null });
    const send = (code, body, headers = {}) => { res.writeHead(code, { 'content-type': 'application/json', ...headers }); res.end(typeof body === 'string' ? body : JSON.stringify(body)); };
    if (req.method !== 'GET') return send(405, { error: 'method not allowed' });
    if (scenario === 'redirect') return send(302, '', { location: 'http://127.0.0.1:1/steal' });
    if (scenario === 'ratelimit') return send(429, { error: `slow down ${CANARY.stored}` }, { 'retry-after': '30' });
    if (scenario === 'malformed') return send(200, path.endsWith('ping') ? { status: 'ok' } : '<html>not json {{{');
    if (scenario === 'wrongtypes') return send(200, path.endsWith('ping') ? { status: 'ok' } : [1, 2, 3]);
    if (!publicPaths.includes(path) && req.headers.authorization !== `Bearer ${want}`) return send(401, { error: { message: `Invalid API key ${CANARY.stored}` } });
    if (scenario === 'auth') return send(401, { error: 'nope' });
    const body = (gateway === 'freellmapi' ? freellmapi : omniroute)(path, scenario);
    return body === undefined ? send(404, { error: 'not found' }) : send(200, body);
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ server, port: server.address().port, requests, close: () => new Promise((r) => server.close(r)) })));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const [gateway, scenario = 'ok', port = '0'] = process.argv.slice(2);
  const m = await startMock(gateway, scenario, Number(port));
  console.log(`mock ${gateway}/${scenario} listening on ${m.port}`);
}
