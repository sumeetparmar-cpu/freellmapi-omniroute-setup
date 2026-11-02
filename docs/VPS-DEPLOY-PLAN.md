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
