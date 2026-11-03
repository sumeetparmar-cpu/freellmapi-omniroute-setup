#!/usr/bin/env bash
# Deploy FreeLLMAPI and OmniRoute as isolated systemd services. DRY-RUN BY DEFAULT: nothing changes without --apply.
#
#   deploy.sh [--apply] <step> [options]
#
# Steps (in order):
#   users     create system users llmfree / llmomni (no login, no sudo, no docker group)   GATED: needs --preflight FILE --baseline FILE
#   dirs      create /srv/llm layout (root-owned shell, 0700 per-gateway homes)
#   runtime   download pinned Node (sha256 verified) into /srv/llm/runtime; never touches system packages
#   toolkit   copy this toolkit to /srv/llm/toolkit (root-owned, read-only to the service users)
#   config    choose ports (must be free) and write each gateway's non-secret config
#   install <freellmapi|omniroute>   run the tested installer AS the service user, niced; secrets are generated on the server
#   units     render + verify + install llm-*.service (does not enable or start)
#   enable <gw> [--baseline FILE]    enable --now, wait for health, then run verify.sh; on failure the service is disabled again
#   timers    install optional backup/monitor timers (not enabled)
#   status    read-only summary
#   remove <gw> [--purge --yes-delete-data]   stop+disable+remove unit; --purge also deletes ONLY /srv/llm/<gw> and its user
#   prepare   = users dirs runtime toolkit config
#
# Never touched: Docker, Caddy, n8n, SUPPAR, EARNIX, firewall, sshd, sudoers, cron, any existing user, any path outside $LLM_ROOT
# (except the two unit files in /etc/systemd/system and, for 'timers', the timer units).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vps-common.sh
. "$HERE/lib/vps-common.sh"
REPO_DIR="$(cd "$HERE/.." && pwd)"
TOOLKIT_DIR="$LLM_ROOT/toolkit"

STEP=""; ARGS=(); PREFLIGHT=""; BASELINE=""; PORT_FL=""; PORT_OM=""; PURGE=0; YES_DELETE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;; --root) LLM_ROOT="$2"; TOOLKIT_DIR="$LLM_ROOT/toolkit"; shift ;;
    --preflight) PREFLIGHT="$2"; shift ;; --baseline) BASELINE="$2"; shift ;;
    --freellmapi-port) PORT_FL="$2"; shift ;; --omniroute-port) PORT_OM="$2"; shift ;;
    --purge) PURGE=1 ;; --yes-delete-data) YES_DELETE=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) if [ -z "$STEP" ]; then STEP="$1"; else ARGS+=("$1"); fi ;;
  esac; shift
done
[ -n "$STEP" ] || { sed -n '2,24p' "$0"; exit 2; }
assert_safe_root
DEPLOY_LOG="$LLM_ROOT/deploy.log"
export APPLY
if [ "$APPLY" = 1 ]; then is_root || die "--apply needs root"; else info "DRY-RUN: no changes will be made (add --apply to execute)"; fi

# ---- gates -----------------------------------------------------------------------------------------
check_gates() { # preflight report must be recent, for this host, and not BLOCKED; baseline snapshot must exist
  [ -n "$PREFLIGHT" ] && [ -f "$PREFLIGHT" ] || die "gate: pass --preflight FILE (from: preflight.sh --out FILE)"
  [ -n "$BASELINE" ] && [ -f "$BASELINE" ] || die "gate: pass --baseline FILE (from: inventory.sh snapshot --out FILE)"
  grep -qE '^RESULT: PASS' "$PREFLIGHT" || die "gate: preflight report does not say RESULT: PASS*"
  grep -q "host=$(hostname) " "$PREFLIGHT" || die "gate: preflight report was made on a different host"
  [ -n "$(find "$PREFLIGHT" -mmin -1440 2>/dev/null)" ] || die "gate: preflight report is older than 24h; re-run it"
  grep -q "^snapshot|taken|" "$BASELINE" || die "gate: baseline is not an inventory snapshot"
  grep -q "host=$(hostname)$" "$BASELINE" || die "gate: baseline was taken on a different host"
  ok "gates passed (preflight $(grep '^RESULT' "$PREFLIGHT"), baseline present)"
}
need_root_dir() { [ -d "$LLM_ROOT" ] || [ "$APPLY" != 1 ] || die "run 'dirs' first ($LLM_ROOT missing)"; }
read_conf() { # read_conf KEY -> value from deploy.conf
  [ -f "$LLM_ROOT/deploy.conf" ] && grep -E "^$1=" "$LLM_ROOT/deploy.conf" | head -n1 | cut -d= -f2-; }
