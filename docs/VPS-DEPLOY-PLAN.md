# VPS deployment plan: ARCHITECTURE C FIRST (OmniRoute + its guard, OVH anonymous inference only)

Status: PREPARATION ONLY. Nothing in this document has been run on the VPS. Deployment needs the owner's explicit approval at each gate (G0-G8 below). Facts about the VPS come from the owner's forensic report summary; measurements marked "cloud" were taken on an x86_64 Linux sandbox with the same pinned Node and OmniRoute versions, NOT on the VPS.

## 1. Decision and architecture
Owner's decision after the forensic inspection: architecture **C**.
* Deploy: **OmniRoute 3.8.52** (loopback `127.0.0.1:20128`) + its **free-only guard** (`127.0.0.1:20228`) as isolated systemd units under their own user `llmomni` and `/srv/llm`.
* Inference: the keyless OVH anonymous route only (custom OpenAI-compatible node prefix `ovhanon` + ONE keyless connection, `termux/lib/provision.mjs omniroute`, proven on the phone: OmniRoute 120B fixed both phone coding tasks). No API key, no account, no paid provider, no fallback; the guard allowlist refuses any other model (HTTP 403).
* NOT deployed now: a second FreeLLMAPI (future optional stage, section 9). The existing `suppar-freellmapi` container (v0.16.10, `127.0.0.1:3001`, 384 MiB limit, `/opt/suppar-tools/freellmapi`, volume `freellmapi-data`) is not touched, not reused, not referenced.
* Every listener binds 127.0.0.1 (verified in the units, `deploy.sh` config, guard `--listen`; CI test `e2e-systemd` checks loopback binding of the gateways).

### Code changes made for C (this repo, CI-tested, nothing deployed)
* `--only omniroute` for `deploy.sh` and `preflight.sh`; the choice is persisted as `GATEWAYS=omniroute` in `/srv/llm/deploy.conf`, and `free-install.sh`, `verify.sh`, `monitor.sh` read it, so FreeLLMAPI is never created (no `llmfree` user, no `/srv/llm/freellmapi`), installed, enabled, verified, monitored or port-checked (port 3001 is not even looked at). Installing/enabling the unselected gateway is refused. Default (both gateways) behaviour is unchanged. 17 new tests (`tests/vps/only-omniroute.test.sh`) + the 99 existing VPS tests pass.
* `OOMScoreAdjust=500` added to the gateway and guard units: if the host ever runs out of memory (0 swap, Ollama ~3.5 GiB), the kernel picks the toolkit's processes before Ollama/n8n/SUPPAR.
* The survey now also reports n8n/5678 exposure and a CPU/load sample (`--forensic`).

