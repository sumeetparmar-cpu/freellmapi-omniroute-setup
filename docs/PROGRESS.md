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

## 2026-10-30 (session 2: hardening)

* DONE  SECURITY: guard hardened. Header ALLOWLIST (strips x-omniroute-*, x-freellm-*, cookies, session, forwarding headers), Host-header check (DNS rebinding), status endpoint refused behind a reverse proxy,
        POST must be application/json, query string dropped, model must be a plain printable-ASCII string, n>1/best_of/extra_body blocked, `fusion` blocked, in-flight cap (16), server timeouts,
        write-through persistence of counters/cooldowns/rate windows, optional CLIENT KEYS (clients hold a guard key; the gateway key sits in a 0600 file they cannot read).
        tests/guard/security.test.mjs: 12 adversarial tests (40 bad model strings, 28 route tricks, smuggling, streaming, crash/restart quota) all pass.
* DONE  Live: gateway key useless through the guard, guard key useless against either gateway directly; both gateways + guards listen on 127.0.0.1 only; no TLS-verification bypass anywhere in the repo.
* CORRECTION  My earlier "no gateway/guard ports left listening" check used `ss`, which is not installed here, so it proved nothing; the scratch gateways were still running. Verified now via /proc/net/tcp.
* DONE  OMNIROUTE: genuine keyless ₹0 route found and verified live: custom OpenAI-compatible node (prefix `ovhanon`) -> OVH anonymous endpoint, connection with no API key. Real completion via client -> guard -> OmniRoute -> OVH.
        Policy `customNodePrefixes` + audit of provider nodes (wrong prefix/base URL/compatible connection without node => violation + kill flag); audit login via OMNIROUTE_ADMIN_PASSWORD. Built-in ovhcloud connector needs a key => not used.
* DONE  PRODUCTION: units verified with systemd-analyze (verify + security --offline: guard 2.9 / audit 2.9 OK; audit unit hardened from 5.0). Installer gained `--client-keys`. Privileged VPS suite 132/132 in the disposable container, no leftovers.
        Footprint measured: FreeLLMAPI 0.58 GB disk/~155 MB RSS, OmniRoute 2.8 GB/~610 MB RSS, guard ~61 MB each. No sandbox-path dependencies (git grep clean). Ubuntu 26.04: NOT runnable here; static review only.
* DONE  RELEASE tooling: scripts/make-release.sh (deterministic tar.gz + sha256, --verify from clean extraction under Node 24.11.0 = the pinned version). check-secrets.sh now works without .git and refuses a vacuous 0-file pass.
* NEXT  push, open PR with test report, build final archive. Deployment to the VPS: NOT performed (by instruction); runbook Stage I added.
* FIX   PR #1 CI `linux` job failed: tests/vps/free-install.test.sh had only ever run as root; its non-root fallback (copy script to a temp dir + chown) was broken. Reproduced locally as `nobody`
        (9 passed / 8 failed, same as CI), root-caused to the harness (relative source path, chown root:root), replaced with re-exec under `sudo -n` or explicit SKIP (never a pass).

## 2026-10-30 (session 3: completion work)

* DONE  Guard review: abuse run (aborted uploads, resets, mid-stream disconnects, stalled headers) => no crash, no leaked in-flight slots. FOUND+FIXED: SIGTERM with an open stream never exited (systemd would SIGKILL after 15 s) => graceful drain (5 s) + state flush;
        guard log was unbounded => 5 MB rotation. Regression tests added.
* DONE  Audit `--auto-fix` (FreeLLMAPI only, disable-only) so catalog drift cannot leave inference down; OmniRoute audit stays read-only.
* DONE  Monitoring: tools/free-status.mjs + monitor.sh guard/audit/kill-switch/quota checks (tests/vps/monitor-guard.test.sh, 9/9).
* DONE  Backup/recovery: FOUND that backups omitted the guard's client-key hashes (restore would lock clients out). Now included (hashes only; upstream key + audit credentials deliberately excluded). tests/vps/guard-backup.test.sh 16/16.
* DONE  CI: new `systemd-guard` job (real systemd) and ubuntu-24.04 + ubuntu-26.04 matrix for linux / vps-privileged / vps-e2e. ubuntu-26.04 is a GitHub-hosted runner (verified in actions/runner-images README).
* FIXED (CRITICAL) Full-file code review found that a 4-byte POST body `null` (valid JSON) crashed the guard (TypeError in an async handler => unhandled rejection => process exit). Under systemd, a few such requests would exceed StartLimitBurst and leave the unit
        permanently failed. Fix: bodies must be JSON objects (400 otherwise); catch-all around the request handler (500, never a crash); state-file shape validation; last-resort process handlers.
        Added: regression test, garbage-state-file test, and a deterministic 400-request FUZZ test whose invariant is "everything that reaches the gateway is policy-compliant" (mutation-checked: disabling the model check makes it fail).