gw_port() { case "$1" in freellmapi) read_conf PORT_FREELLMAPI;; omniroute) read_conf PORT_OMNIROUTE;; esac; }
ping_path() { case "$1" in freellmapi) echo /api/ping;; omniroute) echo /api/health/ping;; esac; }
as_user() { # as_user GW cmd... : run as the gateway's service user with a scrubbed environment
  local gw="$1"; shift; local u h pt=(); u="$(gw_user "$gw")"; h="$(gw_home "$gw")"; mapfile -t pt < <(passthrough_env)
  runuser -u "$u" -- env -i -C "$h" HOME="$h/home" PATH="$LLM_ROOT/runtime/node/bin:/usr/bin:/bin" GW_HOME="$h" LANG=C.UTF-8 TERM=dumb "${pt[@]}" "$@"
}

# ---- steps -----------------------------------------------------------------------------------------
step_users() {
  check_gates
  local gw u h
  for gw in freellmapi omniroute; do
    u="$(gw_user "$gw")"; h="$(gw_home "$gw")"
    if getent passwd "$u" >/dev/null; then
      [ "$(getent passwd "$u" | cut -d: -f6)" = "$h" ] || die "user $u exists with a different home; refusing"
      ok "user $u already exists (unchanged)"
    else
      act "creates ONE system account '$u' (uid from the system range, no password, no shell, no home created, own group only)" \
        useradd --system --user-group --home-dir "$h" --no-create-home --shell /usr/sbin/nologin "$u"
    fi
  done
}
step_dirs() {
  act "creates the root-owned parent $LLM_ROOT (nothing else on the filesystem is touched)" install -d -m 0755 -o root -g root "$LLM_ROOT" "$LLM_ROOT/runtime"
  local gw u h
  for gw in freellmapi omniroute; do
    u="$(gw_user "$gw")"; h="$(gw_home "$gw")"
    act "creates $h (0700, owned by $u): the only place that gateway can write, including its HOME and npm cache" install -d -m 0700 -o "$u" -g "$u" "$h" "$h/home" "$h/config"
  done
  [ "$APPLY" = 1 ] && : > "$DEPLOY_LOG" 2>/dev/null && chmod 600 "$DEPLOY_LOG"; return 0
}
_node_fetch() { curl -fsSL --retry 3 -o "$NODE_TMP/node.tgz" "$NODE_URL"; }
_node_verify() {
  local want got; want="$(eval echo "\$NODE_SHA256_$ARCH")"; got="$(sha256sum "$NODE_TMP/node.tgz" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || { err "SHA-256 mismatch for Node tarball (expected $want, got $got)"; return 1; }
}
_node_extract() { tar -xzf "$NODE_TMP/node.tgz" -C "$NODE_TMP" --no-same-owner && [ -x "$NODE_TMP/node-v$NODE_VERSION-linux-$ARCH/bin/node" ]; }
_node_install() {
  local dest="$LLM_ROOT/runtime/node-v$NODE_VERSION"
  # Idempotent AND self-repairing: if an earlier run was killed between the move and the chown/chmod, the directory exists but may be
  # owned/writable wrongly, so ownership and modes are (re)applied every time. The move itself is an atomic rename.
  if [ -e "$dest" ]; then rm -rf -- "$NODE_TMP/node-v$NODE_VERSION-linux-$ARCH"
  else mv "$NODE_TMP/node-v$NODE_VERSION-linux-$ARCH" "$dest" || return 1; fi
  chown -R root:root "$dest" && chmod -R go-w "$dest" && [ -x "$dest/bin/node" ]
}
step_runtime() {
  ARCH="$(node_arch)" || die "unsupported architecture $(uname -m)"
  NODE_URL="$NODE_DIST_URL/v$NODE_VERSION/node-v$NODE_VERSION-linux-$ARCH.tar.gz"
  # A download killed with SIGKILL cannot run its EXIT trap and leaves ~30 MB behind. Remove only OUR stale temp dirs (older than 2 minutes,
  # so a concurrent run's fresh one is untouched).
  [ "$APPLY" = 1 ] && find "$LLM_ROOT/runtime" -maxdepth 1 -type d -name '.dl.*' -mmin +2 -exec rm -rf -- {} + 2>/dev/null
  if [ "$APPLY" = 1 ]; then NODE_TMP="$(mktemp -d "$LLM_ROOT/runtime/.dl.XXXXXX")"; trap 'rm -rf -- "$NODE_TMP"' EXIT; else NODE_TMP="$LLM_ROOT/runtime/.dl.XXXXXX"; fi
  act "downloads $NODE_URL into a temporary directory under $LLM_ROOT/runtime" _node_fetch
  act "aborts unless the SHA-256 equals the value pinned in vps-common.sh (from nodejs.org SHASUMS256.txt)" _node_verify
  act "unpacks the tarball (no ownership from the archive)" _node_extract
  act "moves it to $LLM_ROOT/runtime/node-v$NODE_VERSION, root-owned, not group/world-writable" _node_install
  act "points $LLM_ROOT/runtime/node at that version (the units' PATH); system Node and apt are untouched" ln -sfn "node-v$NODE_VERSION" "$LLM_ROOT/runtime/node"
}
step_toolkit() {
  local stage="$LLM_ROOT/toolkit.new" rev; rev="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  act "stages a copy of termux/ tools/ vps/ config/ into $stage" bash -c "rm -rf -- '$stage' && install -d -m 0755 '$stage' && tar -C '$REPO_DIR' -cf - termux tools vps config | tar -C '$stage' -xf - --no-same-owner"
  act "records the source commit ($rev)" bash -c "printf '%s\n' '$rev' > '$stage/VERSION'"
  act "makes the copy root-owned and read-only for the service users, then swaps it in (previous copy kept as toolkit.prev)" \
    bash -c "chown -R root:root '$stage' && chmod -R go-w '$stage' && rm -rf -- '$LLM_ROOT/toolkit.prev' && { [ ! -e '$TOOLKIT_DIR' ] || mv '$TOOLKIT_DIR' '$LLM_ROOT/toolkit.prev'; } && mv '$stage' '$TOOLKIT_DIR'"
}
step_config() {
  local pf="${PORT_FL:-$DEFAULT_PORT_FREELLMAPI}" po="${PORT_OM:-$DEFAULT_PORT_OMNIROUTE}" p
  valid_port "$pf" && valid_port "$po" || die "invalid port"
  [ "$pf" != "$po" ] || die "ports must differ"
  for p in "$pf" "$po"; do
    if port_listening "$p"; then
      if [ -f "$LLM_ROOT/deploy.conf" ] && { [ "$(read_conf PORT_FREELLMAPI)" = "$p" ] || [ "$(read_conf PORT_OMNIROUTE)" = "$p" ]; }; then warn "port $p is in use, but it is already ours (deploy.conf)"
      else die "port $p is already in use by something else (run preflight.sh for proposals)"; fi
    fi
  done
  write_file "$LLM_ROOT/deploy.conf" 0644 root:root "records the chosen loopback ports for the units and monitor (no secrets)" <<CONF
PORT_FREELLMAPI=$pf
PORT_OMNIROUTE=$po
BIND_HOST=127.0.0.1
CONF
  local gw u
  for gw in freellmapi omniroute; do
    u="$(gw_user "$gw")"
    write_file "$(gw_home "$gw")/config/gateways.env" 0600 "$u:$u" "non-secret settings for $gw: both ports (so the toolkit rejects a clash), loopback bind, pinned tested versions" <<CONF
FREELLMAPI_PORT=$pf
OMNIROUTE_PORT=$po
GATEWAY_BIND_HOST=127.0.0.1
FREELLMAPI_REF=${FREELLMAPI_REF:-v0.16.12}
OMNIROUTE_VERSION=${OMNIROUTE_VERSION:-3.8.52}
CONF
  done
}
step_install() {
  local gw="${ARGS[0]:-}"; valid_gw "$gw" || die "usage: install <freellmapi|omniroute>"
  local u h; u="$(gw_user "$gw")"; h="$(gw_home "$gw")"
  if [ "$APPLY" = 1 ]; then
    getent passwd "$u" >/dev/null || die "user $u missing (run users)"
    [ -x "$LLM_ROOT/runtime/node/bin/node" ] || die "Node runtime missing (run runtime)"
    [ -x "$TOOLKIT_DIR/termux/$gw.sh" ] || die "toolkit copy missing (run toolkit)"
    [ -f "$h/config/gateways.env" ] || die "config missing (run config)"
  fi
  local pre=() pt=(); have nice && pre+=(nice -n 19); have ionice && pre+=(ionice -c3); mapfile -t pt < <(passthrough_env)
  local sd=(); [ -d "$SYSTEMD_RUN_DIR" ] && have systemd-run && sd=(systemd-run --quiet --scope -p "MemoryMax=${INSTALL_MEM_MAX:-2G}" -p CPUWeight=20 --)
  act "as $u: git clone/npm install/build (FreeLLMAPI) or npm install --prefix (OmniRoute) into $h only; generates this gateway's secrets into $h/config/$gw.env (0600); heavy CPU/RAM, so niced and memory-capped" \
    "${sd[@]}" runuser -u "$u" -- env -i -C "$h" HOME="$h/home" PATH="$LLM_ROOT/runtime/node/bin:/usr/bin:/bin" GW_HOME="$h" LANG=C.UTF-8 TERM=dumb "${pt[@]}" "${pre[@]}" "$TOOLKIT_DIR/termux/$gw.sh" install
}
render_unit() { # render_unit GW -> unit text on stdout
  local gw="$1" tpl port; tpl="$HERE/systemd/llm-$gw.service"; port="$(gw_port "$gw")"; [ -n "$port" ] || port="@PORT@"
  [ -f "$tpl" ] || die "template missing: $tpl"
  sed -e "s|@LLM_ROOT@|$LLM_ROOT|g" -e "s|@USER@|$(gw_user "$gw")|g" -e "s|@PORT@|$port|g" -e "s|@GW@|$gw|g" \
      -e "s|@MEM_MAX@|${MEM_MAX:-$([ "$gw" = omniroute ] && echo 2G || echo 1G)}|g" "$tpl"
}
step_units() {
  local gw u td tmp
  for gw in freellmapi omniroute; do
    u="$SYSTEMD_DIR/$(gw_unit "$gw")"
    td="$(mktemp -d)"; tmp="$td/$(gw_unit "$gw")"     # systemd-analyze needs a real unit file name (.service suffix)
    render_unit "$gw" > "$tmp"
    if have systemd-analyze && [ -x "$TOOLKIT_DIR/termux/$gw.sh" ]; then
      if systemd-analyze verify "$tmp" >/dev/null 2>"$td/err"; then ok "unit for $gw passed systemd-analyze verify"
      else err "unit for $gw failed systemd-analyze verify:"; cat "$td/err" >&2; rm -rf "$td"; die "refusing to install an invalid unit"; fi
    else warn "unit for $gw not verified (systemd-analyze or $TOOLKIT_DIR/termux/$gw.sh missing)"; fi
    write_file "$u" 0644 root:root "installs the $gw service unit (not enabled, not started). Only file outside $LLM_ROOT touched" < "$tmp"
    rm -rf "$td"
  done
  if [ -d "$SYSTEMD_RUN_DIR" ]; then act "reloads systemd's unit list (affects no running service)" systemctl daemon-reload
  else warn "systemd not running here: skipping daemon-reload"; fi
}
step_timers() {
  local f
  for f in llm-backup@.service llm-backup@.timer llm-monitor.service llm-monitor.timer; do
    [ -f "$HERE/systemd/$f" ] || die "template missing: $f"
    sed -e "s|@LLM_ROOT@|$LLM_ROOT|g" "$HERE/systemd/$f" | write_file "$SYSTEMD_DIR/$f" 0644 root:root "installs $f (NOT enabled; enable manually after review)"
  done
  if [ -d "$SYSTEMD_RUN_DIR" ]; then act "reloads systemd's unit list" systemctl daemon-reload; fi
}
step_enable() {
  local gw="${ARGS[0]:-}"; valid_gw "$gw" || die "usage: enable <freellmapi|omniroute> [--baseline FILE]"
  [ -n "$BASELINE" ] && [ -f "$BASELINE" ] || die "gate: pass --baseline FILE so the result can be verified against it"
  local port unit; port="$(gw_port "$gw")"; unit="$(gw_unit "$gw")"; [ -n "$port" ] || [ "$APPLY" != 1 ] || die "no port recorded (run config)"
  if port_listening "${port:-0}" && ! { [ -d "$SYSTEMD_RUN_DIR" ] && systemctl is-active --quiet "$unit"; }; then die "port $port is in use by another process"; fi
  if [ -d "$SYSTEMD_RUN_DIR" ] && [ -z "${LLM_NO_SYSTEMD:-}" ]; then
    act "starts $unit now and at boot (runs as $(gw_user "$gw"), loopback :$port, memory/CPU capped)" systemctl enable --now "$unit"
  else
    [ -n "${LLM_NO_SYSTEMD:-}" ] || die "systemd is not running"
    warn "LLM_NO_SYSTEMD set (TEST ONLY): starting with the toolkit's own process control instead of systemd"
    act "starts $gw as $(gw_user "$gw") via the toolkit (no systemd)" as_user "$gw" "$TOOLKIT_DIR/termux/$gw.sh" start
  fi
  if [ "$APPLY" = 1 ]; then
    if wait_for_http "http://127.0.0.1:$port$(ping_path "$gw")" 120; then ok "$gw healthy on 127.0.0.1:$port"
    else err "$gw did not become healthy; disabling it again"; _contain "$gw"; return 1; fi
    if "$HERE/verify.sh" --baseline "$BASELINE" --root "$LLM_ROOT"; then ok "post-start verification passed"
    else err "verification FAILED; disabling $gw to contain"; _contain "$gw"; return 1; fi
  fi
}
_contain() {
  local gw="$1"
  if [ -d "$SYSTEMD_RUN_DIR" ] && [ -z "${LLM_NO_SYSTEMD:-}" ]; then systemctl disable --now "$(gw_unit "$gw")" 2>/dev/null || true
  else as_user "$gw" "$TOOLKIT_DIR/termux/$gw.sh" stop 2>/dev/null || true; fi
}
step_status() {
  local gw
  info "root: $LLM_ROOT  exists=$([ -d "$LLM_ROOT" ] && echo yes || echo no)  node=$("$LLM_ROOT/runtime/node/bin/node" -v 2>/dev/null || echo none)  toolkit=$(cat "$TOOLKIT_DIR/VERSION" 2>/dev/null | cut -c1-12 || echo none)"
  for gw in freellmapi omniroute; do
    local u port; u="$(gw_user "$gw")"; port="$(gw_port "$gw")"
    info "$gw: user=$(getent passwd "$u" >/dev/null && echo present || echo absent) dir=$([ -d "$(gw_home "$gw")" ] && echo yes || echo no) port=${port:-unset} listening=$([ -n "$port" ] && port_listening "$port" && echo yes || echo no) unit=$([ -f "$SYSTEMD_DIR/$(gw_unit "$gw")" ] && echo installed || echo none) active=$( [ -d "$SYSTEMD_RUN_DIR" ] && systemctl is-active "$(gw_unit "$gw")" 2>/dev/null || echo n/a)"
  done
}
step_remove() {
  local gw="${ARGS[0]:-}"; valid_gw "$gw" || die "usage: remove <gw> [--purge --yes-delete-data]"
  local u h unit; u="$(gw_user "$gw")"; h="$(gw_home "$gw")"; unit="$(gw_unit "$gw")"
  if [ -d "$SYSTEMD_RUN_DIR" ] && [ -f "$SYSTEMD_DIR/$unit" ]; then
    act "stops and disables ONLY $unit" systemctl disable --now "$unit"
    act "removes the unit file $SYSTEMD_DIR/$unit" rm -f -- "$SYSTEMD_DIR/$unit"
    act "reloads systemd's unit list" systemctl daemon-reload
  fi
  if [ "$PURGE" = 1 ]; then
    [ "$YES_DELETE" = 1 ] || die "--purge also deletes this gateway's data and secrets: add --yes-delete-data (take a backup first)"
    [ "$h" = "$LLM_ROOT/$gw" ] || die "refusing to delete unexpected path $h"
    act "DELETES $h (that gateway's code, database, secrets, backups) and nothing else" rm -rf -- "$h"
    getent passwd "$u" >/dev/null && act "deletes system user $u" userdel "$u"
  else info "data kept in $h (use --purge --yes-delete-data to delete it)"; fi
}

case "$STEP" in
  users) step_users ;; dirs) step_dirs ;; runtime) step_runtime ;; toolkit) step_toolkit ;; config) step_config ;;
  install) step_install ;; units) step_units ;; timers) step_timers ;; enable) step_enable ;; status) step_status ;; remove) step_remove ;;
  prepare) step_users && step_dirs && step_runtime && step_toolkit && step_config ;;
  *) die "unknown step '$STEP'" ;;
esac
