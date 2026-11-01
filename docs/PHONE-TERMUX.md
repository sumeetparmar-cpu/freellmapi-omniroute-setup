# FreeLLMAPI + OmniRoute on your Android phone: one command

**Honest status first.** The bootstrap below is tested for real on Linux (CI, Ubuntu 24.04 and 26.04: real installs, real guards, restart and crash recovery) and, once, with genuine OVH inference through both guards. It has **not been run on Android or in Termux**. Linux tests do not prove Android works; the list of what only a phone can prove is at the bottom. If something fails, the script stops with the exact next step, and running the same command again resumes.

## Step 0: see what is already on the phone (read-only; installs and changes nothing)
Run `bash ~/freellmapi-omniroute-setup/termux/diagnose.sh` (or paste the self-contained version from the chat if the repo is not on the phone yet). It reports versions, locations, whether each gateway is built, whether it is running, which settings exist (names only, never values), and prints the exact next step. **Nothing that already works is reinstalled, updated or deleted:** the bootstrap treats a gateway as installed when its files are on disk, repairs a partial one in place, and only starts a stopped one. If you already created a FreeLLMAPI account or changed OmniRoute's password in a dashboard, give your login once: `FREELLMAPI_ADMIN_EMAIL=... FREELLMAPI_ADMIN_PASSWORD=... OMNIROUTE_ADMIN_PASSWORD=... bash ~/freellmapi-omniroute-setup/termux/bootstrap.sh` (stored only in mode-600 files on the phone).

## The command (paste into Termux, installed from **F-Droid**, not the Play Store)

```bash
pkg update -y && pkg install -y git gh && { gh auth status >/dev/null 2>&1 || gh auth login -h github.com -p https -w; } && gh auth setup-git && { [ -d ~/freellmapi-omniroute-setup/.git ] && git -C ~/freellmapi-omniroute-setup pull --ff-only || gh repo clone sumeetparmar-cpu/freellmapi-omniroute-setup ~/freellmapi-omniroute-setup -- -b claude/network-access-connectivity-test-82ck5t; } && bash ~/freellmapi-omniroute-setup/termux/bootstrap.sh
```

The **one** thing you do by hand: this repository is private, so `gh auth login` shows a one-time code and a web address. Open the address in the phone's browser, enter the code, approve, return to Termux (press Enter at any prompt). Nothing else needs typing or editing. (The branch is the PR branch; it is not merged into `main` yet.)

## What the command does (all idempotent: safe to run again)
1. Installs **only the packages that are missing** (git, python and the build tools on a typical fresh Termux; an existing node/curl is left untouched, nothing is upgraded) and audits the phone (RAM, storage, Node version): stops with a plain message on a blocker.
2. Installs the **tested versions** only if missing: FreeLLMAPI v0.16.12 and OmniRoute 3.8.52 (first time: several minutes, ~3 GB of storage). Existing installs, configs and data are reused as they are (not updated, not edited, not deleted).
3. Starts both and configures the **keyless OVH anonymous route** through each gateway's own API: the FreeLLMAPI custom endpoint, and the OmniRoute node `ovhanon` plus one active keyless connection. No account, no API key, no billing.
4. Generates the credentials (owner login, gateway keys, guard keys), all in `~/llm-gateways/config/` with mode 600. Nothing is printed except your two **guard keys** in the final summary.
5. Prunes and audits: FreeLLMAPI keeps only verified-free models enabled (disable-only, never deletes); OmniRoute is checked for any provider outside the policy. A violation stops the script before anything is exposed.
6. Starts the **free-only guards** and an **audit watcher**, then makes **real requests through both** (HTTP 200, non-empty text, token usage required; a health check does not count).
7. Prints the endpoints, models and dashboard addresses.

**Why a watcher:** FreeLLMAPI re-syncs its model catalog from the internet at every start and every 12 hours, and that can switch on models nobody verified (seen on CI: community providers such as `aihorde` re-appearing minutes after the install audit). The watcher (`gateways.sh` starts it; every 60 s) re-audits, disables anything not verified free (disable-only, never deletes) and keeps the kill switch engaged while a violation exists. On a VPS the same job is a systemd timer.

