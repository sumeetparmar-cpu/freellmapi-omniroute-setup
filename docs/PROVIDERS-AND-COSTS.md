# Providers, costs, quotas and restrictions

Facts below come from the two upstream repositories as inspected on **2026-10-29**
(FreeLLMAPI `main` @ `36826e7` = v0.16.12; OmniRoute `main` @ `689b1eb`, npm `omniroute@3.8.52`).
Free tiers change without notice, so **treat every number as "last documented", not as a promise**, and
check the provider's own page before relying on it. This is not legal advice.

## What costs money, and what does not

| Item | Cost |
|---|---|
| FreeLLMAPI software | Free (MIT). |
| OmniRoute software | Free (MIT). |
| These scripts | Free. Disk/RAM thresholds in the audit (≈3 GB free disk, ≥3 GB RAM) are this toolkit's own conservative heuristics, not upstream requirements. |
| Provider accounts / API keys | **You** sign up per provider. Free tiers can still require an account, API key, manual approval, KYC, or a payment method. |
| FreeLLMAPI "Premium / go live" | Optional, **$19/yr** per upstream README. Without it you get the monthly catalog snapshot, i.e. new free models reach you ~30 days late. Not needed for the toolkit. |
| OmniRoute "Radar" live catalog | Optional, for supporters (see its README). The community catalog and all existing features stay free. Not needed for the toolkit. |
| Paid providers | Never enabled by the toolkit. If you add a paid key yourself, **requests can bill your account**; neither gateway can promise to stay inside a free tier. Set spend limits at the provider. |

Neither gateway "creates" tokens. Headline figures like "7.4 B tokens/month" (FreeLLMAPI) or "~1.62 B" (OmniRoute) are
the *sum of documented free tiers across all providers if you connect all of them*; OmniRoute's own docs say it
"does not issue the advertised aggregate token budget". Your real budget is whatever the providers you connect allow.

## Quotas and limits that matter in practice

* **Rate limits, daily caps and monthly pools apply per provider/key** and reset on the provider's schedule
  (FreeLLMAPI notes many daily caps reset at UTC midnight). Hitting them returns HTTP 429 or auth errors.
* **Quality drifts through the day**: the strongest models have the smallest caps; routers then fall back to weaker ones.
* **No SLA**; latency varies a lot (FreeLLMAPI: "Cerebras and Groq are extremely fast; others are not").
* **Free tiers get tightened or removed** at any time (both projects say so). Expect occasional breakage after upstream changes.
* `test-model` sends **one tiny request** (`max_tokens=16`). It still consumes a request from whichever provider the
  router picks. `GET /v1/models` is free of model quota.

## Terms-of-service posture (from the upstream docs, summarised)

FreeLLMAPI's own review (May 2026; informational, not legal advice) rates a *personal, single-user, self-hosted* proxy as:

| Verdict | Providers (as listed upstream) |
|---|---|
| Likely OK | Groq, Cerebras, Mistral, OpenRouter, Zhipu, Ollama Cloud, OVH AI Endpoints, AI Horde |
| Caution / ambiguous | Google Gemini (ToS now says "professional or business purposes, not for consumer use"), NVIDIA NIM (evaluation-only), Z.ai, Cloudflare Workers AI |
| **Avoid** | **Cohere** (terms forbid personal/household use) |

Rules of thumb it gives, which these scripts assume: **one account per provider, no reselling, do not share your
endpoint with other people, do not hammer a free tier as a production backend.** FreeLLMAPI states it is
"for personal experimentation and learning, not production".

OmniRoute marks providers with a `tos` flag; `tos: avoid` providers (e.g. **Kiro**) are excluded from automatic
routing by default, and connecting an account does not bypass that. It also lists free-access caveats, e.g.:

* **Logfare** — free key, no rate limits, but **every request is logged** for research (opt-out at the provider).
* **Cerebras** — one-time $5 promo credit **requires a payment method** and expires after 30 days.
* **LongCat** — 10 M-token grant needs **KYC**; pay-as-you-go afterwards.
* **Vertex AI** — $300 signup credit needs a Google Cloud billing account; billing applies afterwards.
* **Pollinations** and other **keyless** providers — no credential, but rate-limited, can reject third-party clients, and may be discontinued.

## Verified against official sources on 2026-10-30 (Groq, Gemini, Mistral, OpenRouter, Cloudflare Workers AI, OVHcloud)

Re-check before relying on any figure. "Account-dependent" means the number is shown only inside your provider account.

