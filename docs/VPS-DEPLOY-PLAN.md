# VPS deployment plan (DRAFT: prepared before the survey output was seen; nothing here has been run on the VPS)

Inputs reported by the VPS owner (NOT verified by this repo's tools yet): root SSH works; Ubuntu 26.04.1 LTS; `127.0.0.1:3001` is already published by an existing Docker container (docker-proxy PID 2177) that must not be stopped, restarted, modified, removed or recreated.

## Port map (toolkit only; the existing container keeps 3001)
| Component | Port | Bind | Why |
|---|---|---|---|
| FreeLLMAPI | **13001** | 127.0.0.1 | 3001 is taken by the existing container; 13001 is in the toolkit's own alternative list |
| OmniRoute | 20128 | 127.0.0.1 | unchanged |
| FreeLLMAPI guard | 3101 | 127.0.0.1 | unchanged |
| OmniRoute guard | 20228 | 127.0.0.1 | unchanged |

How 13001 reaches everything without editing defaults (the shared defaults stay 3001 so the phone setup and CI tests are untouched): `deploy.sh --freellmapi-port 13001` writes `PORT_FREELLMAPI=13001` to `/srv/llm/deploy.conf`; the gateway unit, the guard's upstream (`free-install.sh` reads the same file), `verify.sh` and `monitor.sh` all read that file. `preflight.sh --freellmapi-port 13001` checks it first.

## Read-only step now (one command from the phone, nothing written on the VPS except a temp dir that is deleted)
```
bash vps/remote-survey.sh root@VPS_ADDRESS --freellmapi-port 13001 --omniroute-port 20128
```
Reports: OS/RAM/disk, listeners (bind addresses of 13001/20128/3101/20228/3001), running services, **who owns port 3001** (container name, image, status, port mappings, compose project/service/working dir/config files, restart policy, memory limit: labels and state only, no environment variables), firewall listing, the toolkit preflight with the 13001 port, and an inventory snapshot. Required result before anything else: `RESULT: PASS` (warnings reviewed) and 13001/20128/3101/20228 free.

## Strategy decision: reuse the existing FreeLLMAPI (A) or a second instance on 13001 (B)?
Reported by the owner (not verified by this repo): Ubuntu 26.04.1, 2 CPUs, RAM 7,935 MB total / 2,523 MB available, swap 0, disk free 16 GB, load 1.98, 10 containers / 17 volumes, nft firewall active; container `suppar-freellmapi` Up 4 days (healthy) on `127.0.0.1:3001`, Compose file `/opt/suppar-tools/freellmapi/docker-compose.yml`; 13001/20128/3101/20228 free.

**What the repo's scripts/units prove about reuse (verified in code):**
* `deploy.sh config` refuses a port that is already in use by something else, and the guard + audit units are rendered for `/srv/llm/<gw>` with the service user `llmfree`, an upstream key file `free-guard.upstream.key` and `free-audit.env` credentials. There is no "attach to an existing gateway" mode: reuse needs new code, not just a flag.
* The audit unit for FreeLLMAPI runs with `--auto-fix`: it logs in with admin credentials and DISABLES models it cannot verify as free. Pointed at the existing instance, that would change SUPPAR's own gateway settings (models SUPPAR may rely on).
* Zero-cost OVH inference needs a custom endpoint added inside the gateway (its database). Doing that on the existing instance modifies a production service's data.
* The guard itself only needs an HTTP upstream (127.0.0.1:3001 would be reachable from the host, since the container publishes to loopback), so the proxy part would technically work; the surrounding provisioning/audit does not.

**Comparison (resource figures are CI measurements and the units' caps, NOT measurements on this VPS):**
| | A: reuse :3001 behind guard | B: second FreeLLMAPI on :13001 |
|---|---|---|
| Existing services touched | yes: needs the production gateway's admin credentials, a new custom endpoint in its DB, audit `--auto-fix` may disable models SUPPAR uses | no |
| Extra RAM (FreeLLMAPI part) | ~0 | ~65-81 MiB resident (CI), cap `MemoryMax` per unit file |
| Whole new stack RAM | OmniRoute ~705-712 MiB + 2 guards | + FreeLLMAPI ~65-81 MiB; ~0.9 GiB typical, ~1.2 GiB at the unit caps, against 2,523 MB available and no swap |
| Disk | OmniRoute + guards | + one FreeLLMAPI install (preflight requires >= 6 GB free; 16 GB reported) |
| Scripts support it today | no (needs code + approval) | yes (`--freellmapi-port 13001`, tested in CI) |
| Blast radius if it goes wrong | SUPPAR's gateway | only `/srv/llm` services |

**Recommendation: B**, because A saves only ~65-81 MiB of RAM (about 3% of the available memory) but is the only option that modifies a service that is working. Even lower resource option, if wanted: **C, OmniRoute + its guard only** (OmniRoute alone reaches OVH anonymous through the `ovhanon` node), skipping the second FreeLLMAPI. Reuse is preferred wherever it is technically safe: the existing Docker daemon, Caddy and the system tools are reused unchanged (the toolkit installs its own pinned Node under `/srv/llm`, never system packages). The existing FreeLLMAPI container stays exactly as it is.

**Practical risks for B (reasoned from the reported numbers, to be confirmed by the survey):** load 1.98 on 2 CPUs means installs (npm build) compete with SUPPAR; each unit has `CPUQuota=80%`, installs are niced, and the first install should run in a quiet period. 0 swap means a memory spike is fatal for something: the units have `MemoryMax` so the kernel kills the toolkit's service, not your containers, but the install step should only start with comfortable headroom (>= ~1.5 GiB available). The two warnings are unknown until the report text is seen.

**Evidence still needed from the VPS (one read-only command; adds the container inspection, no env values, no file contents beyond a masked compose structure):**
```
bash vps/remote-survey.sh root@VPS_ADDRESS --freellmapi-port 13001 --omniroute-port 20128 --inspect-container suppar-freellmapi
```
It reports: image/tag/created, health, restart policy, memory/CPU limits, user, networks, port mappings, mounts, env var NAMES only, compose labels, health endpoint status codes, `docker stats` (all containers), `docker system df`, and the compose structure with environment blocks and key/token/secret/password lines hidden. What it cannot learn without admin credentials: which providers/keys the existing instance has configured (deliberately not read).

## Three-way architecture comparison (A reuse / B second FreeLLMAPI :13001 / C OmniRoute + guard only)
Evidence level: reasoning from the repo's scripts and the owner-reported VPS facts. NOT yet backed by the container inspection (run `--forensic`, below). CI resource numbers are not VPS measurements.
| Criterion | A reuse :3001 | B second :13001 | C OmniRoute + guard only |
|---|---|---|---|
| Security isolation | worst: shares a production gateway's DB and admin account | good: own user, own dir, own units | best: no second FreeLLMAPI at all |
| SUPPAR compatibility | risk: audit `--auto-fix` may disable models SUPPAR uses; custom endpoint changes its DB | no interaction (own port, own data) | no interaction |
| RAM | ~0 extra for FreeLLMAPI | + one FreeLLMAPI (CI: ~65-81 MiB RSS) | OmniRoute (CI ~705-712 MiB) + 1 guard |
| Disk | OmniRoute + guards | + one FreeLLMAPI install | OmniRoute + 1 guard (smallest) |
| Operational complexity | highest (needs new attach code, admin credentials of production) | medium (supported path) | lowest (one gateway to run and update) |
| Reliability | coupled to SUPPAR's container lifecycle | independent units, `kill -9` recovery CI-tested | independent, fewest moving parts |
| Zero-cost inference (OVH anonymous) | needs a change inside SUPPAR's gateway | yes (provisioning as on the phone) | yes (OmniRoute `ovhanon` custom node, proven on the phone) |
| Maintenance | two things to keep compatible with SUPPAR | two gateways to update | one gateway |
**Provisional recommendation: C if you only need the free OVH route on the VPS, B if you also want FreeLLMAPI there; never A.** The deciding facts (resource headroom on the real VPS, what the existing container is, the remaining warning) come from the forensic run.

## Forensic run: ONE command from Termux (read-only except one report file under `/root/llm-deploy/`)
```
cd ~/freellmapi-omniroute-setup && git pull -q && bash vps/remote-survey.sh root@YOUR_REAL_ADDRESS --forensic --freellmapi-port 13001 --omniroute-port 20128
```
`--forensic` inspects `suppar-freellmapi` (override with `--inspect-container NAME`) and saves the whole report BOTH on the VPS (`/root/llm-deploy/vps-forensic-<UTC timestamp>.txt`, directory 0700, file 0600) and on the phone (`~/vps-survey-<timestamp>.txt`). Covers: container id/image/digest/version labels/health/restart/limits/user/networks/ports/mounts, env var NAMES only, compose project/service/working dir/config files, masked compose structure, health endpoint codes, per-container CPU/RAM, docker disk usage, host CPU/load/RAM/swap/disk, n8n/SUPPAR/EARNIX/Caddy/database containers and host services, non-loopback listeners and non-loopback docker ports, firewall listing, the preflight with port 13001, an inventory snapshot, and the exact preflight WARN/BLOCK lines. The only write on the VPS is the report file (plus a temp dir deleted at the end).

## Finding from auditing the scripts: the survey does not create the deploy gate files
`remote-survey.sh` runs the preflight and inventory in a temp dir on the VPS and deletes it, so nothing is left behind (by design). But `deploy.sh users` (the first changing step) refuses to run unless `--preflight FILE` says `RESULT: PASS*`, is from this host and newer than 24 h, and `--baseline FILE` exists. So Stage A/B of `docs/VPS-DEPLOYMENT.md` must still be done once on the VPS: copy the verified release archive, extract it, run `preflight.sh --freellmapi-port 13001 --omniroute-port 20128 --out /root/llm-deploy/preflight.txt` and `inventory.sh snapshot ... --out /root/llm-deploy/baseline.snap`. These write only under `/root/llm-deploy/` (mode 0600). The survey result is evidence for the decision, not a substitute for those files.

## Approval-gated execution plan (exact commands from `docs/VPS-DEPLOYMENT.md`, with the VPS-specific ports)
Nothing below has been run. Each gate is a separate "yes" from you; a failing step aborts the run.
| Gate | What | Writes to |
|---|---|---|
| G0 (prerequisite) | **Hostinger snapshot** in hPanel. I cannot verify your plan has one. No snapshot, no G3+. | Hostinger side only |
| G1 | Stage A: on a computer, `scripts/make-release.sh --out release --verify` at a CI-green commit, `scp` the `.tar.gz` and `.sha256` to `/root/`; on the VPS `sha256sum -c`. No GitHub credentials on the VPS. | `/root/` (two files) |
| G1 | Stage B: extract to `/root/llm-deploy`, run `./vps/preflight.sh --freellmapi-port 13001 --omniroute-port 20128 --out /root/llm-deploy/preflight.txt` and `./vps/inventory.sh snapshot --out /root/llm-deploy/baseline.snap --hash /etc/caddy/Caddyfile --hash <each compose/config file> --watch <n8n, SUPPAR, EARNIX data dirs>` (paths from the survey's Docker section) | `/root/llm-deploy/*` only |
| G3 | Dry run first: `./vps/deploy.sh prepare --preflight ... --baseline ... --freellmapi-port 13001 --omniroute-port 20128` (prints what it would do), then the same with `--apply`: users `llmfree`/`llmomni` (no login/sudo/docker group), `/srv/llm` layout, pinned Node 24.11.0 (sha256-verified), toolkit copy, `deploy.conf` + `gateways.env` with `PORT_FREELLMAPI=13001`, `BIND_HOST=127.0.0.1` | `/srv/llm`, two new users |
| G4 | `deploy.sh --apply install freellmapi`, `install omniroute`, `units` (renders, verifies with `systemd-analyze`, installs the two unit files, starts nothing) | `/srv/llm/<gw>`, `/etc/systemd/system/llm-freellmapi.service`, `llm-omniroute.service` |
| G5 | `deploy.sh --apply enable freellmapi --baseline ...`, then `enable omniroute --baseline ...` (health wait 120 s + `verify.sh`; a failing service is disabled again automatically) | systemd enablement of our two units |
| G6 | First use over an SSH tunnel: claim the FreeLLMAPI dashboard account before anything else can; configure OVH anonymous (custom endpoint, no keys) | gateway data under `/srv/llm` |
| G8 | Guards: `free-install.sh` dry-run, then apply: `llm-guard@` units on 3101/20228 forwarding to 13001/20128, audit timer, kill switch | `/etc/systemd/system/llm-guard*`, `llm-free-audit*` |
| later | OpenCode on the VPS (optional), same two-provider config pointing at 3101/20228 | user config |

After G5 and G8 run `./vps/inventory.sh compare /root/llm-deploy/baseline.snap`: every container, volume, network, unit file, user and hashed config of your existing services must be identical.

## What is NOT touched at any step
The container on 3001, Docker daemon/config/networks/volumes, Caddy and its config, n8n, SUPPAR, EARNIX, databases, firewall rules (the toolkit binds loopback only, so no rule is needed), sshd. Steps 3-8 are the only ones that write to the VPS and each is a separate approval.

## Open items (need the survey output)
RAM/disk headroom next to the existing services; whether `docker` metadata shows a compose project (so it is clearly excluded from anything the toolkit does); firewall/ufw state; any listener on 13001/20128/3101/20228; whether `/srv` is on its own filesystem.