* NOTE  Fuzz first reported ECONNRESETs: traced to Node's HTTP *client* sending GET/DELETE bodies without framing (desyncing keep-alive), not the guard; test client now sends Content-Length.
* DONE  Installer safety rails: `enable` refuses a guard whose key files are missing/empty (avoids crash-loop); re-running `units` without --client-keys over a hardened unit is refused unless --allow-downgrade. ShellCheck caught a bad `local` in my own edit. free-install test 24/24.
* CI    Real systemd validated on ubuntu-24.04 AND ubuntu-26.04: systemd-guard job 40/40 on both (first run 37/40: root-probe design flaw in my test, fixed). linux + windows green on both images.
* DONE  FINAL HEAD ffc8097 CI: push + pull_request runs both `success` (linux, systemd-guard, vps-privileged, vps-e2e on ubuntu-24.04 AND 26.04, windows). No reviews, no review threads.
* DONE  Docs corrected to match evidence: Ubuntu 26.04 and guard/audit real-systemd are now CI-verified; still unproven: gateway units under systemd, anything on the Hostinger VPS, real inference for the five keyed providers.

## 2026-10-30 (session 4: gateway units, preflight, interruptions)

* DONE  tests/vps/e2e-systemd.sh + CI job `e2e-systemd` (24.04 + 26.04): REAL deploy.sh + real installs with systemd in charge; reads cgroup v2 limits from the kernel, kill -9 recovery, independence, graceful stop leaves no process, StartLimit crash loop + documented recovery. (CI result at 92836e5: green on both images, 63/63 checks each.)
* DONE  Preflight: guard ports, ephemeral range, cgroup/container memory cap, overcommit, RAM left for neighbours, ro/noexec mounts, /tmp space, symlinked root, umask, foreign llm-* units (BLOCK), CA bundle, NTP, toolchain, DNS-vs-connect-vs-HTTP diagnostics. tests/vps/preflight-extra.test.sh 41/41 with negative controls + mutation-checked read-only scan.
* FOUND+FIXED (real defects, interrupted-state class): backup_paths ignored tar's exit status and wrote the final filename directly (a truncated archive was reported as success and chosen as "latest" for rollback); latest_backup could return a corrupt archive; _node_install skipped chown/chmod on an existing dir; SIGKILLed downloads left temp dirs; a half-finished git clone was mistaken for a complete checkout.
        tests/vps/partial-failure.test.sh 33/33; with the fixes reverted 15/33 FAIL (mutation-checked).
* LESSON  Three of my own tests were wrong in instructive ways: `cmd | grep -q` SIGPIPE-killed the command under test; a fixture smaller than the stall threshold made a "stall" test a no-op; killing one PID of a process tree is not a crash simulation. `pkill -f` from the tool shell killed the shell three times: never again.
* FOUND+FIXED (real defect, found by the new real-systemd job): `gwctl <gw> backup|restore|rebuild|rollback` restarted the service and returned before the gateway answered (an immediate health probe got HTTP 000). `with_stopped` now waits up to 120 s for health and fails loudly if it never comes back.
* LESSON  First e2e-systemd run: 54/60. Four were harness bugs of mine (cgroup checks read the cgroup ROOT because of a quoting bug and had never really verified the limits; the crash-loop test never killed anything). Fifth was an assertion on `Result=start-limit-hit`, which systemd 255 AND 259 do not report (they log "Start request repeated too quickly" and end `failed`); replaced with: unit failed + start-limit refusal in the journal + no respawn / unchanged NRestarts over 12 s.
* DONE  e2e-systemd at 92836e5 (GitHub runners, REAL systemd; ubuntu-24.04 = systemd 255, ubuntu-26.04 = systemd 259, cgroup v2, kernel 7.0): real deploy.sh + both real installs; memory.max 1 GiB / 2 GiB, memory.high < max, cpu.max 80000 100000, pids.max 512 read from the kernel; kill -9 of each gateway => new PID, healthy, other gateway's PID unchanged; stop leaves no process of the service user; independent start/stop; StartLimitBurst crash loop ends `failed` and the documented `reset-failed` + `start` recovers; verify.sh and monitor.sh against live units.
        NOT proven: anything on the Hostinger VPS; behaviour under real load or OOM; host reboot persistence.
* NEXT  release archive for the final head; PR description refresh.
