#!/usr/bin/env bash
# Free-only guard manager for Android/Termux (also works on generic Linux). Runs tools/free-guard.mjs in front of each gateway.
#
#   ./free-guard.sh setup <freellmapi|omniroute> [--key-file F] [--client-key-file F]   mint a client key (printed ONCE, or saved 0600 to --client-key-file) and store the gateway's API key (hidden prompt / --key-file)
#   ./free-guard.sh start|stop|restart|status [freellmapi|omniroute]    (default: both)
#   ./free-guard.sh audit                           FreeLLMAPI: prune non-free models (needs FREELLMAPI_ADMIN_TOKEN); OmniRoute: read-only check
#   ./free-guard.sh watch start|stop|status         background re-audit (default every 60 s): FreeLLMAPI re-syncs its model catalog at every start and every 12 h and can
#                                                   re-enable models that are not verified free; this disables them again (disable-only) and engages the kill switch meanwhile
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
  local kf="" ckf=""; while [ $# -gt 0 ]; do case "$1" in --key-file) kf="${2:-}"; shift;; --client-key-file) ckf="${2:-}"; shift;; *) die "unknown option $1";; esac; shift; done
  need
  # Re-running with --client-key-file is a no-op when this guard already has both files (the client key cannot be shown again).
  if [ -n "$ckf" ] && [ -s "$ckf" ] && [ -s "$(clients "$gw")" ] && [ -s "$(upkey "$gw")" ]; then ok "$gw guard already set up (client key in $ckf)"; return 0; fi
  local key; key="$(GW_KEY="${GW_KEY:-}" read_api_key GW_KEY "$kf")"
  ( umask 077; printf '%s\n' "$key" > "$(upkey "$gw")" ); chmod 600 "$(upkey "$gw")"
  unset key
  ok "stored the $gw gateway key in $(upkey "$gw") (mode 600, never printed)"
  local ck; ck="$(node "$GUARD_JS" --new-client-key "${GUARD_CLIENT_LABEL:-phone}" --client-keys-file "$(clients "$gw")")"
  chmod 600 "$(clients "$gw")"
  if [ -n "$ckf" ]; then
    ( umask 077; printf '%s\n' "$ck" > "$ckf" ); chmod 600 "$ckf"
    ok "guard client key for $gw saved to $ckf (mode 600); only its hash is kept by the guard"
  else
    printf '\nYour %s GUARD key (shown once; only its hash is stored; put it in your client app):\n  %s\n\n' "$gw" "$ck"
  fi
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
  local rc=0
  # The "catalog audited" marker is only valid for the audit that just passed: drop it first, recreate it on success.
  rm -f "$GW_STATE_DIR/freellmapi.catalog-audited"
  info "FreeLLMAPI: disabling every non-free model (disable-only; never enables or deletes)"
  if [ -n "${FREELLMAPI_ADMIN_TOKEN:-}${FREELLMAPI_ADMIN_PASSWORD:-}" ]; then
    if node "$POLICY_JS" freellmapi apply --base-url "http://127.0.0.1:$FREELLMAPI_PORT" --flag-file "$(kill_file freellmapi)"; then
      : > "$GW_STATE_DIR/freellmapi.catalog-audited"; ok "catalog is free-only; restart the FreeLLMAPI guard to accept 'auto'"
    else err "FreeLLMAPI still has non-free models enabled (kill switch engaged)"; rc=1; fi
  else warn "set FREELLMAPI_ADMIN_TOKEN (or EMAIL+PASSWORD) to audit FreeLLMAPI"; rc=1; fi
  if [ -n "${OMNIROUTE_MGMT_TOKEN:-}${OMNIROUTE_ADMIN_PASSWORD:-}" ]; then
    node "$POLICY_JS" omniroute audit --base-url "http://127.0.0.1:$OMNIROUTE_PORT" --flag-file "$(kill_file omniroute)" || { err "OmniRoute has a provider outside the free-only policy (kill switch engaged)"; rc=1; }
  else warn "set OMNIROUTE_MGMT_TOKEN (or OMNIROUTE_ADMIN_PASSWORD) to audit OmniRoute"; rc=1; fi
  return $rc
}

