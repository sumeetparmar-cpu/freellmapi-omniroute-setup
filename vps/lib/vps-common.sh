#!/usr/bin/env bash
# Shared helpers for the VPS toolkit. Source, do not execute. Reuses the tested helpers in termux/lib/common.sh.
# shellcheck disable=SC2034  # constants are consumed by the scripts that source this file
# shellcheck shell=bash

_VPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../termux/lib/common.sh
. "$_VPS_LIB_DIR/../../termux/lib/common.sh"

# ---- layout & identities (all overridable for tests) ------------------------------------------------
LLM_ROOT="${LLM_ROOT:-/srv/llm}"
LLM_USER_FREELLMAPI="${LLM_USER_FREELLMAPI:-llmfree}"
LLM_USER_OMNIROUTE="${LLM_USER_OMNIROUTE:-llmomni}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMD_RUN_DIR="${SYSTEMD_RUN_DIR:-/run/systemd/system}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
TARGET_OS_ID="ubuntu"; TARGET_OS_VERSION="26.04"

# Default ports (only used if free; preflight proposes alternatives).
DEFAULT_PORT_FREELLMAPI=3001; DEFAULT_PORT_OMNIROUTE=20128
ALT_PORTS_FREELLMAPI="13001 13101 13201 23001"; ALT_PORTS_OMNIROUTE="23128 23228 23328 30128"

# Node runtime: official tarball, SHA-256 pinned here (copied from https://nodejs.org/dist/v24.11.0/SHASUMS256.txt).
NODE_VERSION="${NODE_VERSION:-24.11.0}"
NODE_SHA256_x64="${NODE_SHA256_x64:-b3c071cdf47aab867c3b2aa287257df12ec5d7c962bf922b32fd33226c4295fd}"
NODE_SHA256_arm64="${NODE_SHA256_arm64:-4786d00c4d259d3ff0b2328307f764ef3ced65f2d6e9502d433e68d66238509d}"
NODE_DIST_URL="${NODE_DIST_URL:-https://nodejs.org/dist}"

# Resource thresholds (toolkit heuristics, not upstream requirements).
MIN_DISK_GB="${MIN_DISK_GB:-6}"; WARN_DISK_GB="${WARN_DISK_GB:-10}"
MIN_RAM_MB="${MIN_RAM_MB:-1536}"; WARN_RAM_MB="${WARN_RAM_MB:-3072}"
MIN_AVAIL_MB="${MIN_AVAIL_MB:-1200}"; WARN_AVAIL_MB="${WARN_AVAIL_MB:-2000}"

gw_user()  { case "$1" in freellmapi) echo "$LLM_USER_FREELLMAPI";; omniroute) echo "$LLM_USER_OMNIROUTE";; *) die "unknown gateway '$1' (freellmapi|omniroute)";; esac; }
gw_home()  { echo "$LLM_ROOT/$1"; }
gw_unit()  { echo "llm-$1.service"; }
valid_gw() { case "$1" in freellmapi|omniroute) return 0;; *) return 1;; esac; }
is_root()  { [ "$(id -u)" = 0 ]; }
os_field() { # os_field KEY -> value from os-release (quotes stripped)
  [ -r "$OS_RELEASE" ] || return 1
  local v; v="$(grep -E "^$1=" "$OS_RELEASE" | head -n1 | cut -d= -f2-)"; v="${v%\"}"; v="${v#\"}"; printf '%s' "$v"
}
node_arch() { case "$(uname -m)" in x86_64|amd64) echo x64;; aarch64|arm64) echo arm64;; *) return 1;; esac; }
mem_kb() { awk -v k="$1:" '$1==k{print $2}' "$MEMINFO_FILE"; }
valid_port() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }

