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
| Termux scripts | `bash tests/termux/run-tests.sh` | **74 passed, 0 failed** |
| Secret scanner | `bash tests/termux/test-check-secrets.sh` | **11 passed, 0 failed** |
| PowerShell scripts (pwsh 7.5 on Linux) | `pwsh -File tests/windows/run-tests.ps1` | **65 passed, 0 failed** |

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