**Model names on FreeLLMAPI:** it groups same-named models behind one id and answers unified names such as `gpt-4o` or `claude-opus-4-5` from whatever is enabled. Since only free models are ever enabled and no paid provider is configured, such a request is answered by the free OVH model (or refused), never by a paid one; ask for `gpt-oss-20b` if you care which model answers. OmniRoute is strict: anything not on the free list gets HTTP 403.

## Where things are (all `127.0.0.1`, i.e. only apps on this phone; no public port is opened)
| | Address | Model |
|---|---|---|
| **FreeLLMAPI API (use this)** | `http://127.0.0.1:3101/v1` | `gpt-oss-20b` |
| **OmniRoute API (use this)** | `http://127.0.0.1:20228/v1` | `ovhanon/gpt-oss-120b` |
| FreeLLMAPI dashboard | `http://127.0.0.1:3001` (login `owner@gateway.invalid`, password in `~/llm-gateways/config/freellmapi.admin`) | |
| OmniRoute dashboard | `http://127.0.0.1:20128` (password: `bash ~/freellmapi-omniroute-setup/termux/omniroute.sh credentials`) | |

Send the **guard key** (`bash ~/freellmapi-omniroute-setup/termux/gateways.sh keys`) as `Authorization: Bearer ...`. Never use ports 3001/20128 from apps: they list paid model names. Paid models get HTTP 403 from the guards; there is no fallback and no paid provider is configured. OmniRoute's `/models` list does not show the OVH model, so enter `ovhanon/gpt-oss-120b` by hand in apps that let you type a model name (apps that only offer a dropdown cannot select it). OVH's anonymous tier allows **2 requests per minute per model**; reasoning models need `max_tokens` of at least ~200 or the visible text can be empty.

## Daily use, restart and recovery
```bash
G=~/freellmapi-omniroute-setup/termux/gateways.sh
bash $G status      # processes, health, kill switch
bash $G start       # after a phone reboot, or if Android killed Termux (also takes a wake lock)
bash $G restart
bash $G test        # one real request through each guard
bash $G doctor      # diagnoses and prints the exact fix for each problem
bash $G logs freellmapi    # or: omniroute | guard-freellmapi | guard-omniroute
```
* **Something half-installed or failed:** run the one command again; it resumes and keeps your data.
* **A gateway crashed or Android killed it:** `bash $G start` (the scripts ignore zombie and orphaned processes, and `restart` cleans both).
* **Start at boot:** install the *Termux:Boot* app, then `bash ~/freellmapi-omniroute-setup/termux/bootstrap.sh --boot`.
* **Backup / rollback:** `bash ~/freellmapi-omniroute-setup/termux/freellmapi.sh backup` (same for `omniroute.sh`); `list-backups`, `restore <file>`. Backups carry the guard's key hashes, never the gateway keys.
* **Kill switch engaged** (doctor says so): a policy violation was found and inference is refused until the audit passes. Fix the named model/provider, then re-run the command.
* Keep Android from suspending Termux: exempt it from battery optimisation (the script takes a wake lock but Android may still kill it).

## What needs a real phone (NOT proven by any Linux/CI test)
* Termux package names and versions (`nodejs` current, `python`, `build-essential`, `util-linux` for `setsid`).
* **Native modules building on Android (Bionic libc, aarch64)**: the biggest risk (the scripts set Termux's known `GYP_DEFINES="android_ndk_path=''"` workaround for `node-gyp`, untested on a phone). FreeLLMAPI tolerates a failed optional `better-sqlite3` build; OmniRoute's native dependencies are unverified on Android.
* RAM and storage: OmniRoute measured ~610 MB RAM / 2.8 GB disk on Linux, FreeLLMAPI ~155 MB / 0.6 GB. Phone figures are unmeasured; if it struggles, run one gateway at a time.
* `gh auth login` device flow inside Termux; `termux-wake-lock`; Termux:Boot; Android's background-process killing.
* Install time on mobile data (downloads are retried with back-off if the connection drops).

If any of these fails, send me the last screen of output and I will fix the script.

## Reaching it from other devices
Everything binds to `127.0.0.1` on purpose. For a laptop later use a private VPN (Tailscale) with key auth on; never port-forward.