# ---- listeners: "addr<TAB>port<TAB>process" ------------------------------------------------------------
# Uses `ss` when present (process names need root); otherwise parses /proc/net/tcp{,6} (no process names).
listeners() {
  if [ -n "${LISTENERS_FILE:-}" ]; then cat "$LISTENERS_FILE"; return 0; fi   # test hook
  if have ss; then
    ss -ltnpH 2>/dev/null | awk '{
      n=split($4,a,":"); port=a[n]; addr=substr($4,1,length($4)-length(port)-1); gsub(/[\[\]]/,"",addr)
      proc=""; if (match($0,/users:\(\("[^"]+"/)) { proc=substr($0,RSTART+9,RLENGTH-10) }
      print addr "\t" port "\t" proc }'
    return 0
  fi
  local f
  for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    awk -v v6="$([ "$f" = /proc/net/tcp6 ] && echo 1 || echo 0)" '
      function hex(s,  i,c,n,d){n=0;for(i=1;i<=length(s);i++){c=substr(s,i,1);d=index("0123456789ABCDEF",toupper(c))-1;n=n*16+d}return n}
      NR>1 && $4=="0A" {
        split($2,p,":"); port=hex(p[2]); a=p[1]
        if (!v6) addr=hex(substr(a,7,2)) "." hex(substr(a,5,2)) "." hex(substr(a,3,2)) "." hex(substr(a,1,2))
        else if (a ~ /^0+$/) addr="::"
        else if (a == "00000000000000000000000001000000") addr="::1"
        else if (a ~ /^0000000000000000FFFF0000/) addr=hex(substr(a,31,2)) "." hex(substr(a,29,2)) "." hex(substr(a,27,2)) "." hex(substr(a,25,2))
        else addr="ipv6:" a
        print addr "\t" port "\t" }' "$f"
  done
}
port_listening() { listeners | awk -F'\t' -v p="$1" '$2==p{f=1} END{exit f?0:1}'; }
# first free port from: preferred, then alternatives (skipping any in $EXCLUDE_PORTS)
pick_free_port() { # pick_free_port PREFERRED "ALT1 ALT2 ..."
  local p
  for p in "$1" $2; do
    case " ${EXCLUDE_PORTS:-} " in *" $p "*) continue;; esac
    port_listening "$p" || { echo "$p"; return 0; }
  done
  return 1
}

# ---- dry-run / apply framework -----------------------------------------------------------------------------
APPLY="${APPLY:-0}"
DEPLOY_LOG="${DEPLOY_LOG:-}"
_log_line() { [ -n "$DEPLOY_LOG" ] && [ -d "$(dirname "$DEPLOY_LOG")" ] && printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$DEPLOY_LOG" 2>/dev/null; return 0; }
# act "why" cmd args...   -> prints (dry-run) or runs (apply). Every state change goes through here.
act() {
  local why="$1"; shift
  if [ "$APPLY" = 1 ]; then
    printf '%s+%s %s\n' "$C_G" "$C_0" "$*" >&2; _log_line "RUN  $* # $why"
    "$@" || { local rc=$?; err "step failed (exit $rc): $*"; _log_line "FAIL $* rc=$rc"; exit 1; }   # never continue after a failed step
  else printf '%sWOULD RUN%s %s\n          effect: %s\n' "$C_Y" "$C_0" "$*" "$why" >&2; fi
}
# write_file PATH MODE OWNER:GROUP "why"  < content
write_file() {
  local path="$1" mode="$2" own="$3" why="$4" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [ "$APPLY" = 1 ]; then
    { install -m "$mode" "$tmp" "$path" && { [ -z "$own" ] || chown "$own" "$path"; }; } || { err "could not write $path"; rm -f "$tmp"; exit 1; }
    printf '%s+%s write %s (mode %s)\n' "$C_G" "$C_0" "$path" "$mode" >&2; _log_line "WRITE $path # $why"
  else printf '%sWOULD WRITE%s %s (mode %s, owner %s)\n          effect: %s\n' "$C_Y" "$C_0" "$path" "$mode" "${own:-root}" "$why" >&2; fi
  rm -f "$tmp"
}
# Refuse obviously dangerous roots before any apply.
assert_safe_root() {
  case "$LLM_ROOT" in /*) ;; *) die "LLM_ROOT must be absolute: $LLM_ROOT";; esac
  [ "$(printf '%s' "$LLM_ROOT" | tr -cd '/' | wc -c)" -ge 2 ] || die "LLM_ROOT too shallow (need e.g. /srv/llm): $LLM_ROOT"
  case "$LLM_ROOT" in /|/etc*|/usr*|/var|/var/lib*|/bin*|/sbin*|/lib*|/boot*|/root*|/home|/opt|/srv|/tmp|/proc*|/sys*|/dev*) die "LLM_ROOT points at a system location: $LLM_ROOT";; esac
}

# Opt-in passthrough of network settings into the scrubbed service-user environment (e.g. an outbound proxy or private CA).
# LLM_PASSTHROUGH_ENV="HTTPS_PROXY NO_PROXY SSL_CERT_FILE"  -> prints VAR=value words for those that are set. Nothing else is inherited.
passthrough_env() {
  local v
  for v in ${LLM_PASSTHROUGH_ENV:-}; do
    case "$v" in *[!A-Za-z0-9_]*|'') continue;; esac
    [ -n "${!v:-}" ] && printf '%s=%s\n' "$v" "${!v}"
  done
  return 0
}
