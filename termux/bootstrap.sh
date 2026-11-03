#!/usr/bin/env bash
# One-command setup of FreeLLMAPI + OmniRoute with the free-only guards, for Android/Termux (also runs on generic Linux for testing).
#
#   bash termux/bootstrap.sh [--no-inference] [--no-packages] [--boot|--no-boot]
#
# Safe to re-run: every step skips what is already done, and it never deletes data or overwrites keys. It does, in order:
#   1 packages (Termux only)   2 environment audit   3 install FreeLLMAPI + OmniRoute (pinned, tested versions)   4 start both
#   5 configure the keyless OVH anonymous route through each gateway's own API   6 free-only guards + secure keys (mode 600)
#   7 prune/audit: nothing non-free stays enabled   8 start guards   9 REAL inference through both guards   10 summary
# Everything binds to 127.0.0.1. No public port, no paid provider, no key you must type, no file you must edit.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The versions this toolkit was tested with (same pins as the VPS deployment); the caller's environment wins.
# Must be set BEFORE lib/common.sh is sourced: common.sh fills in unpinned defaults (main / latest) for anything still unset.
export FREELLMAPI_REF="${FREELLMAPI_REF:-v0.16.12}" OMNIROUTE_VERSION="${OMNIROUTE_VERSION:-3.8.52}"

# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

INFER=1; PKGS=1; BOOT=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --no-inference) INFER=0 ;; --no-packages) PKGS=0 ;; --boot) BOOT=1 ;; --no-boot) BOOT=0 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1" ;;
  esac; shift
done

GUARD_PORT_FREELLMAPI="${GUARD_PORT_FREELLMAPI:-3101}"; GUARD_PORT_OMNIROUTE="${GUARD_PORT_OMNIROUTE:-20228}"
export GUARD_PORT_FREELLMAPI GUARD_PORT_OMNIROUTE
STEP=0; TOTAL=10
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d]%s %s\n' "$C_B" "$STEP" "$TOTAL" "$C_0" "$*" >&2; }
stop_here() { # stop_here "what failed" "what to do"
  err "$1"; printf '\n  What to do: %s\n  Then run the same command again: it resumes where it stopped and keeps everything already set up.\n  Diagnosis any time:  bash %s/gateways.sh doctor\n' "$2" "$HERE" >&2; exit 1
}
FL() { bash "$HERE/freellmapi.sh" "$@"; }
OR() { bash "$HERE/omniroute.sh" "$@"; }
GD() { bash "$HERE/free-guard.sh" "$@"; }

FL_BASE="http://127.0.0.1:$FREELLMAPI_PORT"; OR_BASE="http://127.0.0.1:$OMNIROUTE_PORT"
FL_ADMIN="$GW_CONFIG_DIR/freellmapi.admin"; FL_UKEY="$GW_CONFIG_DIR/freellmapi.unified.key"; OR_APIKEY="$GW_CONFIG_DIR/omniroute.apikey"
FL_CKEY="$GW_CONFIG_DIR/guard-freellmapi.clientkey"; OR_CKEY="$GW_CONFIG_DIR/guard-omniroute.clientkey"

step "Packages"
if [ "$PKGS" = 1 ] && is_termux && have pkg; then
  # Install ONLY what is missing: a working node/curl/etc. is left exactly as it is (no upgrade, no reinstall).
  want=()
  have git || want+=(git); have curl || want+=(curl); have tar || want+=(tar); have node || want+=(nodejs)
  { have python || have python3; } || want+=(python)
  { have make && have clang; } || want+=(build-essential)   # native modules compile on the phone
  have setsid || want+=(util-linux)                          # own process group per gateway (clean stop/restart)
  if [ "${#want[@]}" -eq 0 ]; then ok "all required packages already present (nothing installed or upgraded)"
  else
    info "installing only the missing packages: ${want[*]}"
    pkg update -y >/dev/null 2>&1 || warn "pkg update failed (mirror problem?); trying the install anyway. If it fails: termux-change-repo"
    pkg install -y "${want[@]}" >/dev/null 2>&1 || stop_here "pkg install ${want[*]} failed" "run  termux-change-repo  (pick a mirror), then  pkg update -y"
    ok "installed: ${want[*]}"
  fi
