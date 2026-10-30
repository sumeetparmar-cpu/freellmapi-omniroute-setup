#!/usr/bin/env bash
# FreeLLMAPI manager for Android/Termux (also works on generic Linux for testing).
# Upstream: https://github.com/tashfeenahmed/freellmapi  (MIT)
# Independent from OmniRoute: own dir, data, env file, PID, logs, port (default 3001).
#
#   ./freellmapi.sh install | start | stop | restart | status | health | test-model
#                   backup | list-backups | restore <archive> | update | rollback | rebuild | quota-report | run | logs | uninstall
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

NAME=freellmapi
REPO_URL="${FREELLMAPI_REPO_URL:-https://github.com/tashfeenahmed/freellmapi.git}"
SRC="$GW_HOME/freellmapi"
DATA="$GW_HOME/freellmapi-data"
ENVF="$GW_CONFIG_DIR/freellmapi.env"
# free-guard client-key HASHES (not secret) ride along in backups so a restore does not lock clients out; the upstream key and audit credentials are deliberately NOT backed up (re-create them from the dashboard).
GUARD_CLIENTS="$GW_CONFIG_DIR/free-guard.clients"
LOG="$GW_LOG_DIR/freellmapi.log"
PORT="$FREELLMAPI_PORT"
BASE_URL="http://127.0.0.1:$PORT"

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; cat <<EOF

Options: --yes  --ref <git ref>  --key-file <file>  --model <id>  --base-url <url>  --with-data  --archive <file>
quota-report options: --json  --list-models   (read-only; sends no model requests)
Key for test-model: env FREELLMAPI_KEY, --key-file, or hidden prompt. It is never stored by these scripts.
EOF
}

ASSUME_YES=0; KEY_FILE=""; MODEL="auto"; WITH_DATA=0; ARCHIVE=""; BACKUP_LABEL=""; QR_ARGS=()
ACTION="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --ref) FREELLMAPI_REF="$2"; shift ;;
    --key-file) KEY_FILE="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    --base-url) BASE_URL="$2"; shift ;;
    --with-data) WITH_DATA=1 ;;
    --archive) ARCHIVE="$2"; shift ;;
    --label) BACKUP_LABEL="$2"; shift ;;
    --json|--list-models) QR_ARGS+=("$1") ;;
    -h|--help) usage; exit 0 ;;
    *) ARCHIVE="$1" ;;   # positional: restore <archive>
  esac
  shift
done
export ASSUME_YES

check_prereqs() {
  have node || die "node not found. Termux: pkg install nodejs-lts   (need $(node_range_text freellmapi))"
  have npm  || die "npm not found. Termux: pkg install nodejs-lts"
  have git  || die "git not found. Termux: pkg install git"
  have curl || die "curl not found. Termux: pkg install curl"
  node_ok_freellmapi "$(node_version)" || die "Node $(node_version) unsupported by FreeLLMAPI; need $(node_range_text freellmapi). Termux: pkg upgrade && pkg install nodejs-lts"
  assert_distinct_ports
}

write_env_if_missing() {
  ensure_dirs; mkdir -p "$DATA"; chmod 700 "$DATA"
  if [ -f "$ENVF" ]; then info "keeping existing $ENVF (encryption key preserved)"; return; fi
  ( umask 077
    {
      echo "# FreeLLMAPI runtime config - generated locally. SECRET: never commit."
      echo "ENCRYPTION_KEY=$(gen_hex 32)"
      echo "NODE_ENV=production"
      echo "HOST=$GATEWAY_BIND_HOST"
      echo "PORT=$PORT"
      echo "FREEAPI_DB_PATH=$DATA/freeapi.db"
    } > "$ENVF" )
  chmod 600 "$ENVF"; ok "wrote $ENVF (mode 600)"
}

build() {
  ( cd "$SRC"
    info "npm install (a failing optional better-sqlite3 build is harmless on Android)"
    npm install --no-audit --no-fund
    info "npm run build"
    npm run build )
  node_version > "$GW_STATE_DIR/freellmapi.node_version"
}

# Native modules (better-sqlite3) are compiled for one Node ABI; refuse to start under a different Node.
check_node_unchanged() {
  local f="$GW_STATE_DIR/freellmapi.node_version" built
  [ -f "$f" ] || return 0
  built="$(cat "$f")"
  [ "$built" = "$(node_version)" ] || die "Node changed since FreeLLMAPI was built ($built -> $(node_version)). Switch back, or run: $0 rebuild"
}

