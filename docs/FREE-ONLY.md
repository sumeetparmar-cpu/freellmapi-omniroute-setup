# Free-only (₹0) operation

Goal: neither gateway can spend money. Enforcement has **three independent layers**; each fails closed.

| Layer | What it does | Where |
|---|---|---|
| 1. Policy allowlist | Only models verified free from an official source (2026-10-30) are allowed. Everything else, including `auto`, combos, `:online`/`:nitro` variants, server tools and `models[]` fallback lists, is refused. | `config/free-policy.json`, `tools/lib/free-policy.mjs` |
| 2. Guard proxy | Loopback reverse proxy in front of each gateway. Blocks non-allowlisted models, params and routes **before** anything leaves the box; adds local per-model rate limits, 429 cooldowns (honours `Retry-After`), UTC daily caps, and a kill switch. No retry, no fallback. | `tools/free-guard.mjs` |
| 3. Catalog audit | Reads the gateway's own config and disables (FreeLLMAPI) or reports (OmniRoute) anything outside the policy; on drift it engages the guard's kill switch. | `tools/free-policy.mjs` |

## What this does NOT (and cannot) guarantee

The guard sees requests, not your **provider accounts**. A model can only bill you if the account behind the key is able to pay. So
the policy lists an account precondition per provider; keep every one true:

| Provider | Keep true (the policy's `precondition`) |
|---|---|
| Groq | Free plan only. Never click *Upgrade to Developer* (needs a card). |
| Gemini | API key from a Google Cloud project with **no billing account** linked. Free tier **trains on your prompts and uses human reviewers**. |
| Mistral | Studio in **Free mode**; never enable pay-as-you-go. Free mode may train on your data; opt out under Admin → Privacy. |
| OpenRouter | $0 credits (only `:free` variants are ever sent). |
| Cloudflare | Workers **Free** plan (10,000 Neurons/day); never move to Workers Paid. Eight listed models are paid-only and are blocked. |
| OVHcloud | **Anonymous tier only**; do not create an OVH API key (it requires a payment method). 2 req/min per IP per model. |

Rate-limit numbers in the policy are *self-imposed ceilings*; only OVH (2/min) and Groq (30 RPM, 1K RPD on the gpt-oss models) are published figures.
Anything marked `reviewQueue` (Cerebras, Cohere, HuggingFace, Kilo, LLM7, NVIDIA, Ollama, OpenCode, Pollinations, Zhipu, and a few Groq/Gemini models) was **not verified**
(their domains are not reachable from the verification environment, or the official page does not list the model as free) and is blocked until someone verifies it.

## One-time setup per gateway (local or VPS)

```bash
# 1. FreeLLMAPI: disable every non-free model / uncovered platform (never enables or deletes anything).
export FREELLMAPI_ADMIN_TOKEN=...   # or FREELLMAPI_ADMIN_EMAIL + FREELLMAPI_ADMIN_PASSWORD (hidden prompt / 0600 file; never argv)
node tools/free-policy.mjs freellmapi audit --base-url http://127.0.0.1:3001      # exit 1 = violations
node tools/free-policy.mjs freellmapi apply --base-url http://127.0.0.1:3001      # exit 0 = clean

# 2. Start the guards and point every client at the GUARD port, never the gateway port.
node tools/free-guard.mjs --gateway freellmapi --upstream http://127.0.0.1:3001 --listen 127.0.0.1:3101 --catalog-audited \
     --state state/fl-guard.json --log logs/fl-guard.log --kill-file state/audit.flag
node tools/free-guard.mjs --gateway omniroute  --upstream http://127.0.0.1:20128 --listen 127.0.0.1:20228 \
     --state state/om-guard.json --log logs/om-guard.log

# 3. OmniRoute: connect ONLY the policy's providers; use explicit models such as groq/openai/gpt-oss-20b.
OMNIROUTE_MGMT_TOKEN=... node tools/free-policy.mjs omniroute audit --base-url http://127.0.0.1:20128
```

* `--catalog-audited` (FreeLLMAPI only) lets `auto` and the gateway's grouped model ids through. **Use it only after `apply` is clean**: FreeLLMAPI v0.16.12 always groups same-named
  models behind one id (the `unify` switch is ignored upstream), so the exact-id allowlist can only be trusted once every enabled member of every group is free.
  The kill switch covers drift between audits: `audit --flag-file F` creates `F` on violations, and `free-guard --kill-file F` then answers every inference request with 503 until a later audit removes it.
* A model that FreeLLMAPI/OmniRoute would add later (catalog sync, new provider) is therefore refused by the guard (OmniRoute) or pruned/flagged by the audit (FreeLLMAPI).

## VPS (prepared, not applied)

`vps/free-install.sh` follows the same dry-run-by-default rules as `vps/deploy.sh` and only adds six unit files; it never touches the gateway units, Docker, Caddy, n8n, SUPPAR, EARNIX or any database.

```bash
./vps/free-install.sh units [--catalog-audited]      # DRY RUN: shows exactly what would be written
./vps/free-install.sh --apply units [--catalog-audited]   # writes llm-guard-<gw>.service, llm-free-audit-<gw>.service/.timer (not enabled)
./vps/free-install.sh --apply enable freellmapi      # starts the guard on 127.0.0.1:3101 + 10-minute audit timer, checks it answers
./vps/free-install.sh status
```

Guard ports: 3101 (FreeLLMAPI) and 20228 (OmniRoute), overridable with `GUARD_PORT_*`. The audit reads an *optional* `<gw>/config/free-audit.env` (0600, owned by the service user) with the admin credential; without it the audit
exits 2 (visible as a failed unit) and the guard keeps its current state. Create that file yourself; the toolkit never writes provider or admin secrets.

## Monitoring and quotas

* `curl http://127.0.0.1:3101/__guard/status` (loopback only): requests today per provider, active cooldowns, blocked/passed counts, the caps in force, kill-switch state. Never contains credentials.
* Guard log (`--log`): one JSON line per decision (`deny` / `pass` / `cooldown`); no bodies, no headers.
* `tools/quota-report.mjs` (existing): provider-reported quota from the gateways themselves. Counters in the guard are **local estimates**; the provider's own numbers win.
* `vps/monitor.sh` remains the resource/health check.

## Credentials

* Provider keys: enter them in each gateway's dashboard (stored encrypted by the gateway). They are never in this repo, `argv`, logs or units.
* The guard forwards the caller's `Authorization` header and never logs it (covered by a canary test).
* TLS verification is never disabled anywhere in this code.

## Test evidence

See `docs/TESTING.md` ("Free-only layer"). Real inference was exercised once on 2026-10-30 through guard → FreeLLMAPI → OVH anonymous tier (a genuine `gpt-oss-20b` completion). Real inference for Groq, Gemini,
Mistral, OpenRouter and Cloudflare, and for OmniRoute with any provider, is **blocked on credentials** that were not supplied.
