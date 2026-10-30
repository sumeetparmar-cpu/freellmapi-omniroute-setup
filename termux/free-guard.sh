#!/usr/bin/env bash
# Free-only guard manager for Android/Termux (also works on generic Linux). Runs tools/free-guard.mjs in front of each gateway.
#
#   ./free-guard.sh setup <freellmapi|omniroute>   mint a client key (printed ONCE) and store the gateway's API key (hidden prompt / --key-file)
#   ./free-guard.sh start|stop|restart|status [freellmapi|omniroute]    (default: both)
#   ./free-guard.sh audit                           FreeLLMAPI: prune non-free models (needs FREELLMAPI_ADMIN_TOKEN); OmniRoute: read-only check
#   ./free-guard.sh logs <freellmapi|omniroute>
#
# Clients use the GUARD ports (FreeLLMAPI 3101, OmniRoute 20228) with the guard key; the gateway's own key stays in a 0600 file.
# Never touches the gateways themselves. Nothing here is sent anywhere except loopback.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
GUARD_JS="$ROOT_DIR/tools/free-guard.mjs"
POLICY_JS="$ROOT_DIR/tools/free-policy.mjs"
GUARD_PORT_FREELLMAPI="${GUARD_PORT_FREELLMAPI:-3101}"
GUARD_PORT_OMNIROUTE="${GUARD_PORT_OMNIROUTE:-20228}"

valid() { case "${1:-}" in freellmapi|omniroute) return 0;; *) return 1;; esac; }
gport()   { case "$1" in freellmapi) echo "$GUARD_PORT_FREELLMAPI";; omniroute) echo "$GUARD_PORT_OMNIROUTE";; esac; }
upport()  { case "$1" in freellmapi) echo "$FREELLMAPI_PORT";; omniroute) echo "$OMNIROUTE_PORT";; esac; }
clients() { echo "$GW_CONFIG_DIR/free-guard-$1.clients"; }
upkey()   { echo "$GW_CONFIG_DIR/free-guard-$1.upstream.key"; }
pname()   { echo "guard-$1"; }
gwlog()   { echo "$GW_LOG_DIR/free-guard-$1.log"; }
kill_file() { echo "$GW_STATE_DIR/free-audit-$1.flag"; }

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

need() {
  have node || die "node not found (Termux: pkg install nodejs)"
  [ -f "$GUARD_JS" ] || die "tools/free-guard.mjs not found next to this script"
  ensure_dirs; mkdir -p "$GW_STATE_DIR"
}

