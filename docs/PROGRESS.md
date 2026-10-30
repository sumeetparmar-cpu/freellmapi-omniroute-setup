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
* DONE  tools/free-policy.mjs: check / freellmapi audit|apply (prunes non-free models + uncovered platforms, custom endpoints only for listed base URLs, --flag-file kill switch) / omniroute audit (read-only).
        Live result on FreeLLMAPI v0.16.12: 97 -> 43 enabled models, 0 violations. FINDING: v0.16.12 always groups same-named models (unify cannot be disabled) -> safe only because apply leaves free members enabled; guard --catalog-audited + --kill-file cover drift.
* DONE  REAL INFERENCE 2026-10-30: guard(3101) -> FreeLLMAPI -> OVH anonymous tier (gpt-oss-20b, max_tokens=16): genuine completion with usage. 1 request. Paid/fallback/tool/route negatives all refused locally.
* DONE  OmniRoute 3.8.52 path: guard(3102) -> OmniRoute with real API key: allowed model refused by OmniRoute (provider_not_configured, no inference); paid/auto blocked by guard.
* BLOCKED(credentials) OmniRoute real inference: needs a provider key; its ovhcloud connector requires an API key (OVH keys need a payment method) so no ₹0 keyless path. Groq/Gemini/Mistral/OpenRouter/Cloudflare keys not supplied.
* NEXT  free-policy CLI tests; systemd units (guard + audit timer); docs; CI; restart/resume test.
* DONE  vps/free-install.sh + vps/systemd/llm-guard.service, llm-free-audit.service/.timer (dry-run default, 6 units, not enabled). tests/vps/free-install.test.sh 16/16. ShellCheck clean (found+fixed SC2034).
* DONE  Audit can log in with email+password from a 0600 env file (no stored token). Restart-recovery test (state file survives restart; corrupt state tolerated).
* DONE  docs/FREE-ONLY.md runbook; PROVIDERS-AND-COSTS.md "Verified 2026-10-30" section with sources; TESTING.md "Free-only layer"; CI runs tests/guard + free-install test.
* NEXT  full regression of existing suites; quota-report against live gateways; stop scratch gateways; push branch; final report. (VPS not accessed: no host/credentials in this environment.)
