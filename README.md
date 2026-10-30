# FreeLLMAPI + OmniRoute installation toolkit

Scripts to install, audit, health-check, back up, update and roll back two **independent** local
LLM gateways, on **Android (Termux)** and **Windows (PowerShell)**:

| | FreeLLMAPI | OmniRoute |
|---|---|---|
| Upstream | [tashfeenahmed/freellmapi](https://github.com/tashfeenahmed/freellmapi) (MIT) | [cheaper-inference/OmniRoute](https://github.com/cheaper-inference/OmniRoute) (MIT, npm `omniroute`) |
| Installed from | git checkout + `npm install` + `npm run build` | npm package into an isolated prefix |
| Default port (separate!) | **3001** | **20128** |
| Node requirement | `>=20.18 <25` (Android: `>=22.13`) | `>=22.22.2 <23` or `>=24 <27` |
| Auth for `/v1/*` | its "unified key" (dashboard) | an API key you create in the dashboard (`REQUIRE_API_KEY=true` is set) |
| Liveness probe | `GET /api/ping` | `GET /api/health/ping` |

**One Node satisfies both: Node 24.x** (or 22.22.2+ on the 22 line). Verified: FreeLLMAPI builds and runs on
Node 22.22.0 and 24.11.0; OmniRoute needs 24.x or ≥ 22.22.2 (the audit script blocks 22.22.0).

> **Nothing here has been run on your phone or laptop.** Everything was developed and tested in a Linux
> container; see [docs/TESTING.md](docs/TESTING.md) for exactly what was and was not verified, and what
> to run yourself on each device to confirm.

## Design rules

* **Independent gateways.** Each has its own install dir, data dir, env file, PID file, log, port and
  Node-ABI record. Neither script reads or writes the other's files. Equal ports are refused.
* **Loopback only by default** (`127.0.0.1`). FreeLLMAPI would otherwise bind all interfaces (`::`).
* **No secrets in Git, ever.** Encryption keys, JWT secrets, dashboard password are generated on the
  device at install time into `llm-gateways/config/*.env` (mode 600 / owner-only ACL), outside this repo.
  `.gitignore` blocks env/db/key/archive files and `scripts/check-secrets.sh` scans before commit.
* **API keys never touch a command line**: `test-model` takes the key from an env var, a key file, or a
  hidden prompt, and hands it to curl/HttpClient without putting it in `argv` or on disk.
* **Free-only, enforced** (allowlist + guard proxy + audit; see [docs/FREE-ONLY.md](docs/FREE-ONLY.md)) and **honest** about quotas, terms and privacy: [docs/PROVIDERS-AND-COSTS.md](docs/PROVIDERS-AND-COSTS.md).
* **Reversible.** Every `update` takes a backup and records the previous version;
  `rollback [--with-data]` returns to it. See [docs/ROLLBACK.md](docs/ROLLBACK.md).

## Layout

```
termux/   freellmapi.sh  omniroute.sh  audit-env.sh  lib/common.sh     # Android/Termux (bash)
windows/  freellmapi.ps1 omniroute.ps1 audit-env.ps1 lib/Common.ps1    # Windows PowerShell 5.1 / 7+
config/   gateways.env.example  free-policy.json                       # non-secret overrides (ports, pins); verified-free model allowlist
tools/    quota-report.mjs  free-guard.mjs  free-policy.mjs  lib/        # read-only quota report; free-only guard proxy + policy audit
vps/      preflight.sh inventory.sh deploy.sh verify.sh gwctl.sh monitor.sh backup-run.sh systemd/   # Ubuntu VPS deployment (isolated users, systemd)
scripts/  check-secrets.sh                                             # pre-commit secret scan
tests/    termux/ windows/ mock-openai-server.mjs                      # offline test suites
docs/     FREE-ONLY.md  PROVIDERS-AND-COSTS.md  ROLLBACK.md  QUOTA-REPORT.md  VPS-DEPLOYMENT.md  TESTING.md
```

State lives in `~/llm-gateways` (Termux) or `%USERPROFILE%\llm-gateways` (Windows); override with `GW_HOME`.

## Android / Termux

Install **Termux from F-Droid** (the Play Store build is outdated; upstream says the same), then:

```bash
pkg update && pkg upgrade -y
pkg install -y git curl openssl nodejs python build-essential   # `nodejs` (current), not nodejs-lts: OmniRoute needs >=22.22.2
pkg install -y termux-api                                       # optional: termux-wake-lock keeps servers alive
git clone <this repo> && cd freellmapi-omniroute-setup

./termux/audit-env.sh                       # read-only; fix every BLOCKER first
./termux/freellmapi.sh install && ./termux/freellmapi.sh start
./termux/omniroute.sh  install && ./termux/omniroute.sh  start
./termux/freellmapi.sh health; ./termux/omniroute.sh health
```

Dashboards: `http://127.0.0.1:3001` (FreeLLMAPI: create the first account, add provider keys, copy the
unified key) and `http://127.0.0.1:20128` (OmniRoute: `./termux/omniroute.sh credentials` prints the
generated password; connect providers, create an API key under *Endpoints*).

Model-request test (spends a tiny amount of *your* provider quota, see costs doc):

```bash
FREELLMAPI_KEY=...   ./termux/freellmapi.sh test-model                 # or --key-file F, or hidden prompt
OMNIROUTE_KEY=...    ./termux/omniroute.sh  test-model --model <provider/model>
```

Android may suspend Termux when the screen is off: run `termux-wake-lock`, and exempt Termux from
battery optimisation. Memory use was not measured on a phone. The audit uses a rough heuristic (warn under 3 GB total RAM, block under 1.5 GB); if the phone struggles, run one gateway at a time.

## Windows

Needs Node.js (24.x or 22.22.2+), Git and npm: `winget install OpenJS.NodeJS.LTS Git.Git` (check
`node -v`; if the LTS channel is older than 22.22.2, install a newer Node).

```powershell
git clone <this repo>; cd freellmapi-omniroute-setup
# If scripts are blocked: prefix each call with  powershell -ExecutionPolicy Bypass -File   (per-process, no system change)
.\windows\audit-env.ps1
.\windows\freellmapi.ps1 install; .\windows\freellmapi.ps1 start
.\windows\omniroute.ps1  install; .\windows\omniroute.ps1  start
.\windows\freellmapi.ps1 health;  .\windows\omniroute.ps1  health
```

Actions are identical to Termux (`install start stop restart status health test-model backup list-backups
restore update rollback rebuild logs uninstall`, plus `credentials` for OmniRoute). Switches use PowerShell
style: `-Yes -WithData -KeyFile -Model -Ref -Version -Archive`.

FreeLLMAPI also ships a signed Windows `.exe` desktop installer (GitHub Releases). It is simpler but not
scriptable and keeps data under `%APPDATA%\FreeLLMAPI`; these scripts install from source instead, so
that backup, rollback and port control behave the same on both platforms. Do not run both flavours at once.

## Linux VPS (Ubuntu) next to existing services

`vps/` deploys both gateways as **separate unprivileged systemd services under `/srv/llm`**, loopback-only, resource-capped, with a read-only preflight and
inventory so the existing server (Docker, Caddy, n8n, other apps) can be shown to be unchanged. Every changing step is a **dry run unless `--apply`**, and the
first one is gated on a clean preflight report plus a pre-change inventory baseline. Start with `docs/VPS-DEPLOYMENT.md`; it lists every command and what it does.
Not yet run on any real VPS: see its "Known limits".

## Daily commands

| Task | Termux | Windows |
|---|---|---|
| Status / health | `./termux/<gw>.sh status` / `health` | `.\windows\<gw>.ps1 status` / `health` |
| Backup (stop first for a consistent SQLite copy) | `./termux/<gw>.sh stop && ./termux/<gw>.sh backup` | `.\windows\<gw>.ps1 stop; .\windows\<gw>.ps1 backup` |
| Update (auto-backup + records previous version) | `./termux/<gw>.sh update` | `.\windows\<gw>.ps1 update` |
| Roll back | `./termux/<gw>.sh rollback [--with-data]` | `.\windows\<gw>.ps1 rollback [-WithData]` |
| Node version changed | `./termux/<gw>.sh rebuild` | `.\windows\<gw>.ps1 rebuild` |
| Logs | `./termux/<gw>.sh logs` | `.\windows\<gw>.ps1 logs` |
| Usage / quota / availability report (read-only, no model requests) | `./termux/<gw>.sh quota-report` | `.\windows\<gw>.ps1 quota-report` |

Pin versions for repeatability in `llm-gateways/config/gateways.env` (see `config/gateways.env.example`):
`FREELLMAPI_REF=v0.16.12`, `OMNIROUTE_VERSION=3.8.52`.

## Before you commit changes to this repo

```bash
scripts/check-secrets.sh && bash tests/termux/run-tests.sh && bash tests/termux/test-check-secrets.sh
pwsh -File tests/windows/run-tests.ps1        # or: powershell -ExecutionPolicy Bypass -File tests\windows\run-tests.ps1
```

## Supply-chain note

OmniRoute is installed from the **npm registry** (`omniroute`), not built from git, so the tarball you get is
what the maintainers published; this toolkit cannot verify it matches the Git source. Its `package.json`
declares `cheaper-inference/OmniRoute` as the repository, while some of its README links point to
`diegosouzapw/OmniRoute` (the copyright holder in `LICENSE`). Pin `OMNIROUTE_VERSION` once you have a version
you trust. FreeLLMAPI is cloned from GitHub over HTTPS at the ref you choose; pin `FREELLMAPI_REF` to a tag or commit.
