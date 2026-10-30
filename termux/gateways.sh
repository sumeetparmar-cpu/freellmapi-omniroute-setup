#!/usr/bin/env bash
# Day-to-day control of BOTH gateways and their free-only guards (Termux or generic Linux).
#
#   ./gateways.sh start | stop | restart | status | test | keys | doctor | logs <freellmapi|omniroute|guard-freellmapi|guard-omniroute>
#
#   start    FreeLLMAPI, OmniRoute, then both guards (also asks Android to keep Termux awake when termux-wake-lock exists)
#   stop     guards first, then the gateways
#   status   processes, health, guard state, kill switch (read-only)
#   test     one GENUINE completion through each guard (OVH anonymous tier: 2 requests/minute/model)
#   keys     endpoints, models, dashboards and the guard client keys (the secrets of this machine: do not paste them anywhere)
#   doctor   read-only diagnosis with the exact fix for each problem
# Everything binds to 127.0.0.1. Nothing is exposed; no paid provider is configured and the guards refuse paid models.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
GUARD_PORT_FREELLMAPI="${GUARD_PORT_FREELLMAPI:-3101}"
GUARD_PORT_OMNIROUTE="${GUARD_PORT_OMNIROUTE:-20228}"
FL_MODEL="${FL_MODEL:-gpt-oss-20b}"
OR_MODEL="${OR_MODEL:-ovhanon/gpt-oss-120b}"
FL_CKEY="$GW_CONFIG_DIR/guard-freellmapi.clientkey"
OR_CKEY="$GW_CONFIG_DIR/guard-omniroute.clientkey"

FL() { bash "$HERE/freellmapi.sh" "$@"; }
OR() { bash "$HERE/omniroute.sh" "$@"; }
GD() { bash "$HERE/free-guard.sh" "$@"; }
need_node() { have node || die "node not found (Termux: pkg install nodejs)"; }

wake() { if is_termux && have termux-wake-lock; then termux-wake-lock 2>/dev/null && info "wake lock held: Android should not suspend Termux (release with termux-wake-unlock)"; fi; }

cmd_start() {
  need_node; wake
  local rc=0
  FL start || rc=1
  OR start || rc=1
  GD start || rc=1
  GD watch start || rc=1
  [ "$rc" -eq 0 ] && ok "all four processes are up" || err "something failed to start: run  $0 doctor"
  return $rc
}
cmd_stop() { GD watch stop || true; GD stop || true; OR stop || true; FL stop || true; }

cmd_status() {
  local fl or
  fl="$(http_code "http://127.0.0.1:$FREELLMAPI_PORT/api/ping")"; or="$(http_code "http://127.0.0.1:$OMNIROUTE_PORT/api/health/ping")"
  info "FreeLLMAPI  $(gw_running freellmapi && echo "running pid $(gw_pid freellmapi)" || echo stopped)   health HTTP $fl   127.0.0.1:$FREELLMAPI_PORT"
  info "OmniRoute   $(gw_running omniroute && echo "running pid $(gw_pid omniroute)" || echo stopped)   health HTTP $or   127.0.0.1:$OMNIROUTE_PORT"
  GD status; GD watch status
}

run_test() { # run_test NAME PORT KEYFILE MODEL
  [ -s "$3" ] || { err "$1: no guard key at $3 (run termux/bootstrap.sh first)"; return 1; }
  node "$HERE/lib/infer.mjs" --name "$1" --base "http://127.0.0.1:$2/v1" --key-file "$3" --model "$4"
}
cmd_test() {
  need_node
  local rc=0
  run_test "FreeLLMAPI" "$GUARD_PORT_FREELLMAPI" "$FL_CKEY" "$FL_MODEL" || rc=1
  run_test "OmniRoute" "$GUARD_PORT_OMNIROUTE" "$OR_CKEY" "$OR_MODEL" || rc=1
  [ "$rc" -eq 0 ] || warn "a FAIL above with HTTP 429 means OVH's anonymous limit (2 requests/minute/model per IP): wait a minute and run  $0 test"
  return $rc
}

