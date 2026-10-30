# VPS deployment runbook (Ubuntu server, next to existing services)

**Status: the tooling is built and tested on a disposable sandbox. It has NOT been run on your VPS, and nothing in this repo will touch the VPS until you
run these commands yourself or explicitly authorize me to.** Every modifying step is a dry run unless `--apply` is passed.

## What this deploys

Two isolated, loopback-only services under one root-owned directory. No Docker, no change to Caddy/n8n/SUPPAR/EARNIX, no apt packages.

```
/srv/llm/                       root:root 0755
├── runtime/node-v24.11.0/      pinned official Node (SHA-256 verified), root-owned; symlink runtime/node
├── toolkit/                    root-owned, read-only copy of this repo's termux/ tools/ vps/ config/ (+ VERSION = git commit)
├── deploy.conf                 chosen ports (no secrets)           deploy.log   record of every change made
├── freellmapi/   (llmfree:0700)   config/ (freellmapi.env 0600 = secrets generated on the server) freellmapi/ (code) freellmapi-data/ home/ backups/ logs/ state/
└── omniroute/    (llmomni:0700)   same layout
/etc/systemd/system/llm-freellmapi.service, llm-omniroute.service      (the only files outside /srv/llm; plus optional timers)
```

Users `llmfree` and `llmomni`: system accounts, shell `/usr/sbin/nologin`, in no group but their own (so: no `docker`, no `sudo`).
Each service can write only to its own directory (`ProtectSystem=strict`, `ReadWritePaths=` one path), runs with no capabilities, no new privileges, memory/CPU capped, lower
scheduling priority than your existing services, and listens on `127.0.0.1` only.

## Stages and approval gates

Replace `VPS` with your host. Use a fresh root shell; nothing here needs a reboot.

### Stage A: get the toolkit onto the VPS (on your laptop)
```bash
git clone https://github.com/sumeetparmar-cpu/freellmapi-omniroute-setup.git && cd freellmapi-omniroute-setup
git checkout <commit that CI shows green>       # the commit hash is printed in the final report
scripts/make-release.sh --out release --verify    # deterministic archive + .sha256; --verify re-runs the suites from a clean extraction
scp release/llm-toolkit-*.tar.gz release/llm-toolkit-*.tar.gz.sha256 root@VPS:/root/
# the same commit always produces the same bytes, so the hash can be compared with the one printed in the pull request
```
(The older manual form still works: `git archive --format=tar.gz --prefix=llm-toolkit/ HEAD -o llm-toolkit.tar.gz && sha256sum llm-toolkit.tar.gz`.) On the VPS, run `sha256sum -c llm-toolkit-*.tar.gz.sha256` before extracting.
No private-repo credentials ever need to exist on the VPS.

### Stage B: READ-ONLY inspection (VPS)  [gate G1: you authorize reading]
```bash
sha256sum /root/llm-toolkit.tar.gz              # must equal the hash from Stage A
mkdir -p /root/llm-deploy && tar -xzf /root/llm-toolkit.tar.gz -C /root/llm-deploy && cd /root/llm-deploy/llm-toolkit
./vps/preflight.sh --out /root/llm-deploy/preflight.txt
./vps/inventory.sh snapshot --out /root/llm-deploy/baseline.snap \
    --hash /etc/caddy/Caddyfile  --hash <each docker-compose.yml / .env-free config you care about> \
    --watch <n8n data dir> --watch <SUPPAR data dir> --watch <EARNIX data dir>
```
Writes: only `/root/llm-deploy/*` (the extracted toolkit and two report files, mode 0600). Everything else is read-only (`ss`/`/proc/net/tcp`, `df`, `docker ps/volume ls/network ls`,
`systemctl list-*`, `getent`, `stat`, `sha256sum`). The snapshot stores names, IDs, mounts, hashes and file identity only: never file contents, environment variables or secrets.
The preflight also checks (all read-only, every one covered by `tests/vps/preflight-extra.test.sh` with a negative control): the **guard ports** (3101/20228) and ports inside the kernel's **ephemeral range**; a **cgroup/container memory cap** below what `/proc/meminfo` shows, `vm.overcommit_memory=2`, and how much RAM would **remain for your existing services** with both gateways running; **read-only or `noexec` mounts** under `/srv/llm` (BLOCK) or `/tmp` (WARN) and free space in `/tmp`; a **symlinked** `/srv/llm`, a permissive `umask`, write access to `/srv` and `/etc/systemd/system`; **foreign unit files that already use our `llm-*` names** (BLOCK: they would be overwritten); the CA bundle, NTP clock sync, `openssl` and a native-build toolchain; and network failures are classified as **DNS failure** vs **connect/TLS failure** vs **HTTP status**.
**Stop here if `RESULT: BLOCKED`.** Typical blockers: port taken (it proposes another), < 6 GB free disk, < 1.5 GB RAM, no systemd, no pinned-Node architecture, missing `useradd`/`runuser`.
If the preflight proposes different ports, pass them to `config` below.