| | Free access / card | Published limits | Data use | India |
|---|---|---|---|---|
| **Groq** | Free plan; card only to upgrade ([billing FAQs](https://console.groq.com/docs/billing-faqs)) | Free plan e.g. gpt-oss-120b/20b: 30 RPM, 1K RPD, 8K TPM, 200K TPD ([rate limits](https://console.groq.com/docs/rate-limits)) | Inference not retained by default; ZDR available ([your data](https://console.groq.com/docs/your-data)) | India billing rules exist; no eligibility list found |
| **Gemini** | Free tier, no card; billing only to upgrade ([pricing](https://ai.google.dev/gemini-api/docs/pricing)) | Per-project; reset midnight Pacific; numbers in AI Studio ([limits](https://ai.google.dev/gemini-api/docs/rate-limits)) | **Free tier: used to improve products, human review** ([terms](https://ai.google.dev/gemini-api/terms)) | **Listed as available** ([regions](https://ai.google.dev/gemini-api/docs/available-regions)) |
| **Mistral** | Free mode, no card ([quickstart](https://docs.mistral.ai/getting-started/quickstarts/studio/activate-and-generate-api-key)) | Free = lowest tier; numbers in Admin panel ([help](https://help.mistral.ai/en/articles/698531-why-am-i-hitting-api-rate-limits-and-how-do-i-increase-them)) | **Free mode may train; opt-out in Admin → Privacy** ([help](https://help.mistral.ai/en/articles/347617-do-you-use-my-user-data-to-train-your-artificial-intelligence-models)) | not stated |
| **OpenRouter** | `:free` models; card requirement not stated | Free-model RPM/RPD depend on credits purchased ([limits](https://openrouter.ai/docs/api-reference/limits)); numbers did not render in the fetched page | OpenRouter does not train on inputs/outputs ([privacy](https://openrouter.ai/privacy)); upstream providers differ ([logging](https://openrouter.ai/docs/features/privacy-and-logging)) | not stated |
| **Cloudflare** | Workers Free: 10,000 Neurons/day; 8 models need a paid method ([pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)) | Text generation 300 RPM ([limits](https://developers.cloudflare.com/workers-ai/platform/limits/)) | Zero retention, no training ([data usage](https://developers.cloudflare.com/workers-ai/platform/data-usage/)) | not stated |
| **OVHcloud** | **Anonymous tier works with no key**; an API key needs a Public Cloud project with a payment method ([getting started](https://docs.ovhcloud.com/en/guides/public-cloud/ai-machine-learning/ai-endpoints-getting-started)) | Anonymous 2 req/min per IP per model; authenticated 400 req/min per project per model | "We do not store user data" | not stated |

OVH API host (used by both gateways, confirmed with an unauthenticated `GET /v1/models` = 200, 22 models, all priced 0): `https://oai.endpoints.kepler.ai.cloud.ovh.net/v1`.
Both gateways support all six: FreeLLMAPI v0.16.12 (`groq google mistral openrouter cloudflare ovh`) and OmniRoute 3.8.52 (`groq gemini mistral openrouter cloudflare-ai ovhcloud`).
Enforcement of "free only" is described in [FREE-ONLY.md](FREE-ONLY.md).

## Behaviour observed while testing (OmniRoute `model=auto`)

On a **fresh** OmniRoute install with no provider connected, a request with `model: "auto"` was routed to a
*keyless, browser-based* provider (Cloudflare Playground) and failed with HTTP 503 ("needs Playwright and its
Chromium browser"). Lesson: `auto` can pick targets you never chose. Therefore:

* `omniroute … test-model` **requires an explicit `--model` / `-Model`** (the toolkit never defaults to `auto`).
* Connect only the providers whose terms you have read, then select models by `provider/model`.

## Privacy and network behaviour to know about

* FreeLLMAPI logs `[catalog-sync] polling https://api.freellmapi.co every 12h` (signed model-catalog feed) and runs
  a background key health check every ~5 min (`HEALTH_CHECK_INTERVAL_MS`); some providers meter key validation, so
  a faster cadence can cost quota. Optional background model probes are **off** unless `MODEL_PROBE_ENABLED=1`.
* OmniRoute's optional Radar overlay is opt-in and GET-only; upstream states it uploads no prompts, traffic or
  usage telemetry. The CLI uses `update-notifier` (checks npm for new versions).
* Your prompts go to whichever **upstream provider** serves the request, under that provider's data policy.
  Some free tiers train on or log prompts. Do not send secrets or personal data through free tiers you have not vetted.
* Both dashboards hold provider keys. The toolkit binds them to `127.0.0.1`. If you set `GATEWAY_BIND_HOST=0.0.0.0`,
  use only a trusted network (or a private VPN such as Tailscale), keep API-key auth on, and never port-forward to the internet.

## Where the secrets live

| Secret | Where | Notes |
|---|---|---|
| FreeLLMAPI `ENCRYPTION_KEY` | `llm-gateways/config/freellmapi.env` | **Losing it makes stored provider keys undecryptable.** Back up with the DB. |
| OmniRoute `JWT_SECRET`, `API_KEY_SECRET`, `STORAGE_ENCRYPTION_KEY`, `INITIAL_PASSWORD` | `llm-gateways/config/omniroute.env` | Same warning for the storage key. `INITIAL_PASSWORD` is only used until you change it in the dashboard. |
| Provider API keys | each gateway's SQLite DB (encrypted at rest) | Entered in the dashboards, never in this repo or in scripts. |
| Gateway client keys | shown in dashboards | Pass to `test-model` via env var, key file or hidden prompt. |

Backups contain the keys above. Treat `llm-gateways/backups/` as secret; the scripts create it owner-only.