else info "skipped (not Termux, or --no-packages)"; fi
have node && have git && have curl || stop_here "node, git and curl are required" "install them (Termux: pkg install nodejs git curl)"

step "Environment audit (read-only)"
bash "$HERE/audit-env.sh" || stop_here "the audit found a BLOCKER (see above)" "fix what it names (usually storage space or the Node version), or free memory by closing apps"
ensure_dirs; mkdir -p "$GW_STATE_DIR"

step "Install FreeLLMAPI $FREELLMAPI_REF and OmniRoute $OMNIROUTE_VERSION (first time: several minutes)"
# "Installed" means what is on disk, not a marker file: a gateway that was set up some other way and works is reused, never reinstalled or updated.
if [ -d "$GW_HOME/freellmapi/server/dist" ] && [ -d "$GW_HOME/freellmapi/node_modules" ]; then
  [ -f "$GW_STATE_DIR/freellmapi.installed_commit" ] || git -C "$GW_HOME/freellmapi" rev-parse HEAD > "$GW_STATE_DIR/freellmapi.installed_commit" 2>/dev/null || true
  ok "FreeLLMAPI already installed ($(git -C "$GW_HOME/freellmapi" describe --tags --always 2>/dev/null)); kept as is, not updated"
else FL install || stop_here "FreeLLMAPI install failed" "read the last lines above (a native-module build error usually means build tools or storage are missing)"; fi
OR_ENTRY="$GW_HOME/omniroute/node_modules/omniroute"
if [ -f "$OR_ENTRY/bin/omniroute.mjs" ]; then
  [ -f "$GW_STATE_DIR/omniroute.installed_version" ] || node -e 'console.log(require(process.argv[1]+"/package.json").version)' "$OR_ENTRY" > "$GW_STATE_DIR/omniroute.installed_version" 2>/dev/null || true
  ok "OmniRoute already installed ($(tr -d '\n' < "$GW_STATE_DIR/omniroute.installed_version" 2>/dev/null)); kept as is, not updated"
else NEW_OR=1; OR install || stop_here "OmniRoute install failed" "read the last lines above; OmniRoute needs Node >= 22.22.2 and about 3 GB of free storage"; fi
# Dashboard on (still 127.0.0.1 only, password protected) -- but only for an OmniRoute installed by THIS run; an existing config is never edited.
if [ "${NEW_OR:-0}" = 1 ]; then env_set "$GW_CONFIG_DIR/omniroute.env" OMNIROUTE_HEADLESS 0
elif [ "$(env_get "$GW_CONFIG_DIR/omniroute.env" OMNIROUTE_HEADLESS 2>/dev/null)" = 1 ]; then info "OmniRoute dashboard is off in your existing config (left untouched). To turn it on: set OMNIROUTE_HEADLESS=0 in $GW_CONFIG_DIR/omniroute.env and restart."; fi

step "Start both gateways"
FL start || stop_here "FreeLLMAPI did not start" "bash $HERE/gateways.sh logs freellmapi"
OR start || stop_here "OmniRoute did not start" "bash $HERE/gateways.sh logs omniroute   (first start can take a minute; just re-run)"

step "Configure the keyless OVH anonymous route through each gateway's own API"
node "$HERE/lib/provision.mjs" freellmapi --base "$FL_BASE" --cred-file "$FL_ADMIN" --key-out "$FL_UKEY" || stop_here "FreeLLMAPI configuration failed" "the message above says why; the dashboard route in docs/FREE-ONLY.md is the manual fallback"
node "$HERE/lib/provision.mjs" omniroute --base "$OR_BASE" --env-file "$GW_CONFIG_DIR/omniroute.env" --key-out "$OR_APIKEY" || stop_here "OmniRoute configuration failed" "the message above says why; the dashboard route in docs/FREE-ONLY.md is the manual fallback"