cmd_setup() {
  local gw="${1:-}"; valid "$gw" || die "usage: setup <freellmapi|omniroute> [--key-file F]"; shift
  local kf=""; while [ $# -gt 0 ]; do case "$1" in --key-file) kf="${2:-}"; shift;; *) die "unknown option $1";; esac; shift; done
  need
  local key; key="$(GW_KEY="${GW_KEY:-}" read_api_key GW_KEY "$kf")"
  ( umask 077; printf '%s\n' "$key" > "$(upkey "$gw")" ); chmod 600 "$(upkey "$gw")"
  unset key
  ok "stored the $gw gateway key in $(upkey "$gw") (mode 600, never printed)"
  local ck; ck="$(node "$GUARD_JS" --new-client-key "${GUARD_CLIENT_LABEL:-phone}" --client-keys-file "$(clients "$gw")")"
  chmod 600 "$(clients "$gw")"
  printf '\nYour %s GUARD key (shown once; only its hash is stored; put it in your client app):\n  %s\n\n' "$gw" "$ck"
  info "client base URL: http://127.0.0.1:$(gport "$gw")/v1"
}

guard_args() {
  local gw="$1"
  local a=(--gateway "$gw" --upstream "http://127.0.0.1:$(upport "$gw")" --listen "127.0.0.1:$(gport "$gw")"
           --state "$GW_STATE_DIR/free-guard-$gw.json" --log "$(gwlog "$gw")" --kill-file "$(kill_file "$gw")"
           --client-keys-file "$(clients "$gw")" --upstream-key-file "$(upkey "$gw")")
  # FreeLLMAPI: only after the catalog was pruned ('audit' clean) may auto/grouped ids pass (docs/FREE-ONLY.md).
  if [ "$gw" = freellmapi ] && [ -f "$GW_STATE_DIR/freellmapi.catalog-audited" ]; then a+=(--catalog-audited); fi
  printf '%s\n' "${a[@]}"
}

start_one() {
  local gw="$1" n; n="$(pname "$gw")"
  [ -s "$(clients "$gw")" ] && [ -s "$(upkey "$gw")" ] || die "$gw guard not set up: run  free-guard.sh setup $gw  first"
  if gw_running "$n"; then ok "$gw guard already running (pid $(gw_pid "$n"))"; return 0; fi
  port_in_use "$(gport "$gw")" && die "guard port $(gport "$gw") is already in use"
  local args=(); while IFS= read -r l; do args+=("$l"); done < <(guard_args "$gw")
  daemon_start "$n" "$(gwlog "$gw")" node "$GUARD_JS" "${args[@]}"
  if wait_for_http "http://127.0.0.1:$(gport "$gw")/__guard/status" 15; then ok "$gw guard running on 127.0.0.1:$(gport "$gw") (pid $(gw_pid "$n"))"
  else err "$gw guard did not answer; last log lines:"; tail -n 5 "$(gwlog "$gw")" >&2 2>/dev/null || true; gw_stop "$n" >/dev/null 2>&1 || true; return 1; fi
}

each() { # each fn [gw]
  local fn="$1" gw="${2:-}"
  if [ -n "$gw" ]; then valid "$gw" || die "gateway must be freellmapi or omniroute"; "$fn" "$gw"; else "$fn" freellmapi; "$fn" omniroute; fi
}
stop_one() { gw_stop "$(pname "$1")" "$(gport "$1")"; }
status_one() {
  local gw="$1" n; n="$(pname "$gw")"
  if gw_running "$n"; then info "$gw guard: running pid $(gw_pid "$n") port $(gport "$gw") kill-switch=$([ -e "$(kill_file "$gw")" ] && echo ENGAGED || echo off)"; else info "$gw guard: stopped"; fi
}

cmd_audit() {
  need; [ -f "$POLICY_JS" ] || die "tools/free-policy.mjs not found"
  info "FreeLLMAPI: disabling every non-free model (disable-only; never enables or deletes)"
  if [ -n "${FREELLMAPI_ADMIN_TOKEN:-}${FREELLMAPI_ADMIN_PASSWORD:-}" ]; then
    node "$POLICY_JS" freellmapi apply --base-url "http://127.0.0.1:$FREELLMAPI_PORT" --flag-file "$(kill_file freellmapi)" && : > "$GW_STATE_DIR/freellmapi.catalog-audited" && ok "catalog is free-only; restart the FreeLLMAPI guard to accept 'auto'"
  else warn "set FREELLMAPI_ADMIN_TOKEN (or EMAIL+PASSWORD) to audit FreeLLMAPI"; fi
  if [ -n "${OMNIROUTE_MGMT_TOKEN:-}${OMNIROUTE_ADMIN_PASSWORD:-}" ]; then
    node "$POLICY_JS" omniroute audit --base-url "http://127.0.0.1:$OMNIROUTE_PORT" --flag-file "$(kill_file omniroute)" || true
  else warn "set OMNIROUTE_MGMT_TOKEN (or OMNIROUTE_ADMIN_PASSWORD) to audit OmniRoute"; fi
}

ACT="${1:-}"; [ $# -gt 0 ] && shift
case "$ACT" in
  setup) cmd_setup "$@" ;;
  start) need; each start_one "${1:-}" ;;
  stop) need; each stop_one "${1:-}" ;;
  restart) need; each stop_one "${1:-}"; each start_one "${1:-}" ;;
  status) need; each status_one "${1:-}" ;;
  audit) cmd_audit ;;
  logs) valid "${1:-}" || die "usage: logs <freellmapi|omniroute>"; tail -n 50 "$(gwlog "$1")" ;;
  *) usage; exit 2 ;;
esac
