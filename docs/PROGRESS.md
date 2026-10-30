# Progress log (append-only; newest at the bottom)

Resume rule: read the last "NEXT" line, continue from there. Facts here are dated; re-verify before relying on them.

## 2026-10-30

* DONE  Network allowlist verified (11 + 7 provider domains reachable through the session proxy).
* DONE  Official-source verification of six providers (Groq, Gemini, Mistral, OpenRouter, Cloudflare Workers AI, OVHcloud).
        Summary and sources: `docs/PROVIDERS-AND-COSTS.md` (section "Verified 2026-10-30").
* DONE  Confirmed OVH API host: `https://oai.endpoints.kepler.ai.cloud.ovh.net/v1` (anonymous `GET /v1/models` = 200, 22 models, all priced 0).
* DONE  Confirmed both gateways support all six providers (FreeLLMAPI v0.16.12 @ 36826e7; omniroute@3.8.52).
* START Autonomous phase: free-only enforcement, routing, monitoring, real-inference verification, VPS deployment prep.
* DONE  config/free-policy.json: per-model allowlist from official pages (Groq free-plan table, Google free-tier pricing, Cloudflare paid-only list, OpenRouter ':free', OVH anonymous). Everything else blocked; unverified items in reviewQueue.
* DONE  tools/lib/free-policy.mjs + tools/free-guard.mjs (policy, routes, fallback/paid body fields, local rate limit, cooldown on 429, UTC daily caps, secret-free logs, loopback only). tests/guard: 12/12 pass. Found+fixed: chunked requests broke forwarding.
* DONE  Both gateways built+started in the scratchpad from the toolkit (FreeLLMAPI pinned v0.16.12 = 36826e7, omniroute 3.8.52). Health OK.
* NEXT  free-policy CLI: apply/audit FreeLLMAPI catalog; OmniRoute audit; real OVH anonymous inference through guard+gateway; systemd units; docs; CI.
