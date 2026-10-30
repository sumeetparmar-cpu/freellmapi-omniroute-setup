// Free-only policy engine shared by free-guard.mjs and free-policy.mjs. Zero dependencies.
// classify() is the single decision point: a model is allowed only if a provider rule says so.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULT_POLICY_PATH = path.resolve(HERE, '../../config/free-policy.json');

export function loadPolicy(file = DEFAULT_POLICY_PATH) {
  const p = JSON.parse(readFileSync(file, 'utf8'));
  if (p.version !== 1 || typeof p.providers !== 'object') throw new Error(`bad policy file ${file}`);
  return p;
}

const norm = (s) => String(s).trim();

function providerAllows(rule, model) {
  if (rule.deny?.includes(model)) return { ok: false, why: 'listed as paid-only in the provider docs' };
  if (rule.allow?.includes('*')) return { ok: true };
  if (rule.allow?.includes(model)) return { ok: true };
  if (rule.allowSuffix) {
    // exactly one trailing ':free'; ':free:online', ':nitro' etc. never match
    return model.endsWith(rule.allowSuffix) && model.indexOf(':') === model.length - rule.allowSuffix.length
      ? { ok: true } : { ok: false, why: `only '${rule.allowSuffix}' variants are free` };
  }
  const prefixes = [].concat(rule.allowPrefix ?? []);
  if (prefixes.some((x) => model.startsWith(x))) return { ok: true };
  return { ok: false, why: 'not on the verified-free list' };
}

/**
 * @param {object} policy
 * @param {'freellmapi'|'omniroute'} gateway
 * @param {string|undefined} rawModel
 * @param {{allowAuto?: boolean}} opts allowAuto: FreeLLMAPI 'auto'/missing model is only safe after the catalog was pruned.
 * @returns {{ok:boolean, provider?:string, model?:string, reason?:string}}
 */
export function classify(policy, gateway, rawModel, opts = {}) {
  const model = rawModel == null ? '' : norm(rawModel);
  if (model === '' || model === 'auto') {
    return gateway === 'freellmapi' && opts.allowAuto
      ? { ok: true, provider: 'freellmapi', model: 'auto' }
      : { ok: false, reason: "'auto' / missing model is blocked (it could route to an unverified provider)" };
  }
  if (gateway === 'omniroute') {
    const i = model.indexOf('/');
    if (i < 1) return { ok: false, reason: 'OmniRoute models must be explicit provider/model (combos and aliases are blocked)' };
    const prefix = model.slice(0, i), rest = model.slice(i + 1);
    for (const [name, rule] of Object.entries(policy.providers)) {
      if (rule.ids.includes(prefix)) {
        const r = providerAllows(rule, rest);
        return r.ok ? { ok: true, provider: name, model: rest } : { ok: false, provider: name, model: rest, reason: `${name}: ${r.why}` };
      }
    }
    return { ok: false, reason: `provider prefix '${prefix}' is not in the verified-free policy` };
  }
  // FreeLLMAPI: bare model ids; a model can belong to exactly one provider rule.
  const hits = [];
  for (const [name, rule] of Object.entries(policy.providers)) {
    const r = providerAllows(rule, model);
    if (r.ok) hits.push(name);
  }
  if (hits.length === 1) return { ok: true, provider: hits[0], model };
  if (hits.length > 1) return { ok: false, reason: `ambiguous model id (${hits.join(', ')})` };
  return { ok: false, reason: 'not on the verified-free list' };
}

export function limitsFor(policy, provider) {
  return policy.providers[provider]?.limits ?? policy.gatewayLimits?.[provider] ?? { rpm: 10, rpd: 200 };
}

export function routeAllowed(policy, method, urlPath) {
  const p = urlPath.replace(/\/+$/, '') || '/';
  return policy.allowedRoutes.some((r) => {
    const [m, rp] = r.split(' ');
    return m === method && (rp.endsWith('/*') ? p.startsWith(rp.slice(0, -2)) : rp === p);
  });
}

/** Returns a reason string if the request body tries to enable paid/fallback features, else null. */
export function inspectBody(policy, body) {
  if (body == null || typeof body !== 'object') return null;
  if (body.n !== undefined && body.n !== 1) return "body field 'n' > 1 is blocked (multiplies quota use)";
  if (body.best_of !== undefined) return "body field 'best_of' is blocked";
  for (const f of policy.forbiddenBodyFields) if (f in body) return `body field '${f}' is blocked (fallback/paid routing)`;
  if (Array.isArray(body.tools)) {
    for (const t of body.tools) {
      if (!policy.allowedToolTypes.includes(t?.type)) return `tool type '${t?.type}' is blocked (server-side tools can bill)`;
    }
  }
  return null;
}
