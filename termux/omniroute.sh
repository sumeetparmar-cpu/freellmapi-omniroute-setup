#!/usr/bin/env bash
# OmniRoute manager for Android/Termux (also works on generic Linux for testing).
# Upstream: https://github.com/cheaper-inference/OmniRoute  (npm package: omniroute)
# Independent from FreeLLMAPI: own prefix, data dir, env file, PID, logs, port (default 20128).
#
#   ./omniroute.sh install | start | stop | restart | status | health | test-model | credentials
#                  backup | list-backups | restore <archive> | update | rollback | rebuild | logs | uninstall
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

NAME=omniroute
PREFIX="$GW_HOME/omniroute"
DATA="$GW_HOME/omniroute-data"
ENVF="$GW_CONFIG_DIR/omniroute.env"
LOG="$GW_LOG_DIR/omniroute.log"
PORT="$OMNIROUTE_PORT"
BASE_URL="http://127.0.0.1:$PORT"
ENTRY="$PREFIX/node_modules/omniroute/bin/omniroute.mjs"
ALLOW_SCRIPTS="omniroute,keytar,onnxruntime-node,@parcel/watcher,@swc/core,protobufjs,esbuild"

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options: --yes  --version <npm version>  --key-file <file>  --model <provider/model> (required for test-model)  --base-url <url>  --with-data  --archive <file>
Key for test-model: env OMNIROUTE_KEY (create one in Dashboard -> Endpoints), --key-file, or hidden prompt. Never stored here.
EOF
}

ASSUME_YES=0; KEY_FILE=""; MODEL=""; WITH_DATA=0; ARCHIVE=""
ACTION="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --version) OMNIROUTE_VERSION="$2"; shift ;;
    --key-file) KEY_FILE="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    --base-url) BASE_URL="$2"; shift ;;
    --with-data) WITH_DATA=1 ;;
    --archive) ARCHIVE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) ARCHIVE="$1" ;;
  esac
  shift
done
export ASSUME_YES

installed_version() { node -p 'require(process.argv[1]).version' "$PREFIX/node_modules/omniroute/package.json" 2>/dev/null || true; }

check_prereqs() {
  have node || die "node not found. Termux: pkg install nodejs   (need $(node_range_text omniroute))"
  have npm  || die "npm not found. Termux: pkg install nodejs"
  have curl || die "curl not found. Termux: pkg install curl"
  node_ok_omniroute "$(node_version)" || die "Node $(node_version) unsupported by OmniRoute; need $(node_range_text omniroute). Termux: pkg upgrade && pkg install nodejs (nodejs-lts may be too old)"
  assert_distinct_ports
  if is_termux; then have python || warn "python missing: native deps may fail to build. Termux: pkg install python build-essential"; fi
}

write_env_if_missing() {
  ensure_dirs; mkdir -p "$DATA"; chmod 700 "$DATA"
  if [ -f "$ENVF" ]; then info "keeping existing $ENVF (encryption key + password preserved)"; return; fi
  ( umask 077
    {
      echo "# OmniRoute runtime config - generated locally. SECRET: never commit."
      echo "JWT_SECRET=$(gen_hex 48)"
      echo "API_KEY_SECRET=$(gen_hex 32)"
      echo "STORAGE_ENCRYPTION_KEY=$(gen_hex 32)"
      echo "INITIAL_PASSWORD=$(gen_hex 12)"
      echo "REQUIRE_API_KEY=true"
      echo "AUTH_COOKIE_SECURE=false"
      echo "DATA_DIR=$DATA"
      echo "OMNIROUTE_SERVER_HOST=$GATEWAY_BIND_HOST"
      echo "OMNIROUTE_HEADLESS=1"
      echo "PORT=$PORT"
    } > "$ENVF" )
  chmod 600 "$ENVF"; ok "wrote $ENVF (mode 600)"
}

npm_install_omniroute() { # npm_install_omniroute VERSION
  mkdir -p "$PREFIX"
  local npm_major args=(install --prefix "$PREFIX" --no-audit --no-fund "omniroute@$1")
  npm_major="$(npm -v | cut -d. -f1)"
  # npm >= 11 blocks lifecycle scripts unless allowed (upstream README, Quick Start).
  [ "$npm_major" -ge 11 ] && args+=("--allow-scripts=$ALLOW_SCRIPTS")
  npm "${args[@]}"
  node_version > "$GW_STATE_DIR/omniroute.node_version"
}