## 2. Resource budget (exact where measured)
Host (owner-reported): 2 CPUs, 7,935 MB RAM, 2,523 MB available, 0 swap, 16 GB disk free, load 1.98. Neighbours: Ollama ~3.53 GiB, n8n ~488 MiB.
| Item | Measurement (cloud x86_64, Node 24.11, OmniRoute 3.8.52) | Cap in the unit |
|---|---|---|
| OmniRoute RAM idle | 557 MiB (2 processes) | `MemoryHigh` 1536M, `MemoryMax` 2G |
| OmniRoute after 2 real requests | 586 MiB | same |
| OmniRoute under systemd (CI, earlier) | 704-712 MiB | same |
| OmniRoute guard | 58-59 MiB | `MemoryMax` 192M |
| CPU idle | about 1% of one core | `CPUQuota` 80% |
| **Steady state total** | **about 0.62-0.78 GiB** (use 0.8 GiB for planning) | |
| Disk: OmniRoute install | 2,804 MB (`node_modules` 2,803 MB) | |
| Disk: npm cache during install | up to 1,238 MB in the cloud run (under `/srv/llm/omniroute/home/.npm`; can be deleted after install) | |
| Disk: pinned Node runtime | about 190-200 MB | |
| Disk: data/logs/state | under 10 MB at start | |
| **Disk total** | **about 3.0 GB after cache cleanup, about 4.3 GB peak** (preflight requires >= 6 GB free; 16 GB reported) | |
| **Install (measured, cloud, `omniroute.sh install` with the pinned 3.8.52)** | peak **1,374 MiB** (sum of node + npm RSS, 1 s sampling), wall time **about 137 s** on a fast link, exit 0, no `node-gyp` activity (prebuilt binaries used) | scope cap `INSTALL_MEM_MAX` (default 2G) |
**Headroom (computed from the owner's figures, not measured on the VPS):** 2,523 MB available - about 800 MB steady = about 1.7 GB left for Ollama growth and n8n bursts. This is acceptable only because the units are capped, `OOMScoreAdjust=500` makes them the first victim, and the install is run with a memory cap (below). No swap means there is no cushion: do not start G4 unless `MemAvailable` is at least 2.5 GB at that moment (install peak 1.37 GiB measured in the cloud). Ollama releases its model memory when idle (default keep-alive 5 minutes), so a quieter moment may show more, but that is not verified for this VPS.

## 3. Is the system suitable right now? (n8n CPU 97.35%)
Verified: load average 1.98 on 2 CPUs means both cores were close to saturated at inspection time, and n8n's single `docker stats` sample read 97.35% (of one core). I cannot see why from here: a single sample is not a measurement (docker's one-shot CPU figure covers a very short window and can catch a burst such as a running workflow, a scheduled trigger, an execution backlog or an update). Likely candidates, unverified: a long-running or looping workflow, a polling trigger, or the task runner busy. The survey now includes a 3-sample CPU table, two `docker stats` samples, `vmstat` and kernel pressure (PSI) so the answer is evidence, not a guess.
**Decision rule for G4:** do not start the install while the 1-minute load average is above 1.5 on these 2 CPUs or CPU pressure (`/proc/pressure/cpu` `some avg60`) is above about 20; wait for a quiet period. The install is niced (19), idle I/O class and in a systemd scope with `CPUWeight=20`, so SUPPAR/n8n win under contention, but a saturated 2-CPU box makes the npm install slow (it is mostly network + file writes) and risks timeouts in n8n workflows meanwhile. Steady-state use is negligible CPU (about 1% idle; inference is remote at OVH).

## 4. Security assessment
* **Network**: OmniRoute, its guard: loopback only; no firewall change needed or made; no Caddy change; first use through an SSH tunnel. Docker containers cannot reach the host's `127.0.0.1` (known limitation: SUPPAR/EARNIX/n8n would need a separate, separately approved route to call the guard).
* **Isolation**: own system user (no login shell, no sudo, no docker group), own `/srv/llm` tree 0700, systemd sandbox (`NoNewPrivileges`, `ProtectSystem=strict`, `ReadWritePaths` limited, `RestrictAddressFamilies`), `MemoryMax`/`CPUQuota`/`TasksMax`.
* **Free-only**: guard allowlist (only OVH models), per-model rate limit (2/min), client keys (the upstream OmniRoute key never leaves the guard), audit timer + kill switch. No provider key is ever entered.
* **Data sent to OVH**: prompts go to OVH's anonymous endpoint (no account); do not send secrets or customer data.
* **Residual**: OVH's anonymous tier has no SLA and may change; first-run account creation in OmniRoute (do the tunnel step before anything else is exposed); the toolchain warning (section 7).
* **n8n 5678**: separate finding, see `docs/VPS-N8N-EXPOSURE.md`; not changed by this plan.

