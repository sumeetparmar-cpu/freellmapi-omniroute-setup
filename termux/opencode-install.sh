#!/usr/bin/env bash
# Install OpenCode on Termux (Android ARM64) and wire it to the two free-only guards. Safe to re-run. Never touches the gateways or their data.
#
#   bash opencode-install.sh [--method auto|grun|proot]
#
# Why not `npm i -g opencode-ai`: its installer has no Android mapping (it looks for "opencode-android-arm64", which does not exist) and the real
# binary is a glibc Linux executable, which Android's own libc cannot run. So this script:
#   1 downloads the linux-arm64 binary straight from the npm registry and VERIFIES its sha512 against the registry,
#   2 gives it glibc: first Termux's glibc-runner (light), else Debian under proot-distro (heavier, well established),
#   3 only counts a method as working if it actually RUNS `opencode --version`,
#   4 writes the config (only our two providers) and the `opencode-free` launcher.
# If no method works it says so and leaves nothing half-configured as "installed".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
OC="$GW_HOME/opencode"; BIN="$OC/bin/opencode"; VERSION="${OPENCODE_VERSION:-1.19.5}"; METHOD=auto
while [ $# -gt 0 ]; do case "$1" in --method) METHOD="${2:-auto}"; shift;; -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;; *) die "unknown option $1";; esac; shift; done
case "$METHOD" in auto|grun|proot) ;; *) die "--method must be auto, grun or proot";; esac

fail() { err "$1"; printf '\n  What to do: %s\n  Nothing is marked as installed. Your gateways and their data were not touched.\n' "$2" >&2; exit 1; }
runs_ok() { # runs_ok CMD... : the binary must really start and print a version
  local out; out="$(timeout "${OC_VERIFY_TIMEOUT:-120}" "$@" 2>&1 | head -n 5)"
  printf '%s\n' "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'
}
verify_grun() {
  have grun || { have pkg && info "installing glibc-runner (Termux package)" && pkg install -y glibc-repo glibc-runner >/dev/null 2>&1; }
  have grun || { warn "glibc-runner is not available on this Termux"; return 1; }
  runs_ok grun "$BIN" --version
}
PROOT=(proot-distro login debian --shared-tmp --bind "$HOME:$HOME" --bind "$GW_HOME:$GW_HOME" --)   # a plain command prefix: timeout cannot run shell functions
verify_proot() {
  have proot-distro || { have pkg && info "installing proot-distro (Termux package)" && pkg install -y proot-distro >/dev/null 2>&1; }
  have proot-distro || { warn "proot-distro is not available on this Termux"; return 1; }
  if ! runs_ok "${PROOT[@]}" "$BIN" --version; then
    info "installing the Debian userland for proot-distro (one time, a few hundred MB)"
    proot-distro install debian >/dev/null 2>&1 || warn "proot-distro install debian reported a problem (it may already be installed)"
    runs_ok "${PROOT[@]}" "$BIN" --version
  fi
}

have node && have tar || fail "node and tar are required" "pkg install nodejs tar"
[ -s "$GW_CONFIG_DIR/guard-freellmapi.clientkey" ] && [ -s "$GW_CONFIG_DIR/guard-omniroute.clientkey" ] || fail "the gateway guard keys are missing" "run the gateway bootstrap first: bash $HERE/bootstrap.sh"
mkdir -p "$OC"

info "[1/4] OpenCode $VERSION linux-arm64 binary (checksum-verified)"
node "$HERE/lib/fetch-opencode.mjs" --version "$VERSION" --out "$OC" || fail "could not fetch a verified OpenCode binary" "check the connection and run this command again (it resumes)"

info "[2/4] a glibc environment that really runs it (method: $METHOD)"
chosen=""
if [ -f "$OC/runner" ] && [ "$METHOD" = auto ]; then   # re-run: keep what already works
  case "$(cat "$OC/runner")" in
    grun) have grun && runs_ok grun "$BIN" --version && chosen=grun ;;
    proot) have proot-distro && runs_ok "${PROOT[@]}" "$BIN" --version && chosen=proot ;;
  esac
  [ -n "$chosen" ] && ok "existing method '$chosen' still works (kept)"
fi
if [ -z "$chosen" ] && { [ "$METHOD" = auto ] || [ "$METHOD" = grun ]; }; then info "trying glibc-runner"; verify_grun && chosen=grun; fi
if [ -z "$chosen" ] && { [ "$METHOD" = auto ] || [ "$METHOD" = proot ]; }; then info "trying Debian under proot-distro"; verify_proot && chosen=proot; fi
[ -n "$chosen" ] || fail "neither glibc-runner nor proot-distro could run the OpenCode binary on this phone" "send me the output above; the binary needs glibc 2.17 or newer and nothing else, so one of the two should work once the Termux repositories are reachable (try: termux-change-repo, then pkg update)"
ok "OpenCode starts with method: $chosen"
printf '%s\n' "$chosen" > "$OC/runner"

info "[3/4] config + launcher (only the two guarded gateways are enabled providers)"
bash "$HERE/opencode-setup.sh" config || fail "could not write the OpenCode config" "see the message above"
info "[4/4] verification"
bash "$HERE/opencode-setup.sh" check || fail "the generated config failed its own free-only check" "see the message above; do not use OpenCode until this passes"
ver="$("$GW_HOME/bin/opencode-free" --version 2>&1 | head -n 1)"
ok "launcher runs OpenCode: $ver"
cat <<EOF

OpenCode is installed and configured. Start it in any project folder with:

    $GW_HOME/bin/opencode-free

It can use ONLY the two guarded gateways (FreeLLMAPI gpt-oss-20b, OmniRoute ovhanon/gpt-oss-120b); every other provider is disabled.
Expect OVH's anonymous limit of 2 requests/minute/model: tasks are slow. Check usage any time:  bash $HERE/gateways.sh usage
End-to-end acceptance (real coding tasks, ~10-20 minutes):  bash $HERE/opencode-accept.sh
EOF
