# Testing: what was verified, what was not

Test date: 2026-10-29. Environment: Ubuntu 24.04 container (x86_64, 16 GB RAM), Node 22.22.0 and 24.11.0,
npm 10.9.4 / 11.6.1, PowerShell 7.5.0 (Linux build), ShellCheck. Upstream versions: FreeLLMAPI `36826e7`
(v0.16.12) and `26a50fc` (v0.16.11); `omniroute@3.8.52` and `@3.8.50`.

**Not tested on Android/Termux, not tested on Windows, not tested on your devices.** Treat the toolkit as
"works on Linux, written to be portable", and run the checks in the last section on each device.

## Automated suites (run offline, no installs, no real secrets)

| Suite | Command | Result |
|---|---|---|
| ShellCheck (`-S warning`) on all `.sh` | `shellcheck -x -S warning termux/*.sh termux/lib/common.sh tests/termux/*.sh scripts/*.sh` | clean |
| PowerShell parser on all `.ps1` | `[Parser]::ParseFile(...)` | 0 errors |
| Termux scripts | `bash tests/termux/run-tests.sh` | **89 passed, 0 failed** |
| `quota-report` reporter (Node 24 and Node 22.22.0) | `node --test tests/quota/quota-report.test.mjs` | **22 passed, 0 failed** (also run inside the bash suite) |
| Secret scanner | `bash tests/termux/test-check-secrets.sh` | **11 passed, 0 failed** |
| PowerShell scripts (pwsh 7.5 on Linux) | `pwsh -File tests/windows/run-tests.ps1` | **75 passed, 0 failed** |

What they cover: Node-range logic (incl. the 22.22.0 / 23.x gaps), port conflict/equality/range checks, env-file
permissions and non-executing parsing, backup/restore round-trip, restore path allow-listing (`..`, foreign paths,
zip-slip), PID-reuse guard, process-tree stop (parent + child), model test against a mock (success, 429, empty reply,
bad key, unreachable), API-key sourcing, CLI behaviour (help, unknown action, refuse start before install, equal ports,
Node-ABI guard, `--model` required for OmniRoute), audit exit codes, and the secret scanner's true/false positives.

`PSScriptAnalyzer` and `Pester` were **not run**: the PowerShell Gallery is blocked in the test sandbox. The suite is
dependency-free instead.

## Live integration runs (real upstream software, Linux)

Both gateways were installed through the scripts and run **at the same time** on their separate ports.
No real provider key was used. Where a model reply was needed, a **local mock OpenAI server**
(`tests/mock-openai-server.mjs`) was registered as the upstream provider, so the full chain
*script → real gateway → mock upstream* was exercised without spending anyone's quota.

| Step | FreeLLMAPI (bash) | FreeLLMAPI (PowerShell) | OmniRoute (bash) | OmniRoute (PowerShell) |
|---|---|---|---|---|
| install (clone/npm + build) | ✅ ~46 s | ✅ | ✅ ~2.4 min (Node 24) | ✅ |
| env file owner-only (checked with `stat`) | ✅ 600, dir 700 | ✅ 600 | ✅ 600 | not checked |
| start, and listener inspected: bound to `127.0.0.1` only | ✅ | not inspected | ✅ | not inspected |
| health (liveness, anonymous `/v1/models` → 401) | ✅ | ✅ | ✅ | ✅ |
| `test-model` with a wrong key → clean failure | ✅ | ✅ | not run | not run |
| `test-model`: real gateway → mock upstream → `OK` | ✅ | ✅ | ✅ | ✅ |
| explicit `backup` + `restore` commands on real archives (stale file in data dir removed; stored keys still authenticate; model reply OK after) | ✅ | `backup`/`list-backups` only | ✅ | `backup` via `update` only |
| `update` to older release → mutate state → `rollback --with-data` (which restores the pre-update archive) | ✅ v0.16.11 | ✅ | ✅ 3.8.50 | ✅ 3.8.50 |
| …state really reverted (regenerated key / extra dashboard key gone, version back) | ✅ | ✅ | ✅ | ✅ |

Also verified (bash): both gateways running concurrently on 3001 + 20128 (stopping one left the other
healthy); the script refuses OmniRoute install under Node 22.22.0; Node-ABI guard and `rebuild` (Node 22 build →
Node 24 run); stop leaves no orphan process and frees the port.