cmd_rebuild() {
  check_prereqs; [ -d "$SRC/.git" ] || die "not installed"
  gw_stop $NAME $PORT
  ( cd "$SRC" && npm rebuild ) || warn "npm rebuild reported errors (harmless on Android, which uses node:sqlite)"
  build
  ok "rebuilt for Node $(node_version). Start with: $0 start"
}

cmd_install() {
  check_prereqs
  ensure_dirs
  if [ -d "$SRC/.git" ]; then info "source already at $SRC ($(git -C "$SRC" rev-parse --short HEAD)); use 'update' to move it"
  else
    info "cloning $REPO_URL ($FREELLMAPI_REF)"
    git clone --depth 1 --branch "$FREELLMAPI_REF" "$REPO_URL" "$SRC" 2>/dev/null \
      || { git clone "$REPO_URL" "$SRC" && git -C "$SRC" checkout "$FREELLMAPI_REF"; }
  fi
  write_env_if_missing
  build
  git -C "$SRC" rev-parse HEAD > "$GW_STATE_DIR/freellmapi.installed_commit"
  ok "FreeLLMAPI installed at $(git -C "$SRC" rev-parse --short HEAD). Start it with: $0 start"
  info "Next: open $BASE_URL , create the dashboard account, add provider keys (see docs/PROVIDERS-AND-COSTS.md)."
}

cmd_start() {
  [ -d "$SRC/server/dist" ] || die "not built; run: $0 install"
  assert_distinct_ports
  check_node_unchanged
  if gw_running $NAME; then ok "already running (pid $(gw_pid $NAME))"; return 0; fi
  port_in_use "$PORT" && die "port $PORT is already in use by something else; set FREELLMAPI_PORT to another value"
  ( load_env_file "$ENVF"; cd "$SRC"; daemon_start $NAME "$LOG" node server/dist/index.js )
  info "waiting for $BASE_URL/api/ping ..."
  if wait_for_http "$BASE_URL/api/ping" "${START_TIMEOUT:-60}"; then ok "running (pid $(gw_pid $NAME)) on $GATEWAY_BIND_HOST:$PORT"
  else err "did not become healthy; last log lines:"; tail -n 20 "$LOG" >&2 || true; return 1; fi
  if is_termux && have termux-wake-lock; then info "tip: run termux-wake-lock so Android doesn't suspend the server"; fi
  return 0
}
# Foreground entry point for a service manager (systemd): no PID file, no daemonizing; exec so signals reach node.
cmd_run() {
  [ -d "$SRC/server/dist" ] || die "not built; run: $0 install"
  assert_distinct_ports; check_node_unchanged
  load_env_file "$ENVF"; cd "$SRC"
  exec node server/dist/index.js
}
cmd_stop()   { gw_stop $NAME $PORT; }
cmd_restart(){ cmd_stop; cmd_start; }

cmd_status() {
  if gw_running $NAME; then ok "running pid $(gw_pid $NAME), port $PORT"; else warn "not running"; fi
  [ -d "$SRC/.git" ] && info "version: $(git -C "$SRC" describe --tags --always 2>/dev/null) ($(git -C "$SRC" rev-parse --short HEAD))"
  [ -f "$ENVF" ] && info "config: $ENVF (mode $(stat -c %a "$ENVF" 2>/dev/null || stat -f %Lp "$ENVF"))"
  return 0
}

cmd_health() {
  local code; code="$(http_code "$BASE_URL/api/ping")"
  if [ "$code" = "200" ]; then ok "GET /api/ping -> 200 (public liveness probe)"; else err "GET /api/ping -> $code"; return 1; fi
  local dash; dash="$(http_code "$BASE_URL/")"
  [ "$dash" = "200" ] && ok "dashboard served at / -> 200" || warn "dashboard / -> $dash"
  # /v1/models without a key must be rejected (auth enforced).
  local anon; anon="$(http_code "$BASE_URL/v1/models")"
  case "$anon" in 401|403) ok "/v1/models rejects anonymous requests ($anon)";; 200) warn "/v1/models answered anonymously - check auth!";; *) info "/v1/models anonymous -> $anon";; esac
}

cmd_test_model() {
  local key; key="$(read_api_key FREELLMAPI_KEY "$KEY_FILE")"
  model_test "$BASE_URL" "$key" "$MODEL"
}

cmd_backup() {
  ensure_dirs
  gw_running $NAME && warn "gateway is running; stop it first for a fully consistent SQLite copy (continuing: WAL files are included)"
  local out; out="$(backup_paths $NAME "${1:-manual}" "$ENVF" "$DATA" "$GUARD_CLIENTS")" || return 1
  ok "backup: $out"; warn "This archive contains your ENCRYPTION_KEY and encrypted provider keys. Keep it private; never commit it."
}
cmd_list_backups() { list_backups $NAME; }

