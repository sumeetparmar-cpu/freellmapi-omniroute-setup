#!/usr/bin/env bash
# Read-only environment audit for running FreeLLMAPI + OmniRoute side by side.
# Changes nothing, sends no credentials. Exit 0 = no blockers, 1 = at least one blocker.
#   ./audit-env.sh [--offline] [--only freellmapi|omniroute]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

OFFLINE=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in --offline) OFFLINE=1 ;; --only) ONLY="$2"; shift ;; -h|--help) sed -n '2,5p' "$0"; exit 0 ;; esac
  shift
done
BLOCKERS=0; WARNINGS=0
pass()    { ok "$*"; }
blocker() { err "BLOCKER: $*"; BLOCKERS=$((BLOCKERS + 1)); }
caution() { warn "$*"; WARNINGS=$((WARNINGS + 1)); }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

echo "== Platform =="
info "uname: $(uname -srm)"
if is_termux; then pass "Termux detected (TERMUX_VERSION=${TERMUX_VERSION:-unknown})"
  [ -n "${ANDROID_ROOT:-}" ] && info "Android root: $ANDROID_ROOT"
  have getprop && info "Android $(getprop ro.build.version.release 2>/dev/null) / SDK $(getprop ro.build.version.sdk 2>/dev/null)"
else caution "Not Termux: fine for testing, but this audit is meant for the phone"; fi
case "$(uname -m)" in aarch64|arm64|x86_64|amd64) pass "architecture $(uname -m)";; *) caution "uncommon architecture $(uname -m): native modules may lack prebuilt binaries";; esac

echo "== Resources =="
if [ -r /proc/meminfo ]; then
  mem_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  if [ "$mem_mb" -ge 3000 ]; then pass "RAM ${mem_mb} MB"; elif [ "$mem_mb" -ge 1500 ]; then caution "RAM ${mem_mb} MB: running both gateways together may be tight; start one at a time"; else blocker "RAM ${mem_mb} MB is too low for the OmniRoute/Next.js server"; fi
fi
free_mb=$(df -Pm "${HOME}" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${free_mb:-}" ]; then
  if [ "$free_mb" -ge 3000 ]; then pass "free disk ${free_mb} MB in \$HOME"; elif [ "$free_mb" -ge 1500 ]; then caution "free disk ${free_mb} MB (FreeLLMAPI ~1 GB + OmniRoute ~1 GB recommended: 3 GB)"; else blocker "free disk ${free_mb} MB; need ~3 GB for both"; fi
fi

echo "== Tooling =="
for t in curl git openssl tar; do
  if have "$t"; then
    case "$t" in openssl) v="$(openssl version 2>&1 | head -n1)";; *) v="$($t --version 2>&1 | head -n1)";; esac
    pass "$t: ${v:0:60}"
  else
    case "$t" in openssl) caution "openssl missing (key generation falls back to Node)";; *) blocker "$t missing. Termux: pkg install $t";; esac; fi
done
if have node; then
  nv="$(node_version)"; info "node $nv, npm $(npm -v 2>/dev/null || echo '?')"
  want freellmapi && { if node_ok_freellmapi "$nv"; then pass "Node OK for FreeLLMAPI ($(node_range_text freellmapi))"; else blocker "Node $nv not OK for FreeLLMAPI; need $(node_range_text freellmapi)"; fi
    if is_termux; then node -e 'require("node:sqlite")' 2>/dev/null && pass "node:sqlite available" || blocker "node:sqlite unavailable (needed on Android)"; fi; }
  want omniroute && { if node_ok_omniroute "$nv"; then pass "Node OK for OmniRoute ($(node_range_text omniroute))"; else blocker "Node $nv not OK for OmniRoute; need $(node_range_text omniroute)"; fi; }
else blocker "node missing. Termux: pkg install nodejs"; fi
have setsid || caution "setsid missing: 'stop' cannot signal the whole process group and may leave a child server running (Termux: pkg install util-linux)"
if is_termux; then
  have python || caution "python missing (OmniRoute native deps may need it). pkg install python build-essential"
  have make || caution "make/build-essential missing (only needed if a native module has no prebuilt binary)"
  have termux-wake-lock && pass "termux-api present (wake lock available)" || caution "termux-api missing: Android may suspend servers when the screen is off (pkg install termux-api + Termux:API app)"
fi

echo "== Ports =="
if [ "$FREELLMAPI_PORT" = "$OMNIROUTE_PORT" ]; then blocker "both gateways configured for port $FREELLMAPI_PORT"; else pass "distinct ports: FreeLLMAPI=$FREELLMAPI_PORT OmniRoute=$OMNIROUTE_PORT"; fi
for pair in "freellmapi:$FREELLMAPI_PORT" "omniroute:$OMNIROUTE_PORT"; do
  g="${pair%%:*}"; p="${pair##*:}"; want "$g" || continue
  if port_in_use "$p"; then
    if gw_running "$g"; then pass "$g already running on $p (managed by these scripts)"; else blocker "port $p is in use by another process (not managed $g)"; fi
  else pass "port $p free"; fi
done
[ "$GATEWAY_BIND_HOST" = "127.0.0.1" ] && pass "bind host 127.0.0.1 (device-local)" || caution "bind host $GATEWAY_BIND_HOST exposes the gateways to the network"

echo "== Network (reachability only; no credentials sent) =="
if [ "$OFFLINE" = 1 ]; then info "skipped (--offline)"; else
  c="$(HTTP_TIMEOUT=15 http_code https://registry.npmjs.org/omniroute)"
  case "$c" in 2*|3*) pass "npm registry -> $c";; *) caution "npm registry -> $c (OmniRoute install/update will fail)";; esac
  # git protocol check: github.com web pages can be blocked by proxies while git still works.
  if want freellmapi; then
    if timeout 30 git ls-remote --heads https://github.com/tashfeenahmed/freellmapi.git HEAD >/dev/null 2>&1; then pass "git can reach tashfeenahmed/freellmapi"; else caution "git cannot reach tashfeenahmed/freellmapi (FreeLLMAPI install/update will fail)"; fi
  fi
fi

echo "== Existing installs & secrets hygiene =="
for g in freellmapi omniroute; do
  want "$g" || continue
  f="$GW_CONFIG_DIR/$g.env"
  if [ -f "$f" ]; then
    mode="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")"
    [ "$mode" = "600" ] && pass "$f mode 600" || caution "$f mode $mode; run: chmod 600 $f"
  else info "$g not configured yet ($f absent)"; fi
done
repo_root="$(cd "$HERE/.." && pwd)"
if have git && git -C "$repo_root" rev-parse >/dev/null 2>&1; then
  tracked_env="$(git -C "$repo_root" ls-files | grep -E '(^|/)\.env($|\.)|\.sqlite$|\.db$|\.pem$' | grep -v '\.example$' || true)"
  [ -z "$tracked_env" ] && pass "no env/db/key files tracked in this repo" || blocker "secret-like files tracked in Git: $tracked_env"
fi

echo
echo "Summary: $BLOCKERS blocker(s), $WARNINGS warning(s)"
[ "$BLOCKERS" -eq 0 ]