# Native modules are compiled for one Node ABI; refuse to start under a different Node.
check_node_unchanged() {
  local f="$GW_STATE_DIR/omniroute.node_version" built
  [ -f "$f" ] || return 0
  built="$(cat "$f")"
  [ "$built" = "$(node_version)" ] || die "Node changed since OmniRoute was installed ($built -> $(node_version)). Switch back, or run: $0 rebuild"
}

cmd_rebuild() {
  check_prereqs; [ -f "$ENTRY" ] || die "not installed"
  gw_stop $NAME $PORT
  npm rebuild --prefix "$PREFIX" || warn "npm rebuild reported errors; if start fails, run: $0 install --version $(installed_version)"
  node_version > "$GW_STATE_DIR/omniroute.node_version"
  ok "rebuilt for Node $(node_version). Start with: $0 start"
}

cmd_install() {
  check_prereqs; ensure_dirs; write_env_if_missing
  info "installing omniroute@$OMNIROUTE_VERSION into $PREFIX (isolated; no global npm state)"
  npm_install_omniroute "$OMNIROUTE_VERSION"
  [ -f "$ENTRY" ] || die "install finished but $ENTRY is missing"
  installed_version > "$GW_STATE_DIR/omniroute.installed_version"
  ok "OmniRoute $(installed_version) installed. Start it with: $0 start"
  info "Dashboard login password: run '$0 credentials' (printed on demand, not stored in logs)."
}

cmd_credentials() {
  [ -f "$ENVF" ] || die "not installed"
  warn "Printing a secret to your terminal; do not paste it into chats or commits."
  printf 'dashboard: %s\npassword : %s\n' "http://127.0.0.1:$PORT" "$(env_get "$ENVF" INITIAL_PASSWORD)"
  info "INITIAL_PASSWORD only applies until you change it in Dashboard -> Settings -> Security."
}

cmd_start() {
  [ -f "$ENTRY" ] || die "not installed; run: $0 install"
  assert_distinct_ports
  check_node_unchanged
  if gw_running $NAME; then ok "already running (pid $(gw_pid $NAME))"; return 0; fi
  port_in_use "$PORT" && die "port $PORT is already in use by something else; set OMNIROUTE_PORT to another value"
  mkdir -p "$HOME/.cache"   # Termux/Android: Next.js needs it (upstream Termux guide)
  ( load_env_file "$ENVF"; daemon_start $NAME "$LOG" node "$ENTRY" serve --port "$PORT" --no-open )
  info "waiting for $BASE_URL/api/health/ping (first start can take a minute) ..."
  if wait_for_http "$BASE_URL/api/health/ping" "${START_TIMEOUT:-120}"; then ok "running (pid $(gw_pid $NAME)) on $GATEWAY_BIND_HOST:$PORT"
  else err "did not become healthy; last log lines:"; tail -n 20 "$LOG" >&2 || true; return 1; fi
  if is_termux && have termux-wake-lock; then info "tip: run termux-wake-lock so Android doesn't suspend the server"; fi
  return 0
}
cmd_stop()   { gw_stop $NAME $PORT; }
cmd_restart(){ cmd_stop; cmd_start; }

cmd_status() {
  if gw_running $NAME; then ok "running pid $(gw_pid $NAME), port $PORT"; else warn "not running"; fi
  [ -f "$ENTRY" ] && info "version: $(installed_version)"
  [ -f "$ENVF" ] && info "config: $ENVF (mode $(stat -c %a "$ENVF" 2>/dev/null || stat -f %Lp "$ENVF"))"
  return 0
}

cmd_health() {
  local code; code="$(http_code "$BASE_URL/api/health/ping")"
  if [ "$code" = "200" ]; then ok "GET /api/health/ping -> 200 (liveness + DB)"; else err "GET /api/health/ping -> $code"; return 1; fi
  local anon; anon="$(http_code "$BASE_URL/v1/models")"
  case "$anon" in 401|403) ok "/v1/models rejects anonymous requests ($anon)";; 200) warn "/v1/models answered anonymously - REQUIRE_API_KEY not effective!";; *) info "/v1/models anonymous -> $anon";; esac
}