## 5. Deployment (each gate = a separate explicit "yes"; dry run first at every changing step)
All commands run on the VPS as root from the extracted release archive (`/root/llm-deploy/llm-toolkit` below).
| Gate | Command(s) | Writes to |
|---|---|---|
| **G0** prerequisite | **Hostinger snapshot** in hPanel (cannot be verified from here). Record its name/time. No snapshot = no G3+. | Hostinger |
| **G1a** archive | On a computer (not the VPS): `scripts/make-release.sh --out release --verify` at a CI-green commit; `scp release/llm-toolkit-*.tar.gz{,.sha256} root@VPS:/root/`; on the VPS `sha256sum -c llm-toolkit-*.tar.gz.sha256`. No GitHub credentials ever on the VPS. | `/root/` (2 files) |
| **G1b** gate files | `mkdir -p /root/llm-deploy && tar -xzf /root/llm-toolkit-*.tar.gz -C /root/llm-deploy && cd /root/llm-deploy/llm-toolkit-*` then `./vps/preflight.sh --only omniroute --omniroute-port 20128 --out /root/llm-deploy/preflight.txt` and `./vps/inventory.sh snapshot --out /root/llm-deploy/baseline.snap --hash /etc/caddy/Caddyfile --hash /opt/suppar-tools/freellmapi/docker-compose.yml --watch /opt/suppar-tools/freellmapi` (add every other compose/config file and data dir of n8n/SUPPAR/EARNIX from the survey's Docker section). Required: `RESULT: PASS*` (the toolchain warning is expected). | `/root/llm-deploy/*` (0600) |
| **G3** layout | Dry run: `./vps/deploy.sh --only omniroute prepare --preflight /root/llm-deploy/preflight.txt --baseline /root/llm-deploy/baseline.snap --omniroute-port 20128`; read it; then the same with `--apply`. Creates user `llmomni`, `/srv/llm`, pinned Node 24.11.0 (sha256-verified), a read-only toolkit copy, `deploy.conf` (`GATEWAYS=omniroute`, `PORT_OMNIROUTE=20128`, `BIND_HOST=127.0.0.1`). | `/srv/llm`, 1 user |
| **G4** install | **Only when load < 1.5 and MemAvailable >= 2.5 GB** (install peak measured at 1.37 GiB; the reported 2,523 MB is exactly at that threshold, so re-check at that moment). `INSTALL_MEM_MAX=1800M ./vps/deploy.sh --apply install omniroute` then `./vps/deploy.sh --apply units` (renders + `systemd-analyze verify` + installs `llm-omniroute.service`, starts nothing). Afterwards optional cache cleanup: `rm -rf /srv/llm/omniroute/home/.npm`. If the install fails on a missing native toolchain, STOP and ask (section 7). | `/srv/llm/omniroute`, 1 unit file |
| **G5** start + verify | `./vps/deploy.sh --apply enable omniroute --baseline /root/llm-deploy/baseline.snap` (waits up to 120 s for `/api/health/ping`; runs `verify.sh`; a failure disables it again automatically). | enablement of 1 unit |
| **G6** OVH route (no key) | `./vps/gwctl.sh omniroute credentials` (shows the generated admin password once; change it later). Then, as the service user: `runuser -u llmomni -- env GW_HOME=/srv/llm/omniroute /srv/llm/runtime/node/bin/node /srv/llm/toolkit/termux/lib/provision.mjs omniroute --base http://127.0.0.1:20128 --env-file /srv/llm/omniroute/config/omniroute.env --key-out /srv/llm/omniroute/config/free-guard.upstream.key` (creates the `ovhanon` node + one keyless connection; stores a gateway key for the guard; prints no secret; idempotent). | OmniRoute DB, 1 key file (0600) |
| **G8** guard | `./vps/free-install.sh --only omniroute units --client-keys` (dry run) then `--apply`; mint a client key as in `docs/VPS-DEPLOYMENT.md` Stage I (`free-guard.mjs --new-client-key phone --client-keys-file /srv/llm/omniroute/config/free-guard.clients`); `./vps/free-install.sh --apply enable omniroute`. | 3 unit files, key files |
| **later** | `./vps/deploy.sh --apply timers` then `systemctl enable --now llm-monitor.timer llm-backup@omniroute.timer` after review (read-only monitor every 5 min, weekly backup). | timer units |

## 6. Validation tests (after G8; all read-only or one tiny inference)
1. `./vps/verify.sh --baseline /root/llm-deploy/baseline.snap` : existing containers, volumes, networks, unit files, users and hashed configs identical; `llmomni` owns nothing outside `/srv/llm`, is in no extra group, only loopback sockets.
2. `./vps/inventory.sh compare /root/llm-deploy/baseline.snap` : exit 0 (only our own users/units/ports ignored).
3. `ss -ltnp | grep -E ':(20128|20228)\b'` : both `127.0.0.1` only; `ss -ltn | grep -c ':3001 '` unchanged (the SUPPAR container still published on 127.0.0.1:3001).
4. `docker ps` : same 10 containers, `suppar-freellmapi` still `healthy`, uptime not reset.
5. Guard: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20228/__guard/status` = 200; a request with a forbidden model (`gpt-4o`) = 403 `model_blocked`; no client key = 401/403.
6. One real completion through the guard with the client key, model `ovhanon/gpt-oss-120b` (same call as on the phone): HTTP 200 and tokens reported; `./vps/gwctl.sh omniroute test-model --model ovhanon/gpt-oss-120b` equivalent. Wait 30 s between tries (OVH 2 requests/minute).
7. `systemctl show llm-omniroute -p MemoryCurrent,MemoryMax,OOMScoreAdjust`; `free -m` before/after: Ollama and n8n RSS unchanged within noise.
8. OpenCode on the VPS is optional; on the phone, add the VPS only through an SSH tunnel, never an open port.

## 7. Warnings and prerequisites
* **Toolchain warning, reviewed for the OmniRoute-only install** (exact text: "no native build toolchain (make + g++/gcc + python3): fine when npm finds prebuilt binaries for x86_64/glibc 2.43, but a native module without one would fail to build"). Findings from the installed OmniRoute 3.8.52 tree and a measured experiment:
  * `better-sqlite3` is an optional dependency of OmniRoute and **ships its binaries inside the package** (`prebuilds/linux-x64.node`, plus 7 other platforms; no `build/` directory, no install script). OmniRoute's own `postinstall` copies the matching prebuild ("no rebuild or build tools needed", per its source). Nothing is compiled or downloaded for it.
  * `keytar` (optional) tries `prebuild-install` first and compiles only if that fails; an optional dependency that fails to build does not fail the npm install. `@parcel/watcher` only compiles with `npm_config_build_from_source=true`; its prebuilt `@parcel/watcher-linux-x64-glibc` package is installed. OmniRoute's native `transparent.node` ships prebuilt in `dist`.
  * **Experiment (cloud x86_64, glibc 2.39, Node 24.11, same pinned versions): `omniroute.sh install` with gcc, g++, cc, c++, make and python3 removed from PATH: exit 0, zero `gyp ERR`, then `omniroute.sh start` served `/api/health/ping` = 200 and created `storage.sqlite`** (the native SQLite module loaded). So for the OmniRoute-only install the warning has no practical impact on x86_64/glibc. It is not a measurement on your VPS (glibc 2.43, Node 24.11 from the pinned tarball): residual risk is a different glibc/N-API combination, in which case the install or start fails safely and nothing is enabled. Do NOT install build tools (the warning stays informational).
  * It matters for the future FreeLLMAPI stage only: FreeLLMAPI's `better-sqlite3` 12.x downloads its prebuilt binary via `prebuild-install` and would compile only if that download is missing.
* **Hostinger snapshot** (G0): unverified.
* **n8n 5678 exposure**: independent, see its own document.
* **Gate files**: the survey leaves none; G1b creates them.
* **Caddy / Docker networking**: nothing here exposes the guard; SUPPAR/EARNIX/n8n inside Docker cannot reach the host loopback.

## 8. Rollback (smallest first; none touches existing services)
1. Stop only ours: `systemctl disable --now llm-guard-omniroute.service llm-free-audit-omniroute.timer llm-omniroute.service` (or `./vps/free-install.sh --apply remove omniroute` and `./vps/deploy.sh --apply remove omniroute`; both stop and delete only our unit files; data kept).
2. Undo the install completely: `./vps/deploy.sh --apply remove omniroute --purge --yes-delete-data` (deletes only `/srv/llm/omniroute` and user `llmomni`); then remove `/srv/llm` and `/root/llm-deploy` by hand if you want nothing left.
3. Verify nothing else changed: `./vps/inventory.sh compare /root/llm-deploy/baseline.snap`.
4. Last resort only: restore the Hostinger snapshot (G0): this reverts the WHOLE VPS, including other services' data since the snapshot.
Failed steps abort by themselves; `enable` auto-disables a service that is unhealthy or fails verification.

## 9. Monitoring
* `llm-monitor.timer` (5 min, read-only): unit active, health endpoint, memory vs cap, load vs CPUs, disk, guard kill switch, audit failures, cooldowns, quota vs caps; exits non-zero on CRIT.
* Manual: `./vps/monitor.sh`, `./vps/free-install.sh status`, `journalctl -u llm-omniroute -u llm-guard-omniroute --since -1h`, `systemctl show llm-omniroute -p NRestarts,MemoryCurrent`.
* Alert yourself on: `NRestarts` increasing, `MemoryCurrent` near 1.5 GiB, kill-switch engaged (`state/free-audit.flag`), any `/proc/pressure/memory some avg60` above 10.

## 10. Future optional stage: a separate FreeLLMAPI
Only after C has run stably and with fresh approval: `preflight.sh --freellmapi-port 13001`, then `deploy.sh prepare/install/enable freellmapi` with `--freellmapi-port 13001` (this converts the deployment to both gateways: remove `GATEWAYS=omniroute` from `deploy.conf`, or set it to `both`). Cost: about +65-81 MiB RAM (CI) and one more install on disk; isolation from `suppar-freellmapi` is complete (own user, port, data). Reuse of the existing container behind the guard is rejected: no attach mode in the scripts, the FreeLLMAPI audit `--auto-fix` could disable models SUPPAR uses, and adding the OVH route changes SUPPAR's gateway database.

## 11. Readiness
Ready to proceed to G0 (snapshot) and G1; not ready to install until: the snapshot exists, the quiet-period/load/memory conditions in section 3 hold, and the owner approves each gate. Evidence still missing from the VPS: the CPU/load sample and the n8n exposure facts (the extended `--forensic` survey collects them in one command). The survey MUST be run with `--only omniroute` for architecture C:
```
bash vps/remote-survey.sh root@VPS_ADDRESS --forensic --only omniroute --omniroute-port 20128
```
**Correction (survey defect found by the owner's run):** the previous survey always ran the dual-gateway preflight, so the occupied port 3001 (the existing SUPPAR FreeLLMAPI) was reported as the only blocker (44 passed, 2 warnings, 1 blocker). `remote-survey.sh` now takes `--only omniroute|freellmapi` and passes it through to `preflight.sh`; without it the survey stays dual-gateway. Regression tests (`tests/vps/only-omniroute.test.sh`, 29 checks) prove: occupied 3001 BLOCKs the default survey, does NOT block `--only omniroute`; the saved configuration (`deploy.sh --only omniroute showconf`) contains `GATEWAYS=omniroute`, `PORT_OMNIROUTE=20128`, `BIND_HOST=127.0.0.1` and no FreeLLMAPI port, ref or path; the default configuration is unchanged (`GATEWAYS=both`, both ports).
**Load gate:** the survey reported a load average of 2.33 on 2 CPUs (earlier 1.98). That is above the 1.5 limit in section 3, so G4 (install) must NOT start now; re-check load at the moment of G4.