cmd_restore() {
  local a="${ARCHIVE:-$(latest_backup $NAME)}"; [ -n "$a" ] || die "no backup to restore"
  confirm "Restore $a over current FreeLLMAPI config+data?" || die "aborted"
  gw_stop $NAME $PORT
  cmd_backup pre-restore >/dev/null || true
  restore_archive "$a" "$ENVF" "$DATA" "$GUARD_CLIENTS"; ok "restored $a (a pre-restore backup was taken). Start with: $0 start"
}

cmd_update() {
  check_prereqs; [ -d "$SRC/.git" ] || die "not installed"
  local was_running=0; gw_running $NAME && was_running=1
  gw_stop $NAME $PORT
  cmd_backup pre-update >/dev/null || true
  git -C "$SRC" rev-parse HEAD > "$GW_STATE_DIR/freellmapi.prev_commit"
  info "previous commit recorded: $(cut -c1-12 "$GW_STATE_DIR/freellmapi.prev_commit")"
  git -C "$SRC" fetch --depth 1 origin "$FREELLMAPI_REF"
  git -C "$SRC" checkout -f FETCH_HEAD
  build
  git -C "$SRC" rev-parse HEAD > "$GW_STATE_DIR/freellmapi.installed_commit"
  ok "updated to $(git -C "$SRC" rev-parse --short HEAD); if it misbehaves: $0 rollback [--with-data]"
  if [ "$was_running" = 1 ]; then cmd_start; fi
}

cmd_rollback() {
  local prev="$GW_STATE_DIR/freellmapi.prev_commit"
  [ -f "$prev" ] || die "no recorded previous version (run 'update' first, or checkout a commit manually in $SRC)"
  local sha; sha="$(cat "$prev")"
  confirm "Roll FreeLLMAPI code back to ${sha:0:12}$([ "$WITH_DATA" = 1 ] && echo ' and restore the pre-update data backup')?" || die "aborted"
  gw_stop $NAME $PORT
  git -C "$SRC" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$SRC" fetch --depth 1 origin "$sha"
  git -C "$SRC" checkout -f "$sha"
  build
  if [ "$WITH_DATA" = 1 ]; then
    local a; a="$(ls -1t "$GW_BACKUP_DIR/$NAME"/*-pre-update.tar.gz 2>/dev/null | head -n1)"
    [ -n "$a" ] || die "no pre-update backup found"
    cmd_backup pre-rollback >/dev/null || true
    restore_archive "$a" "$ENVF" "$DATA" "$GUARD_CLIENTS"; ok "data restored from $a"
  else
    info "data left as-is. Newer DB migrations may not be reversible; use --with-data if the old version fails to start."
  fi
  git -C "$SRC" rev-parse HEAD > "$GW_STATE_DIR/freellmapi.installed_commit"
  ok "rolled back to ${sha:0:12}. Start with: $0 start"
}

# Read-only quota/usage/availability report (tools/quota-report.mjs): GET requests to documented status
# endpoints only, never a model request. The key goes to Node via the environment, never argv or disk.
cmd_quota_report() {
  have node || die "node not found"
  local key; key="$(read_api_key FREELLMAPI_KEY "$KEY_FILE")"
  FREELLMAPI_KEY="$key" node "$HERE/../tools/quota-report.mjs" --gateway freellmapi --base-url "$BASE_URL" ${QR_ARGS[@]+"${QR_ARGS[@]}"}
}

cmd_logs() { tail -n "${LINES:-80}" "$LOG" 2>/dev/null || info "no log yet ($LOG)"; }

cmd_uninstall() {
  confirm "Remove FreeLLMAPI code at $SRC? (config, data and backups are KEPT)" || die "aborted"
  gw_stop $NAME $PORT; rm -rf "$SRC"
  ok "code removed. Kept: $ENVF, $DATA, $GW_BACKUP_DIR/$NAME. Delete those manually only if you are sure."
}

case "$ACTION" in
  install) cmd_install ;; start) cmd_start ;; stop) cmd_stop ;; restart) cmd_restart ;;
  status) cmd_status ;; health) cmd_health ;; test-model) cmd_test_model ;;
  backup) cmd_backup "${BACKUP_LABEL:-manual}" ;; list-backups) cmd_list_backups ;; restore) cmd_restore ;;
  update) cmd_update ;; rollback) cmd_rollback ;; rebuild) cmd_rebuild ;; quota-report) cmd_quota_report ;; run) cmd_run ;; logs) cmd_logs ;; uninstall) cmd_uninstall ;;
  ''|help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
