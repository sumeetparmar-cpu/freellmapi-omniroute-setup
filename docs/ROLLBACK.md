# Backups, updates and rollback

All paths are relative to `GW_HOME` (`~/llm-gateways` on Termux, `%USERPROFILE%\llm-gateways` on Windows).

```
config/<gw>.env          secrets (mode 600 / owner-only)        <- inside every backup
freellmapi-data/         FreeLLMAPI SQLite DB                    <- inside every backup
omniroute-data/          OmniRoute SQLite DB, .env, logs         <- inside every backup
freellmapi/  omniroute/  application code (git checkout / npm prefix) – replaceable
state/                   installed_*, prev_* (version to roll back to), *.node_version
backups/<gw>/            <UTC timestamp>-<label>.tar.gz (Termux) | .zip (Windows), owner-only
run/ logs/               PID files and logs
```

## Backups

```bash
./termux/<gw>.sh stop && ./termux/<gw>.sh backup      # manual; stop first for a consistent SQLite copy
./termux/<gw>.sh list-backups
```
```powershell
.\windows\<gw>.ps1 stop; .\windows\<gw>.ps1 backup; .\windows\<gw>.ps1 list-backups
```

Automatic backups: `pre-update` (before every `update`) and `pre-restore` (before every `restore`).
Archives hold your encryption keys and encrypted provider credentials, so **copy them somewhere private
(not Git, not a public cloud folder)**. A backup without its matching `config/<gw>.env` cannot decrypt its DB;
the script backs both up together so they stay paired.

The scripts back up while running only with a warning: SQLite WAL files are copied too, but a stopped
gateway is the only fully consistent snapshot.

Restore safety: Termux restore refuses archives with `..` path components; Windows restore refuses any entry
outside `config\` and `data\` (zip-slip protection) and always writes to the gateway's own known locations.

## Update → verify → roll back

```bash
./termux/<gw>.sh update            # stops gateway, takes pre-update backup, records previous version, upgrades, restarts if it was running
./termux/<gw>.sh health && ./termux/<gw>.sh test-model ...
./termux/<gw>.sh rollback          # code only: reinstall the recorded previous version
./termux/<gw>.sh rollback --with-data   # code + restore the data/config from the pre-update backup
```

Which rollback do I need?

* New version won't start, or errors on the DB → **`--with-data`**. Newer versions can migrate the database forward in
  ways older code cannot read. `--with-data` discards changes made *after* the update (new keys, chat history, settings).
* Version is merely worse but the DB is fine → plain `rollback` keeps everything you did since.

Both prompt for confirmation (`--yes` / `-Yes` to skip). `update` records the previous version each time it runs,
so running `update` twice in a row makes "previous" mean "the version before the second update". If that happened,
use the version number from `list-backups` timestamps, or pin explicitly:

```bash
./termux/freellmapi.sh update --ref v0.16.11          # any tag/branch/commit
./termux/omniroute.sh  update --version 3.8.50        # any published npm version
```
```powershell
.\windows\freellmapi.ps1 update -Ref v0.16.11
.\windows\omniroute.ps1  update -Version 3.8.50
```

Observed while testing: `omniroute@3.8.50` ran fine as a downgrade target, and a rollback with `--with-data` removed a
dashboard API key created after the update (proof the DB was actually restored). See [TESTING.md](TESTING.md).

## Restore from a specific backup

```bash
./termux/<gw>.sh restore --archive ~/llm-gateways/backups/<gw>/<file>.tar.gz     # or just: restore <file>
```
```powershell
.\windows\<gw>.ps1 restore -Archive $env:USERPROFILE\llm-gateways\backups\<gw>\<file>.zip
```
A `pre-restore` backup of the current state is taken first (`rollback --with-data` takes `pre-rollback`), so a restore is itself reversible. Restore replaces the gateway's data directory wholesale, so no stale SQLite `-wal`/`-shm` file from the newer version survives.

## Node version changed ("Node changed since … was built")

Native modules (SQLite) are compiled for one Node ABI. The scripts record the Node version at install/build time and
refuse to start under a different one (this was hit for real while testing: Node 22 build, Node 24 runtime → `NODE_MODULE_VERSION` crash).
Either switch back, or run `rebuild` (`npm rebuild` + build for FreeLLMAPI; `npm rebuild` in the OmniRoute prefix).

## Stopping cleanly

`stop` terminates the whole process tree. OmniRoute's CLI is a supervisor with a separate server child that it
**respawns if killed** and that some older builds ignore SIGTERM once orphaned; the scripts therefore stop the parent
first, wait, force-kill survivors, and warn if the port is still held. Windows has no graceful signal for hidden console
processes, so `stop` there is a hard kill (SQLite is crash-safe; take backups with the gateway stopped).

## Manual rollback if the scripts themselves fail

FreeLLMAPI (code + data):
```bash
cd ~/llm-gateways/freellmapi && git checkout -f <previous-commit> && npm install --no-audit --no-fund && npm run build
tar -C / -xzf ~/llm-gateways/backups/freellmapi/<…>-pre-update.tar.gz       # restores config + DB (Termux archive)
```
OmniRoute:
```bash
npm install --prefix ~/llm-gateways/omniroute omniroute@<previous-version> --no-audit --no-fund
tar -C / -xzf ~/llm-gateways/backups/omniroute/<…>-pre-update.tar.gz
```
(On Windows, unzip the archive: `config\<gw>.env` goes to `llm-gateways\config\`, `data\` replaces `llm-gateways\<gw>-data\`.)

## Removing everything

`uninstall` deletes the **code only** and keeps config, data and backups. To wipe a gateway completely, stop it, then delete
`config/<gw>.env`, `<gw>-data/`, `backups/<gw>/` and `state/<gw>.*` yourself. This is irreversible and loses your stored provider keys.
