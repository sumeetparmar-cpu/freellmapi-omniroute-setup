# `quota-report`: read-only usage, quota and availability report

```bash
# Termux / Linux                                                  # Windows PowerShell
FREELLMAPI_KEY=... ./termux/freellmapi.sh quota-report            $env:FREELLMAPI_KEY='...'; .\windows\freellmapi.ps1 quota-report
OMNIROUTE_MGMT_TOKEN=... ./termux/omniroute.sh quota-report       $env:OMNIROUTE_MGMT_TOKEN='...'; .\windows\omniroute.ps1 quota-report
# options: --json  --list-models (FreeLLMAPI)  --max-age-min N (OmniRoute)  --key-file F / --token-file F   (PowerShell: -Json -ListModels -MaxAgeMin -KeyFile -TokenFile)
```

It reports what each gateway **exposes about itself** and nothing else. It does not contact providers, does not send model
requests, and does not change any setting. It never prints, logs or stores credentials.

## Credentials (least privilege)

| Gateway | Credential | Where to get it | Can it change anything? |
|---|---|---|---|
| FreeLLMAPI | the **unified key** (`FREELLMAPI_KEY`) | dashboard → Keys page header | It is the same key clients use for inference, so protect it. The report only does GETs. |
| OmniRoute | a **read-scope Access Token** `oma_live_…` (`OMNIROUTE_MGMT_TOKEN`) | Dashboard → Settings → Access Tokens → scope **read** | No: a read token gets HTTP 403 on write routes (verified on 3.8.52). Do not use your inference `sk-…` key or the dashboard password. |

Supply via environment variable, `--key-file`/`--token-file`, or a hidden prompt (OmniRoute: Enter skips). The value is handed to Node
through the process environment, never on a command line, and is redacted from all output. Without a credential the
authenticated sections print `Unknown / unavailable` and only public health endpoints are queried.

## The four labels (every line has exactly one)

| Label | Meaning here |
|---|---|
| **Provider-reported quota** | A limit / remaining / reset the *provider* reported and the gateway relayed or cached. Only shown when the numbers exist, are valid, and the window has not already reset. |
| **Gateway-counted usage** | Anything the gateway measured or decided itself: usage ledgers, token counts, key status, cooldowns, model readiness, health. Includes caps *you* configured in the gateway (these are not provider quota). |
| **Documented estimate** | Figures from the upstream free-tier catalog (documentation, not a live reading). Always shown separately and never added to provider-reported figures. |
| **Unknown / unavailable** | The source was not reachable, rejected the credential, rate-limited us, returned malformed or wrongly-typed data, returned a stale value, or simply does not expose the field. No number is shown. |

## Endpoints queried (all `GET`, allow-listed in code; anything else is refused before a socket opens)

| Gateway | Endpoint | Auth | Used for | Label(s) |
|---|---|---|---|---|
| FreeLLMAPI | `/api/ping` | none | liveness | Gateway |
| | `/v1/usage` | unified key | this month's requests/tokens per provider and key, your own caps, ledger reset time | Gateway |
| | `/v1/providers` | unified key | provider identity, key status, cooldown/resume time, health error (scrubbed), `requests_remaining_pct` | Gateway; the percentage is Provider |
| | `/v1/quota-forecast` | unified key | per-pool used/remaining/limit/reset the providers reported (**requests metric only**) | Provider |
| | `/v1/models` | unified key | per-model `execution_status` (ready / exhausted / needsKey) | Gateway |
| OmniRoute | `/api/health/ping`, `/api/monitoring/health` | none | liveness, circuit-breaker state, quota-monitor counters | Gateway |
| | `/api/providers` | read token | connection identity only (id, provider, name, active, last test status); the rest of each record, including masked key fields, is discarded unread | Gateway |
| | `/api/usage/provider-limits` | read token | **cached** provider quota windows (used / total / remaining / %, reset time, fetch time). `GET` does not refresh the cache | Provider |
| | `/api/usage/analytics?range=30d` | read token | requests and tokens over a rolling 30 days, per provider | Gateway |
| | `/api/free-tier/summary` | read token | catalog-wide documented free allowance; per connected provider, one documented budget per shared pool | Estimate (+ month-to-date usage when OmniRoute provides it) |

Never called: `/v1/chat/completions` and every other generation endpoint, any `POST` (including the manual provider-limits
**refresh**, which would contact providers), pricing sync, key/provider management, and FreeLLMAPI's `/api/free-tier` (needs a dashboard login session, so it
would mean handling the password).

## How the rules in the spec are enforced

* **No double counting.** No total is computed across providers, keys or pools. FreeLLMAPI per-provider/per-key rows are printed as "a view of the totals", quota pools are one row each, and OmniRoute's documented budget is taken once per shared `poolKey` (the maximum, never a sum of its member models).
* **No mixing of estimate and reported.** OmniRoute's own `remaining` field (catalog estimate minus counted usage) is deliberately ignored. Estimate lines never contain "remaining", and provider lines never contain estimates.
* **Errors and gaps are Unknown.** HTTP 401/403, 404, 429 (not retried; `Retry-After` shown), 5xx, redirects (refused; credentials are never forwarded), timeouts, invalid JSON, wrong types, negative / non-numeric values, and missing fields all become `Unknown` with a short reason. Response bodies are never echoed.
* **Stale data is Unknown.** A FreeLLMAPI ledger whose reset time has passed, a quota window whose reset time has passed, and an OmniRoute cache entry older than `2 × its sync interval` (override with `--max-age-min`) are withheld.
* **Free vs paid.** Neither status endpoint says whether a model or a gateway-counted token was free. That is stated, not guessed.

## What it cannot tell you (limitations)

* **Quota windows exist only where a provider reports them.** Many free tiers expose no quota API; FreeLLMAPI's pool list and OmniRoute's provider-limits cache are then empty, and the report says "absence does not mean unlimited".
* **FreeLLMAPI's relayed provider quota is request-based only** (`metric=requests`); token quotas are not exposed on the unified-key routes.
* **FreeLLMAPI `/v1/models` does not say which provider serves a model** (`owned_by` is always `freellmapi`) **or whether it is free.** Readiness is the gateway's view (key status, cooldowns, windows), not a guarantee.
* **OmniRoute per-model readiness is reported Unknown**: `GET /v1/models` listed 289 models on an install with no real provider connected, so it is not evidence of availability, and no other documented read-only readiness endpoint was verified.
* **OmniRoute month-to-date usage is withheld** from access-token callers (only a dashboard session unlocks it), so the report uses the rolling 30-day analytics instead and says so. OmniRoute estimates tokens when a provider returns no usage figures; those estimates are inside the "counted" number.
* **No reset time** is available for OmniRoute's 30-day figure (it is rolling) or for calendar-month usage.
* Endpoint shapes were taken from the upstream docs/source and the sandbox instances as of 2026-10-29 (FreeLLMAPI v0.16.12, OmniRoute 3.8.52). If a later version changes a shape, fields will degrade to Unknown rather than be guessed.
* **Not verified against any real provider quota.** See [TESTING.md](TESTING.md#quota-report).