step "Free-only guards and credentials (all key files are mode 600)"
GD setup freellmapi --key-file "$FL_UKEY" --client-key-file "$FL_CKEY" || stop_here "guard setup failed (FreeLLMAPI)" "bash $HERE/gateways.sh doctor"
GD setup omniroute --key-file "$OR_APIKEY" --client-key-file "$OR_CKEY" || stop_here "guard setup failed (OmniRoute)" "bash $HERE/gateways.sh doctor"

step "Prune and audit: only verified-free models stay enabled"
(
  # shellcheck disable=SC1090
  . "$FL_ADMIN" 2>/dev/null || true
  export FREELLMAPI_ADMIN_EMAIL="${FREELLMAPI_ADMIN_EMAIL:-}" FREELLMAPI_ADMIN_PASSWORD="${FREELLMAPI_ADMIN_PASSWORD:-}"
  OMNIROUTE_ADMIN_PASSWORD="${OMNIROUTE_ADMIN_PASSWORD:-$(env_get "$GW_CONFIG_DIR/omniroute.env" INITIAL_PASSWORD)}"; export OMNIROUTE_ADMIN_PASSWORD
  GD audit
) || stop_here "the free-only audit reported a violation" "nothing paid may stay enabled; read the lines above (they name the model/provider), disable it in the dashboard, and re-run"
[ -f "$GW_STATE_DIR/freellmapi.catalog-audited" ] || stop_here "FreeLLMAPI's catalog audit did not complete" "bash $HERE/gateways.sh doctor"

step "Start the guards"
GD restart || stop_here "a guard did not start" "bash $HERE/gateways.sh logs guard-freellmapi   (or guard-omniroute)"
GD watch start || stop_here "the audit watcher did not start" "bash $HERE/gateways.sh doctor"

step "Genuine inference through both guards"
if [ "$INFER" = 1 ]; then
  if bash "$HERE/gateways.sh" test; then ok "both gateways completed a real request"
  else stop_here "an inference test failed" "if it says HTTP 429 wait a minute (OVH anonymous limit) and run  bash $HERE/gateways.sh test ; otherwise  bash $HERE/gateways.sh doctor"; fi
else warn "skipped (--no-inference): nothing proves a real completion yet; run  bash $HERE/gateways.sh test"; fi

step "Finish"
if [ "$BOOT" = 1 ] || { [ "$BOOT" = auto ] && [ -d "$HOME/.termux/boot" ]; }; then
  mkdir -p "$HOME/.termux/boot"
  printf '#!/data/data/com.termux/files/usr/bin/sh\ntermux-wake-lock\nbash "%s/gateways.sh" start\n' "$HERE" > "$HOME/.termux/boot/llm-gateways.sh"; chmod 700 "$HOME/.termux/boot/llm-gateways.sh"
  ok "start-at-boot script written (needs the Termux:Boot app)"
else info "start-at-boot: install the Termux:Boot app, then re-run with --boot (optional)"; fi

printf '\n'
bash "$HERE/gateways.sh" keys
cat <<EOF

== Daily use, recovery and restart ============================================
  bash $HERE/gateways.sh status     what is running, health, kill switch
  bash $HERE/gateways.sh start      start everything (after a phone reboot or if Android killed Termux)
  bash $HERE/gateways.sh restart    stop and start everything
  bash $HERE/gateways.sh test       one real request through each guard
  bash $HERE/gateways.sh doctor     diagnose and print the exact fix
  bash $HERE/gateways.sh logs <freellmapi|omniroute|guard-freellmapi|guard-omniroute>
  Back up / roll back: bash $HERE/freellmapi.sh backup | list-backups | restore <file> ; same for omniroute.sh
  Anything half-done: just run the bootstrap command again; it resumes and keeps your data.
  Android kills background apps: run termux-wake-lock (done by "start") and exempt Termux from battery optimisation.
EOF