# ---- watcher: the Termux equivalent of the VPS audit timer -------------------------------------------------------------------------------
WATCH_INTERVAL="${FREE_AUDIT_INTERVAL:-60}"
audit_cycle() { # one self-healing audit using the credential files this toolkit wrote; never prints a secret
  (
    # shellcheck disable=SC1091
    [ -f "$GW_CONFIG_DIR/freellmapi.admin" ] && . "$GW_CONFIG_DIR/freellmapi.admin"
    export FREELLMAPI_ADMIN_EMAIL="${FREELLMAPI_ADMIN_EMAIL:-}" FREELLMAPI_ADMIN_PASSWORD="${FREELLMAPI_ADMIN_PASSWORD:-}"
    OMNIROUTE_ADMIN_PASSWORD="${OMNIROUTE_ADMIN_PASSWORD:-$(env_get "$GW_CONFIG_DIR/omniroute.env" INITIAL_PASSWORD 2>/dev/null)}"; export OMNIROUTE_ADMIN_PASSWORD
    local rc=0
    if [ -n "$FREELLMAPI_ADMIN_PASSWORD" ] && port_in_use "$FREELLMAPI_PORT"; then
      node "$POLICY_JS" freellmapi audit --auto-fix --base-url "http://127.0.0.1:$FREELLMAPI_PORT" --flag-file "$(kill_file freellmapi)" || rc=1
    fi
    if [ -n "$OMNIROUTE_ADMIN_PASSWORD" ] && port_in_use "$OMNIROUTE_PORT"; then
      node "$POLICY_JS" omniroute audit --base-url "http://127.0.0.1:$OMNIROUTE_PORT" --flag-file "$(kill_file omniroute)" || rc=1
    fi
    exit $rc
  )
}
cmd_watch() {
  local sub="${1:-}"
  case "$sub" in
    start)
      need
      if gw_running guard-watch; then ok "audit watcher already running (pid $(gw_pid guard-watch))"; return 0; fi
      daemon_start guard-watch "$GW_LOG_DIR/free-guard-watch.log" bash "$HERE/free-guard.sh" watch loop
      sleep 1
      if gw_running guard-watch; then ok "audit watcher running (re-checks every ${WATCH_INTERVAL}s; disable-only; kill switch while a violation exists)"; else err "audit watcher did not start"; return 1; fi ;;
    stop) gw_stop guard-watch ;;
    status) if gw_running guard-watch; then info "audit watcher: running pid $(gw_pid guard-watch), every ${WATCH_INTERVAL}s"; else info "audit watcher: stopped"; fi ;;
    loop) # internal: the daemon body
      need
      while :; do
        if audit_cycle >>"$GW_LOG_DIR/free-guard-watch.log" 2>&1; then :; else printf '%s audit cycle reported a problem (see lines above)\n' "$(timestamp)" >>"$GW_LOG_DIR/free-guard-watch.log"; fi
        sleep "$WATCH_INTERVAL"
      done ;;
    *) die "usage: watch start|stop|status" ;;
  esac
}

ACT="${1:-}"; [ $# -gt 0 ] && shift
case "$ACT" in
  setup) cmd_setup "$@" ;;
  start) need; each start_one "${1:-}" ;;
  stop) need; each stop_one "${1:-}" ;;
  restart) need; each stop_one "${1:-}"; each start_one "${1:-}" ;;
  status) need; each status_one "${1:-}" ;;
  audit) cmd_audit ;;
  watch) cmd_watch "$@" ;;
  logs) valid "${1:-}" || die "usage: logs <freellmapi|omniroute>"; tail -n 50 "$(gwlog "$1")" ;;
  *) usage; exit 2 ;;
esac