### Stage C: snapshot  [gate G2: you confirm]
Create a Hostinger snapshot/backup of the VPS in hPanel (I cannot verify that your plan includes it). Do not continue without a restore point.

### Stage D: create the isolated layout  [gate G3: you authorize changes]
```bash
./vps/deploy.sh prepare --preflight /root/llm-deploy/preflight.txt --baseline /root/llm-deploy/baseline.snap     # DRY RUN: read the output
./vps/deploy.sh --apply prepare --preflight ... --baseline ... [--freellmapi-port N --omniroute-port N]          # makes the changes
```
`prepare` = `users dirs runtime toolkit config`. The first step refuses to run unless the preflight report is `RESULT: PASS*`, from this host, newer than 24 h, and a baseline exists.
Any failing step aborts the whole run (nothing continues after an error). If your server sits behind an outbound proxy or private CA, add
`LLM_PASSTHROUGH_ENV="HTTPS_PROXY NO_PROXY SSL_CERT_FILE"` (opt-in; nothing else is inherited by the service users).

### Stage E: install the applications  [gate G4]
```bash
./vps/deploy.sh --apply install freellmapi     # niced, memory-capped when systemd-run is available; several minutes
./vps/deploy.sh --apply install omniroute
./vps/deploy.sh --apply units                  # renders, VERIFIES with systemd-analyze, installs the two unit files; does NOT start anything
```
Installs run as the service users, write only under their own directory, and generate each gateway's secrets there (`config/*.env`, 0600). Run during a quiet period.

### Stage F: start and verify  [gate G5]
```bash
./vps/deploy.sh --apply enable freellmapi --baseline /root/llm-deploy/baseline.snap
./vps/deploy.sh --apply enable omniroute  --baseline /root/llm-deploy/baseline.snap
```
Each `enable` starts the unit, waits up to 120 s for the liveness endpoint, then runs `verify.sh`. **If health or verification fails, that service is disabled again automatically.**
`verify.sh` proves: the inventory matches the baseline (containers, volumes, networks, unit files, users, hashes of Caddyfile/sshd/sudoers/cron, watched paths), the service users own
nothing outside `/srv/llm` (a niced, idle-IO `find` that skips `/proc /sys /run /tmp`, Docker/containerd storage and snaps; on a large disk the first run can take a minute or two), belong to no privileged group, and every socket they own is loopback-only on a configured port. Run it again any time:
`./vps/verify.sh --baseline /root/llm-deploy/baseline.snap`.

