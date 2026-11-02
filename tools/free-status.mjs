#!/usr/bin/env node
// Health evaluation of a running free-guard, for monitors. Read-only, loopback only.
//   node tools/free-status.mjs --url http://127.0.0.1:3101 [--policy file] [--warn-pct 80]
// Prints one line per check:  LEVEL<TAB>name<TAB>detail   (LEVEL = OK | WARN | CRIT). Exit code = worst level (0/1/2).
import http from 'node:http';
import { loadPolicy, limitsFor } from './lib/free-policy.mjs';

/** Pure: turn a /__guard/status document into check results. */
export function evaluate(st, policy, warnPct = 80) {
  const out = [];
  out.push(st.killSwitch ? ['CRIT', 'kill-switch', 'ENGAGED: the audit found a non-free configuration; inference is suspended'] : ['OK', 'kill-switch', 'off']);
  const cds = Object.entries(st.cooldownsSec ?? {});
  out.push(cds.length ? ['WARN', 'cooldowns', cds.map(([k, s]) => `${k} ${s}s`).slice(0, 5).join(', ')] : ['OK', 'cooldowns', 'none']);
  for (const [prov, n] of Object.entries(st.requestsToday ?? {})) {
    const cap = limitsFor(policy, prov).rpd; const pct = Math.round((n / cap) * 100);
    out.push(pct >= 100 ? ['WARN', `quota.${prov}`, `daily cap reached: ${n}/${cap} (resets 00:00 UTC)`] : pct >= warnPct ? ['WARN', `quota.${prov}`, `${n}/${cap} = ${pct}% of the self-imposed daily cap`] : ['OK', `quota.${prov}`, `${n}/${cap}`]);
  }
  return out;
}

function fetchStatus(url) {
  return new Promise((resolve, reject) => {
    const u = new URL('/__guard/status', url);
    if (!['127.0.0.1', 'localhost', '::1'].includes(u.hostname)) return reject(new Error('refusing non-loopback --url'));
    const r = http.get({ hostname: u.hostname, port: u.port, path: u.pathname, timeout: 5000 }, (res) => {
      let t = ''; res.on('data', (d) => (t += d)); res.on('end', () => (res.statusCode === 200 ? resolve(JSON.parse(t)) : reject(new Error(`HTTP ${res.statusCode}`))));
    });
    r.on('timeout', () => r.destroy(new Error('timeout'))); r.on('error', reject);
  });
}

export async function main(argv, out = (s) => process.stdout.write(s + '\n')) {
  const opt = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : undefined; };
  const url = opt('--url'); if (!url) { out('usage: free-status.mjs --url http://127.0.0.1:PORT'); return 2; }
  let results;
  try { results = evaluate(await fetchStatus(url), loadPolicy(opt('--policy')), Number(opt('--warn-pct') ?? 80)); }
  catch (e) { results = [['CRIT', 'guard', `not answering (${String(e.message).slice(0, 80)})`]]; }
  for (const [l, n, d] of results) out(`${l}\t${n}\t${d}`);
  return results.some((r) => r[0] === 'CRIT') ? 2 : results.some((r) => r[0] === 'WARN') ? 1 : 0;
}

if (import.meta.url === `file://${process.argv[1]}`) main(process.argv.slice(2)).then((c) => process.exit(c));
