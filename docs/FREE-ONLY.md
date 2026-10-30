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
| Cloudflare | Workers **Free** plan (10,000 Neurons/day); never move to Workers Paid. Eight listed models are paid-only and are blocked. **Design limit:** the Cloudflare rule is `@cf/` prefix minus that deny list (the free catalog changes monthly), so a paid-only model Cloudflare adds *later* would pass the guard; on the Free plan Cloudflare refuses it instead of billing, which makes the plan precondition the real protection here. Re-check the deny list against the pricing page when you update the policy. |
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

## OmniRoute: the keyless ₹0 route (verified live 2026-10-30)

OmniRoute's built-in `ovhcloud` connector insists on an API key (and OVH keys need a payment method), so do **not** use it. Instead add a *custom OpenAI-compatible node* that points at OVH's anonymous endpoint.
No credential is invented or sent: OmniRoute accepts a connection with no key, you activate it, and requests reach OVH unauthenticated (OVH's anonymous tier, 2 req/min per IP per model).

1. Dashboard → Providers → *Add OpenAI-compatible node*: name `OVH anonymous`, **prefix `ovhanon`** (the policy only knows this prefix), type `chat`, base URL `https://oai.endpoints.kepler.ai.cloud.ovh.net/v1`.
2. Add a connection for that node **without an API key** and make it active.
3. Call it as `ovhanon/gpt-oss-20b` (or `ovhanon/gpt-oss-120b`, `ovhanon/Qwen3.6-27B`, `ovhanon/Mistral-Small-3.2-24B-Instruct-2506`, …).

Result on the real stack: client → free-guard → OmniRoute 3.8.52 → OVH returned `pong` with real token usage. `free-policy omniroute audit` accepts exactly this node and flags any other custom node
(wrong prefix, wrong base URL, or a compatible connection without a node) and engages the kill switch via `--flag-file`.

Limits of this route: it is *one* provider, rate-limited to 2 requests/minute/model by OVH (the guard enforces the same locally), and OVH reserves the right to add caps or retire models. Other keyless providers
bundled in OmniRoute (`duckduckgo-web`, `cloudflare-playground`, `veoaifree-web`, `uncloseai`, `aihorde`, …) are web/browser bridges or unverified community services; they are not in the policy and are blocked.

## Client keys: make "go through the guard" the only way in

Without client keys, anyone who holds the gateway's own API key can call the gateway directly and skip the guard. With client keys the gateway key stays in a root-only file the clients never see:

```bash
node tools/free-guard.mjs --new-client-key laptop --client-keys-file state/clients   # prints the key ONCE; only its SHA-256 is stored
printf '%s\n' "$GATEWAY_API_KEY" > state/upstream.key && chmod 600 state/upstream.key      # key from the gateway dashboard
node tools/free-guard.mjs --gateway omniroute --upstream http://127.0.0.1:20128 --listen 127.0.0.1:20228 \
     --client-keys-file state/clients --upstream-key-file state/upstream.key
```

Verified live: the gateway key does not work through the guard, and a guard key does not work against either gateway directly (both answer 401).

Other guard hardening (all covered by `tests/guard/security.test.mjs`): only `application/json` POSTs; the query string is dropped; only a header allowlist is forwarded (no `x-omniroute-*`, `x-freellm-*`, cookies, sessions or forwarding headers);
`Host` must be loopback or `--allow-host`; `/__guard/status` is refused when reached through a reverse proxy; model strings must be plain printable ASCII; `n>1`, `best_of`, `extra_body`, non-`function` tools, `fusion` are blocked;
at most 16 requests in flight; counters, cooldowns and per-minute windows are written through to the state file on every counted request, so a crash or restart cannot hand quota back.

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

## Monitoring, quotas, recovery

* `curl http://127.0.0.1:3101/__guard/status` (local only, refused behind a reverse proxy): requests today per provider, active cooldowns, blocked/passed counts, caps in force, kill-switch state. Never contains credentials.
* `vps/monitor.sh check` (the existing 5-minute monitor) now also reports, for every gateway whose guard is installed: guard unit active, last audit run failed, **kill switch engaged (CRIT)**, active cooldowns (WARN) and each provider's
  usage against its self-imposed daily cap (WARN at 80%/100%). Implemented by `tools/free-status.mjs`; `tests/vps/monitor-guard.test.sh` covers every level.
* Guard log (`--log`, default `<gw>/logs/free-guard.log`): one JSON line per decision (`deny` / `pass` / `cooldown`); no bodies, no headers. Size-capped at 5 MB with one rotated generation (`.1`), so it cannot fill the disk.
* `tools/quota-report.mjs` (existing): provider-reported quota from the gateways themselves. Guard counters are **local estimates**; the provider's own numbers win.
* **Self-healing (FreeLLMAPI):** the 10-minute audit runs with `--auto-fix`: if catalog sync adds a non-free model it is *disabled* (never enabled, never deleted), the kill flag is cleared and inference resumes without a human. OmniRoute's audit is read-only: a
  non-free provider or custom node engages the kill switch until you remove it in the dashboard.
* **Stop/restart:** `systemctl stop` drains in-flight responses for up to 5 s (`GUARD_DRAIN_MS`), flushes state and exits 0; `Restart=always` brings a crashed guard back in 3 s with its counters, cooldowns and rate windows intact.
* **Backups:** `gwctl <gw> backup` / `restore` carry `config/free-guard.clients` (client-key *hashes*, not secret) so a restore does not lock clients out. They deliberately do **not** carry `free-guard.upstream.key` or `free-audit.env`
  (secrets): after a restore on a new machine, re-create those two files (gateway API key from the dashboard; admin credential for the audit). Covered by `tests/vps/guard-backup.test.sh`.

## Credentials

* Provider keys: enter them in each gateway's dashboard (stored encrypted by the gateway). They are never in this repo, `argv`, logs or units.
* The guard forwards the caller's `Authorization` header and never logs it (covered by a canary test).
* TLS verification is never disabled anywhere in this code.

## Test evidence

See `docs/TESTING.md` ("Free-only layer"). Real inference was exercised once on 2026-10-30 through guard → FreeLLMAPI → OVH anonymous tier (a genuine `gpt-oss-20b` completion). Real inference for Groq, Gemini,
Mistral, OpenRouter and Cloudflare, and for OmniRoute with any provider, is **blocked on credentials** that were not supplied.