cmd_keys() {
  cat <<EOF
== Endpoints (use these from apps on this phone) ==============================
FreeLLMAPI  http://127.0.0.1:$GUARD_PORT_FREELLMAPI/v1     model: $FL_MODEL
OmniRoute   http://127.0.0.1:$GUARD_PORT_OMNIROUTE/v1    model: $OR_MODEL
  (OpenAI-compatible: POST /chat/completions, GET /models. The guards allow only free models; paid names get HTTP 403.)
  Note: OmniRoute's /models list does NOT show the OVH model; type the model name yourself ($OR_MODEL) in apps that offer a free-text model field.
== Dashboards (open in the phone's browser) ===================================
FreeLLMAPI  http://127.0.0.1:$FREELLMAPI_PORT      login: $(grep -s '^FREELLMAPI_ADMIN_EMAIL=' "$GW_CONFIG_DIR/freellmapi.admin" | cut -d= -f2-)  (password: $GW_CONFIG_DIR/freellmapi.admin)
OmniRoute   http://127.0.0.1:$OMNIROUTE_PORT      password: bash '$HERE/omniroute.sh' credentials
== Guard client keys (secret; files are mode 600) =============================
EOF
  local f n
  for n in freellmapi omniroute; do
    f="$GW_CONFIG_DIR/guard-$n.clientkey"
    if [ -s "$f" ]; then printf '%-11s %s\n' "$n" "$(head -n1 "$f")"; else printf '%-11s (not set up)\n' "$n"; fi
  done
  echo "Do NOT use the raw gateway ports ($FREELLMAPI_PORT / $OMNIROUTE_PORT) from apps: they list paid model names."
}

cmd_doctor() {
  local bad=0 c
  say() { printf '%s\n' "$*"; }
  problem() { err "$1"; say "    fix: $2"; bad=$((bad + 1)); }
  have node && ok "node $(node_version)" || problem "node missing" "pkg install nodejs"
  [ -d "$GW_HOME/freellmapi/server/dist" ] || problem "FreeLLMAPI is not installed/built" "re-run termux/bootstrap.sh"
  [ -d "$GW_HOME/omniroute/node_modules/omniroute" ] || problem "OmniRoute is not installed" "re-run termux/bootstrap.sh"
  for c in "freellmapi:$FREELLMAPI_PORT:api/ping" "omniroute:$OMNIROUTE_PORT:api/health/ping"; do
    IFS=: read -r n p path <<<"$c"
    if [ "$(http_code "http://127.0.0.1:$p/$path")" = 200 ]; then ok "$n healthy on :$p"
    elif gw_running "$n"; then problem "$n is running but not answering on :$p" "wait a minute (OmniRoute is slow to start), then  $0 restart; logs:  $0 logs $n"
    elif port_in_use "$p"; then problem "port $p is used by another program" "stop that program or set a different port in $GW_CONFIG_DIR/gateways.env"
    else problem "$n is stopped" "$0 start"; fi
  done
  for c in "freellmapi:$GUARD_PORT_FREELLMAPI" "omniroute:$GUARD_PORT_OMNIROUTE"; do
    IFS=: read -r n p <<<"$c"
    if [ "$(http_code "http://127.0.0.1:$p/__guard/status")" = 200 ]; then ok "$n guard answers on :$p"; else problem "$n guard is not answering on :$p" "$0 start   (logs: $0 logs guard-$n)"; fi
    [ -e "$GW_STATE_DIR/free-audit-$n.flag" ] && problem "free-only KILL SWITCH is engaged for $n (a policy violation was found; inference is refused)" "FREELLMAPI_ADMIN_EMAIL/PASSWORD from $GW_CONFIG_DIR/freellmapi.admin, then  ./termux/free-guard.sh audit"
    [ -s "$GW_CONFIG_DIR/guard-$n.clientkey" ] || problem "no guard key for $n" "re-run termux/bootstrap.sh"
  done
  if gw_running guard-watch; then ok "free-only audit watcher running"; else problem "the free-only audit watcher is not running (catalog drift would go unnoticed)" "$0 start"; fi
  local free_mb; free_mb=$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "${free_mb:-}" ] && [ "$free_mb" -lt 500 ] && problem "only ${free_mb} MB of storage left" "free some space (backups: $GW_BACKUP_DIR)"
  if is_termux && ! have termux-wake-lock; then warn "termux-api not installed: Android may suspend the servers when the screen is off (pkg install termux-api)"; fi
  [ "$bad" -eq 0 ] && ok "no problems found" || { err "$bad problem(s) found"; return 1; }
}

cmd_logs() {
  case "${1:-}" in
    freellmapi) tail -n 60 "$GW_LOG_DIR/freellmapi.log" ;;
    omniroute) tail -n 60 "$GW_LOG_DIR/omniroute.log" ;;
    guard-freellmapi) tail -n 40 "$GW_LOG_DIR/free-guard-freellmapi.log" ;;
    guard-omniroute) tail -n 40 "$GW_LOG_DIR/free-guard-omniroute.log" ;;
    *) die "usage: logs <freellmapi|omniroute|guard-freellmapi|guard-omniroute>" ;;
  esac
}

ACT="${1:-}"; [ $# -gt 0 ] && shift
case "$ACT" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status) cmd_status ;;
  test) cmd_test ;;
  keys) cmd_keys ;;
  doctor) cmd_doctor ;;
  logs) cmd_logs "$@" ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
