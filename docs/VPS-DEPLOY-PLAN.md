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

## Then, each step needs your explicit approval (gates from `docs/VPS-DEPLOYMENT.md`)
1. **G2 restore point**: Hostinger snapshot in hPanel (I cannot verify that your plan includes one). No snapshot, no further step.
2. **G2 baseline**: `inventory.sh snapshot --hash /etc/caddy/Caddyfile ... --watch <n8n/SUPPAR/EARNIX dirs>`: later `compare` must show your services unchanged.
3. **G3 layout**: `deploy.sh --apply layout --preflight <report> --baseline <snap> --freellmapi-port 13001`: creates users `llmfree`/`llmomni` and `/srv/llm` only.
4. **G4 install** FreeLLMAPI and OmniRoute (pinned Node 24.11.0, FreeLLMAPI v0.16.12, OmniRoute 3.8.52) as their own users.
5. **G5 start + verify** under systemd with cgroup limits (1 GiB / 2 GiB); `verify.sh`; `inventory.sh compare` must show nothing changed.
6. **G6 first use** over an SSH tunnel; claim the FreeLLMAPI dashboard account before anything else can.
7. **G8 guards** (`free-install.sh`, dry-run first): free-only enforcement, kill switch, audit timer. Route inference through OVH anonymous only (no keys, no paid fallback); the phone's `termux/lib/provision.mjs` approach (custom endpoint + `ovhanon` node) is the model for it.
8. **OpenCode on the VPS** (optional, after 7): same two-provider config as on the phone, pointing at the guard ports.

## What is NOT touched at any step
The container on 3001, Docker daemon/config/networks/volumes, Caddy and its config, n8n, SUPPAR, EARNIX, databases, firewall rules (the toolkit binds loopback only, so no rule is needed), sshd. Steps 3-8 are the only ones that write to the VPS and each is a separate approval.

## Open items (need the survey output)
RAM/disk headroom next to the existing services; whether `docker` metadata shows a compose project (so it is clearly excluded from anything the toolkit does); firewall/ufw state; any listener on 13001/20128/3101/20228; whether `/srv` is on its own filesystem.