cmd_test_model() {
  # No default model on purpose: on a fresh install "auto" may route to keyless/web-session providers
  # you never chose (observed: Cloudflare Playground needing Playwright). Pick a model YOU connected.
  [ -n "$MODEL" ] || die "pass --model <provider/model> for a provider you connected (list: curl -H 'Authorization: Bearer <key>' $BASE_URL/v1/models). Use --model auto only if you accept automatic routing."
  local key; key="$(read_api_key OMNIROUTE_KEY "$KEY_FILE")"
  model_test "$BASE_URL" "$key" "$MODEL"
}

cmd_backup() {
  ensure_dirs
  gw_running $NAME && warn "gateway is running; stop it first for a fully consistent SQLite copy (continuing)"
  local out; out="$(backup_paths $NAME "${1:-manual}" "$ENVF" "$DATA")" || return 1
  ok "backup: $out"; warn "This archive contains STORAGE_ENCRYPTION_KEY, secrets and encrypted provider credentials. Keep it private; never commit it."
}
cmd_list_backups() { list_backups $NAME; }

cmd_restore() {
  local a="${ARCHIVE:-$(latest_backup $NAME)}"; [ -n "$a" ] || die "no backup to restore"
  confirm "Restore $a over current OmniRoute config+data?" || die "aborted"
  gw_stop $NAME $PORT
  cmd_backup pre-restore >/dev/null || true
  restore_archive "$a" "$ENVF" "$DATA"; ok "restored $a (a pre-restore backup was taken). Start with: $0 start"
}

cmd_update() {
  check_prereqs; [ -f "$ENTRY" ] || die "not installed"
  local was_running=0; gw_running $NAME && was_running=1
  gw_stop $NAME $PORT
  cmd_backup pre-update >/dev/null || true
  installed_version > "$GW_STATE_DIR/omniroute.prev_version"
  info "previous version recorded: $(cat "$GW_STATE_DIR/omniroute.prev_version")"
  npm_install_omniroute "$OMNIROUTE_VERSION"
  installed_version > "$GW_STATE_DIR/omniroute.installed_version"
  ok "updated to $(installed_version); if it misbehaves: $0 rollback [--with-data]"
  if [ "$was_running" = 1 ]; then cmd_start; fi
}

cmd_rollback() {
  local f="$GW_STATE_DIR/omniroute.prev_version"
  [ -f "$f" ] || die "no recorded previous version (run 'update' first, or: npm install --prefix $PREFIX omniroute@<version>)"
  local v; v="$(cat "$f")"; [ -n "$v" ] || die "recorded version is empty"
  confirm "Roll OmniRoute back to $v$([ "$WITH_DATA" = 1 ] && echo ' and restore the pre-update data backup')?" || die "aborted"
  gw_stop $NAME $PORT
  npm_install_omniroute "$v"
  if [ "$WITH_DATA" = 1 ]; then
    local a; a="$(ls -1t "$GW_BACKUP_DIR/$NAME"/*-pre-update.tar.gz 2>/dev/null | head -n1)"
    [ -n "$a" ] || die "no pre-update backup found"
    cmd_backup pre-rollback >/dev/null || true
    restore_archive "$a" "$ENVF" "$DATA"; ok "data restored from $a"
  else
    info "data left as-is. Newer DB migrations may not be reversible; use --with-data if the old version fails to start."
  fi
  installed_version > "$GW_STATE_DIR/omniroute.installed_version"
  ok "rolled back to $(installed_version). Start with: $0 start"
}

cmd_logs() { tail -n "${LINES:-80}" "$LOG" 2>/dev/null || info "no log yet ($LOG)"; }

cmd_uninstall() {
  confirm "Remove OmniRoute code at $PREFIX? (config, data and backups are KEPT)" || die "aborted"
  gw_stop $NAME $PORT; rm -rf "$PREFIX"
  ok "code removed. Kept: $ENVF, $DATA, $GW_BACKUP_DIR/$NAME. Delete those manually only if you are sure."
}

case "$ACTION" in
  install) cmd_install ;; start) cmd_start ;; stop) cmd_stop ;; restart) cmd_restart ;;
  status) cmd_status ;; health) cmd_health ;; test-model) cmd_test_model ;; credentials) cmd_credentials ;;
  backup) cmd_backup ;; list-backups) cmd_list_backups ;; restore) cmd_restore ;;
  update) cmd_update ;; rollback) cmd_rollback ;; rebuild) cmd_rebuild ;; logs) cmd_logs ;; uninstall) cmd_uninstall ;;
  ''|help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