### Stage G: first use (you, over an SSH tunnel)  [gate G6]
```bash
ssh -L 13001:127.0.0.1:<freellmapi-port> -L 23128:127.0.0.1:<omniroute-port> root@VPS      # no sshd/Caddy/firewall change
```
* **Claim the FreeLLMAPI dashboard account first**, through the tunnel at `http://127.0.0.1:13001`, before any reverse proxy exists: a first-run account can be created without a code from a loopback caller.
* OmniRoute: `/srv/llm/toolkit/vps/gwctl.sh omniroute credentials` prints its generated password once, on request. Change it in the dashboard.
* Add providers yourself in the dashboards. I never need your provider keys. Do not add paid keys unless you accept that requests can then bill you.
* Create a FreeLLMAPI unified key / an OmniRoute **read**-scope access token, store them for the tools without ever typing them on a command line:
  `./vps/gwctl.sh freellmapi put-key` and `./vps/gwctl.sh omniroute put-key` (hidden prompt; saved 0600 for that service user only).
* Then: `./vps/gwctl.sh freellmapi test-model` (spends a tiny amount of a provider's quota; OmniRoute needs `--model provider/model`) and `./vps/gwctl.sh <gw> quota-report` (GET-only).

### Stage H (optional): schedules  [gate G7]
`./vps/deploy.sh --apply timers` installs `llm-backup@.timer` (weekly, briefly stops the service) and `llm-monitor.timer` (every 5 min, read-only) **without enabling them**; review, then
`systemctl enable --now llm-backup@freellmapi.timer llm-backup@omniroute.timer llm-monitor.timer`.

### Stage I (recommended, after F/G): the free-only guard  [gate G8]
Makes "₹0" an enforced property rather than a habit; read [FREE-ONLY.md](FREE-ONLY.md) first (it also lists the provider-account conditions no software can enforce).
```bash
./vps/free-install.sh units --client-keys            # DRY RUN: prints exactly which 6 unit files would be written
./vps/free-install.sh --apply units --client-keys    # writes llm-guard-<gw>.service, llm-free-audit-<gw>.service/.timer into /etc/systemd/system (not enabled)
# as the service user, create the two files the guard needs (client keys are shown once; the gateway key comes from the gateway dashboard):
runuser -u llmomni -- /srv/llm/runtime/node/bin/node /srv/llm/toolkit/tools/free-guard.mjs --new-client-key laptop --client-keys-file /srv/llm/omniroute/config/free-guard.clients
runuser -u llmomni -- sh -c 'umask 077; cat > /srv/llm/omniroute/config/free-guard.upstream.key'     # paste the gateway key, Ctrl-D
./vps/free-install.sh --apply enable omniroute       # starts the guard on 127.0.0.1:20228 + the 10-minute audit timer; disables itself again if it does not answer
./vps/free-install.sh status
```
Repeat for `freellmapi` (guard port 3101). For FreeLLMAPI run `tools/free-policy.mjs freellmapi apply` first and use `--catalog-audited` (see FREE-ONLY.md). Clients then call the **guard** port with their guard key;
the gateway ports stay loopback-only and unused by clients. The audit reads an optional `config/free-audit.env` (0600) that you create. Nothing in this stage touches the gateway units, Docker, Caddy, n8n, SUPPAR, EARNIX or databases.
Safety rails: `enable` refuses to start a guard whose client-key/upstream-key files are missing or empty (it would crash-loop); re-running `units` *without* `--client-keys` over a unit that already enforces them is refused unless you pass `--allow-downgrade`.
Undo: `./vps/free-install.sh --apply remove <gw>`.

### Not in this runbook (needs its own approval): exposing anything through Caddy
Phase 1 is tunnel-only. If you later want a public API hostname: a new site block in a separate included file, authentication in front, only `/v1/*`, `caddy validate` before any
reload (a bad reload can affect your existing sites). Services in Docker's bridge network cannot reach `127.0.0.1` of the host; how SUPPAR/EARNIX/n8n would call the gateways is an open question.

## Every command that changes the VPS

| Stage | Command | Effect |
|---|---|---|
| B | `mkdir`/`tar -x` into `/root/llm-deploy`, two report files | only place outside `/srv/llm` that gets files; delete after use |
| D | `useradd --system … llmfree` / `llmomni` | two no-login accounts, own group only |
| D | `install -d` for `/srv/llm`, `runtime/`, each gateway home (0700) | directories only |
| D | `curl` Node tarball → SHA-256 check → extract → `mv` → `ln -sfn` | adds a root-owned runtime under `/srv/llm/runtime`; aborts on checksum mismatch |
| D | `tar … | tar` toolkit copy, `chown -R root:root`, `chmod -R go-w` | root-owned code the service users cannot modify |
| D | write `deploy.conf`, each `config/gateways.env` | ports + pinned versions (no secrets) |
| E | `runuser -u llmfree|llmomni -- … <gw>.sh install` (nice/ionice, `systemd-run --scope -p MemoryMax=2G` if available) | `git clone`/`npm install`/build into the gateway's directory; downloads from GitHub and npm; generates secrets; CPU/RAM heavy |
| E | write `/etc/systemd/system/llm-freellmapi.service`, `llm-omniroute.service`, `systemctl daemon-reload` | the only system files touched; reload does not affect running services |
| F | `systemctl enable --now llm-<gw>.service` | starts that service now and at boot |
| G | `gwctl … put-key` | writes one 0600 file under that gateway's `config/` |
| H | install timer units; `systemctl enable --now …timer` | scheduled backup/monitor (opt-in) |
| I | `free-install.sh --apply units/enable` | writes 3 unit files per gateway under `/etc/systemd/system`; starts only that gateway's guard + audit timer; touches no existing unit |
| later | `gwctl <gw> update/rollback/restore/backup`; `backup-run.sh` | stop → act → start, only on that gateway's own code/data; scheduled backups pruned by name |
| undo | `deploy.sh --apply remove <gw>` [`--purge --yes-delete-data`] | stop/disable/remove that unit; purge deletes only `/srv/llm/<gw>` and its user |

Commands it never runs: `apt`, `docker` (except read-only `ps`/`volume ls`/`network ls`/`volume inspect`), `caddy`, `ufw`/`iptables`, `crontab`, `usermod` on existing users, anything in `/etc/ssh`, `/etc/sudoers*`, `/etc/caddy`, or existing application directories.
This is checked mechanically: a grep of the committed scripts for those commands is part of `tests/vps/run-tests.sh`.

## If an install is interrupted

Every step is safe to re-run; there is no manual cleanup. What each interruption leaves, and what the re-run does (all covered by `tests/vps/partial-failure.test.sh`, 33 checks; 15 of them fail if the fixes are reverted):

| Interrupted / failed | Left behind | Re-run |
|---|---|---|
| `runtime`: download cut short, or wrong bytes | nothing installed, no `runtime/node` link, temp dir removed by the EXIT trap; a wrong checksum aborts with `SHA-256 mismatch` | just run `runtime` again |
| `runtime`: process **SIGKILLed** mid-download | a `runtime/.dl.XXXXXX` temp dir (~30 MB), no half-installed runtime | removes OUR `.dl.*` dirs older than 2 minutes (a concurrent run's fresh one is kept), then installs |
| `runtime`: killed between the move and the `chown`/`chmod` | `node-vX` present but possibly wrong owner / group-writable | ownership and modes are re-applied on every run |
| `toolkit`: crash between the two renames | no `toolkit/`, `toolkit.prev` and a half-copied `toolkit.new` | re-run re-stages and swaps; ends root-owned and not group/world-writable |
| `install freellmapi`: `git clone` killed | a `freellmapi/` with a `.git` but no usable HEAD or tree | detected ("incomplete checkout"), removed (only inside that gateway's own home) and cloned again |
| `install`: clone fails / build fails | no `state/*.installed_commit` marker; `start` refuses ("not built") | re-run after fixing the cause; nothing is ever marked installed unless the build finished |
| `backup`: `tar` fails, disk full, or killed | previously: a truncated `*.tar.gz` reported as success and picked as "latest" for rollback. Now: written as `.partial`, checked (`tar` status, `gzip -t`, `tar -t`) and renamed atomically; failures delete it and exit non-zero; stale `.partial` files are cleaned | next backup works; `latest_backup`/`restore` also skip any archive that does not read back |

## Rollback
| Level | Command | Affects |
|---|---|---|
| 1 | `gwctl <gw> rollback --yes` (code only) | that gateway |
| 2 | `gwctl <gw> rollback --with-data --yes` / `restore --yes` (takes a `pre-rollback`/`pre-restore` backup first) | that gateway's code+data |
| auto | `gwctl <gw> update`: backs up, updates, restarts, health-checks 120 s; **unhealthy ⇒ automatic `rollback --with-data`** | that gateway |
| 3 | `deploy.sh --apply remove <gw>` then optionally `--purge --yes-delete-data` | only what this toolkit created |
| 4 | restore the Hostinger snapshot | **whole VPS, including your other services' data since the snapshot**: last resort |
Backups contain encryption keys and encrypted provider credentials: export them with `gwctl <gw> export-backup ARCHIVE OUT --gpg-recipient R` (or `--age-recipient`); it refuses to export unencrypted.

## Resource budget (heuristics, not measurements on your VPS)
FreeLLMAPI: `MemoryMax=1G` (heap 512 MB). OmniRoute: `MemoryMax=2G` (`OMNIROUTE_MEMORY_MB=1024`; ~0.6 GB RSS was seen idle in the sandbox). `CPUQuota=80%`, `CPUWeight=50`, `Nice=10`, `IOWeight=50`:
under contention your existing services win. Override per unit with `MEM_MAX=3G ./vps/deploy.sh --apply units`. Measured 2026-10-30 in the sandbox: FreeLLMAPI 0.58 GB disk / ~155 MB RSS; OmniRoute 2.8 GB disk / ~610 MB RSS (wrapper + server); each free-guard ~61 MB RSS (unit cap 192 MB). Disk: ~0.6 GB + up to ~2.8 GB, plus backups. `monitor.sh check` warns at < 8 GB free.

## Known limits, stated plainly
* **Ubuntu 26.04**: the toolkit's unprivileged suites, the privileged suite (real users, units, update/rollback, purge), the end-to-end rehearsal and the guard/audit systemd test all pass in CI on a GitHub-hosted `ubuntu-26.04` runner as well as `ubuntu-24.04`. What has *not* been done is a run on your own 26.04 VPS: your kernel, cgroup setup, installed packages and neighbouring services can differ from a clean runner, so run the read-only `preflight.sh` (Stage B) there first. The preflight decides on functional checks (glibc, systemd ≥ 245, cgroup v2, tools, ports, resources) and warns on any other OS version.
* **systemd start path**: the guard/audit units AND the two gateway units run under real systemd in CI (Ubuntu 24.04 / systemd 255 and 26.04 / systemd 259): `tests/vps/e2e-systemd.sh`, 63 checks per image at head `92836e5`, covering real installs, kernel cgroup limits (memory.max 1 GiB/2 GiB, memory.high, cpu.max 80%, pids.max 512), `kill -9` recovery with the other gateway untouched, graceful stop leaving no process, StartLimit crash loop and the documented recovery. NOT proven: anything on the Hostinger VPS (different kernel, neighbouring services), behaviour under real load or OOM, reboot persistence.
* Free provider tiers are not guaranteed: nothing here depends on a quota, and `quota-report` prints Unknown wherever a source exposes nothing.
* Your existing services' ports, data locations and Docker setup are unknown to me; the preflight and inventory are how they get checked, on the VPS, read-only.
* The pinned Node (24.11.0) and application versions (FreeLLMAPI v0.16.12, OmniRoute 3.8.52) are the tested ones. Bump `NODE_VERSION` + the two SHA-256 values in `vps/lib/vps-common.sh` deliberately, then re-run the tests.