### Defects the live runs found (all fixed, now covered by tests)

1. `test-model` lost the request body (key config and body both used curl's stdin) → HTTP 400 "messages: Required".
2. `http_code` printed `000000` on connection failure (curl's `-w` plus a fallback `000`).
3. OmniRoute 3.8.50 rejects `serve --headless`; the flag was redundant with `OMNIROUTE_HEADLESS=1`, so it was removed.
4. **Stop left an orphaned OmniRoute server**: the CLI is a supervisor that respawns its server child, and older
   builds ignore SIGTERM once orphaned. Rollback then restored the DB underneath a live process. Fixed in both
   platforms (stop parent first, snapshot descendants, wait, force-kill survivors, verify the port is free).
5. PID-reuse guard compared process names (`MainThread` on Linux) and then exact start times (jitter) → now start time with 2 s tolerance.
6. A Node switch after build crashed FreeLLMAPI with `NODE_MODULE_VERSION` mismatch → now detected, with a `rebuild` action.
7. Termux restore only rejected `..`; now restricted to the gateway's own config file and data directory.
8. Secret scanner never matched `-----BEGIN … PRIVATE KEY-----` (grep read the pattern as an option).
9. PowerShell `$null` env restore left an empty variable on Unix; now removes the variable.
10. Restore left stale files in the data directory (a newer version's SQLite `-wal` could be replayed against the older DB). Restore now replaces the data directory wholesale, and `rollback --with-data` takes a `pre-rollback` backup first.

### Other observations

* OmniRoute `model=auto` on a fresh install routed to a keyless browser provider and returned 503 → test requires an explicit model.
* FreeLLMAPI calls out to `api.freellmapi.co` for its signed catalog (12 h poll). In the sandbox this failed (`fetch failed`) without affecting the gateway.
* The sandbox injects `HTTPS_PROXY`; FreeLLMAPI logs "[proxy] Configured …". Not relevant on your devices unless you set a proxy.

## Not verifiable here (needs you or CI)

| Item | Why | How to check |
|---|---|---|
| Everything on **Android/Termux** (package names, Node version offered by `pkg`, `node:sqlite` on-device, `termux-wake-lock`, F-Droid build, setsid/process groups under Android, RAM pressure) | No Android device or emulator available | `./termux/audit-env.sh`, then the install/start/health sequence in README. If `pkg install nodejs` gives Node < 22.22.2 the audit blocks OmniRoute. |
| Everything on **Windows** (`icacls` ACL hardening, `Start-Process -WindowStyle Hidden`, `Get-CimInstance` child lookup, `.cmd` npm shims, long paths, Defender/SmartScreen/firewall prompts, Windows PowerShell **5.1** semantics, `better-sqlite3` prebuilt vs build tools) | Only PowerShell 7.5 on Linux was available | `.\windows\audit-env.ps1`, then `tests\windows\run-tests.ps1` in both `powershell` (5.1) and `pwsh`. `.github/workflows/test.yml` runs both on `windows-latest`; that workflow has **not** been run. |
| Real provider traffic (quotas, 429 handling, ToS) | No provider keys were used or requested | `test-model` with your own keys; see [PROVIDERS-AND-COSTS.md](PROVIDERS-AND-COSTS.md). |
| `npm`'s `--allow-scripts` path on npm 11 for OmniRoute | Exercised on npm 11.6.1 (Node 24) and worked; npm 10 path also worked | – |
| Latest upstream versions after 2026-10-29 | Upstreams move fast | Re-run the suites after `update`; pin versions. |

## Reproduce locally

```bash
bash tests/termux/run-tests.sh
bash tests/termux/test-check-secrets.sh
pwsh -NoProfile -File tests/windows/run-tests.ps1
# optional live run with throwaway state and different ports:
GW_HOME=$(mktemp -d) FREELLMAPI_PORT=3201 OMNIROUTE_PORT=20228 ./termux/freellmapi.sh install   # etc.
```

## quota-report

Added after the first report. Covered by `tests/quota/quota-report.test.mjs` (22 tests) plus wrapper tests in both suites, all
against **mock** status endpoints (`tests/quota/mock-gateways.mjs`): success, missing quotas, authentication errors (wrong credential,
server-side 401, no credential), HTTP 429 with `Retry-After` (no retry), malformed JSON, wrong-typed JSON, stale ledger / expired
windows / old caches, redirects, unreachable gateway, and argument validation. Every scenario also asserts: only `GET`, only allow-listed
paths, no generation path, every line carries one of the four labels, `modelRequestsSent: 0`, and **no credential or planted
canary secret appears in text or JSON output**. Shared pools are counted once, and estimates never appear in provider-reported lines.

Also run once against the **real** sandbox instances (FreeLLMAPI v0.16.12 and OmniRoute 3.8.52 with a read-scope token, mock provider
only): response shapes matched, and the token did not appear in the output. This is **not** evidence about any real provider quota:
no real provider was ever connected, so provider-reported quota has only been exercised with mock data.

Findings from that run, now handled: OmniRoute withholds month-to-date usage from access-token callers (reported Unknown; the rolling
30-day analytics are used instead); the unauthenticated health endpoint omits the version (not printed); `scrub()` was mis-called with a
length argument (fixed); PowerShell treated redirected stdin as interactive (new `Test-Interactive`); a startup race in the port test.

## VPS toolkit (`vps/`)

Tested on a disposable Linux sandbox (Ubuntu 24.04 container, no systemd running, root). **Not run on a real VPS, not on Ubuntu 26.04.**

| Suite | Command | Result |
|---|---|---|
| Part A: no privileges (library, preflight, inventory/integrity, unit templates, deploy gates and dry-run, backup pruning, monitor, gwctl safety, static safety scan) | `bash tests/vps/run-tests.sh` | **96 passed, 0 failed** |
| Part A + B: **real** users, directories, units, isolation, verify.sh, gwctl update/rollback with fake toolkit | `sudo LLM_TEST_ALLOW_SYSTEM_CHANGES=1 bash tests/vps/run-tests.sh` | **131 passed, 0 failed** |
| End-to-end rehearsal: real pinned Node download (SHA-256 checked), both gateways installed as separate users, started, health-checked, verified, `put-key`, `test-model` (through the real FreeLLMAPI to a local mock), `quota-report` on both, backup, scheduled backup, purge | `sudo LLM_TEST_ALLOW_SYSTEM_CHANGES=1 bash tests/vps/e2e-sandbox.sh` | **39 passed, 0 failed**; sandbox left with no users, dirs, processes |

Part B and the rehearsal refuse to run without root **and** `LLM_TEST_ALLOW_SYSTEM_CHANGES=1`, because they create real accounts. They are meant for CI runners and sandboxes.

What the real runs demonstrated (not just asserted): service users are system accounts with no login and no group but their own; each gateway's directory is unreadable by the other's user; the toolkit copy is not writable by either; a stray file, a privileged group, a non-loopback socket and a loopback socket on an unexpected port are each detected by `verify.sh`; the OmniRoute service ran on the pinned Node 24 (the system Node 22.22.0 would have been refused); secrets are generated server-side (0600) and never appear in the deploy log, `quota-report` output, or the process list; update with an unhealthy result rolls back automatically; `remove --purge` deletes only one gateway.

Defects found by these tests and fixed: the preflight's "propose a free port" call passed the alternatives as one argument (proposed nothing); `act` did not abort when a step failed, so a failed checksum would not have stopped the install (now every failed step ends the run); `systemd-analyze verify` rejects a temp file without a `.service` suffix, which would have broken the `units` step; the static safety scan initially matched nothing at line start or inside `act "…" cmd` calls (caught by a planted-violation meta-test, now fixed).

Not verifiable here: Ubuntu 26.04; real systemd start/stop/restart/cgroup limits/`KillMode` (units are checked with `systemd-analyze verify` and unit-tested only; the rehearsal used `LLM_NO_SYSTEMD=1`, and its preflight "no systemd" blocker was overridden on purpose because the container has none); behaviour next to real Docker/Caddy/n8n/SUPPAR/EARNIX (docker and systemctl are shims in Part A); the Hostinger environment (CPU, RAM, disk, existing ports); Windows and Android for anything in `vps/`.
