#!/usr/bin/env bash
# Install the free-only guard + audit timer next to the two gateways. DRY-RUN BY DEFAULT: nothing changes without --apply.
#
#   free-install.sh [--apply] <step> [gateway] [options]
#
#   units  [--catalog-audited] [--client-keys]   render + systemd-analyze verify + install llm-guard-<gw>.service, llm-free-audit-<gw>.service/.timer
#                                for both gateways (NOT enabled, NOT started). --catalog-audited only after
#                                'free-policy.mjs freellmapi apply' (see docs/FREE-ONLY.md).
#   enable <freellmapi|omniroute>  enable --now the guard and the audit timer, then check the guard answers on its port
#   status                         read-only summary
#   remove <freellmapi|omniroute>  stop + disable ONLY that gateway's guard/audit units and delete those unit files
#
# --client-keys: clients must present a guard key (mint with tools/free-guard.mjs --new-client-key) and the gateway key lives in
#   <gw>/config/free-guard.upstream.key (0600, service user); both files must exist before 'enable'.
# Ports: guard listens on 127.0.0.1:$GUARD_PORT_FREELLMAPI (3101) / $GUARD_PORT_OMNIROUTE (20228); they must be free.
# Never touched: the gateway units, Docker, Caddy, n8n, SUPPAR, EARNIX, firewall, sshd, sudoers, cron, databases.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vps-common.sh
. "$HERE/lib/vps-common.sh"

ARGS=(); EXTRA=""; CLIENTKEYS=0
STEP="${1:-}"; [ "$STEP" = "--apply" ] && { APPLY=1; shift; STEP="${1:-}"; }
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do case "$1" in --catalog-audited) EXTRA=" --catalog-audited";; --client-keys) CLIENTKEYS=1;; --apply) APPLY=1;; *) ARGS+=("$1");; esac; shift; done
[ "$APPLY" = 1 ] && { is_root || die "--apply needs root"; assert_safe_root; }

GUARD_PORT_FREELLMAPI="${GUARD_PORT_FREELLMAPI:-3101}"; GUARD_PORT_OMNIROUTE="${GUARD_PORT_OMNIROUTE:-20228}"
read_conf() { [ -f "$LLM_ROOT/deploy.conf" ] && grep -E "^$1=" "$LLM_ROOT/deploy.conf" | head -n1 | cut -d= -f2-; }
gw_port() { case "$1" in freellmapi) read_conf PORT_FREELLMAPI;; omniroute) read_conf PORT_OMNIROUTE;; esac; }
guard_port() { case "$1" in freellmapi) echo "$GUARD_PORT_FREELLMAPI";; omniroute) echo "$GUARD_PORT_OMNIROUTE";; esac; }
guard_unit() { echo "llm-guard-$1.service"; }
audit_unit() { echo "llm-free-audit-$1.service"; }
valid() { case "${1:-}" in freellmapi|omniroute) return 0;; *) return 1;; esac; }

render() { # render TEMPLATE GW
  local tpl="$HERE/systemd/$1" gw="$2" port; port="$(gw_port "$gw")"; [ -n "$port" ] || port="$(case $gw in freellmapi) echo "$DEFAULT_PORT_FREELLMAPI";; *) echo "$DEFAULT_PORT_OMNIROUTE";; esac)"
  [ -f "$tpl" ] || die "template missing: $tpl"
  sed -e "s|@LLM_ROOT@|$LLM_ROOT|g" -e "s|@USER@|$(gw_user "$gw")|g" -e "s|@PORT@|$port|g" -e "s|@GPORT@|$(guard_port "$gw")|g" \
      -e "s|@GW@|$gw|g" -e "s|@EXTRA@|$({ [ "$gw" = freellmapi ] && printf '%s' "$EXTRA"; [ "$CLIENTKEYS" = 1 ] && printf ' --client-keys-file %s/%s/config/free-guard.clients --upstream-key-file %s/%s/config/free-guard.upstream.key' "$LLM_ROOT" "$gw" "$LLM_ROOT" "$gw"; })|g" "$tpl"
}

step_units() {
  local gw td
  [ "$GUARD_PORT_FREELLMAPI" != "$GUARD_PORT_OMNIROUTE" ] || die "guard ports must differ"
  for gw in freellmapi omniroute; do
    td="$(mktemp -d)"
    render llm-guard.service "$gw" > "$td/$(guard_unit "$gw")"
    render llm-free-audit.service "$gw" > "$td/$(audit_unit "$gw")"
    render llm-free-audit.timer "$gw" > "$td/llm-free-audit-$gw.timer"
    if have systemd-analyze; then
      for f in "$(guard_unit "$gw")" "$(audit_unit "$gw")"; do
        # systemd-analyze verify wants ExecStart binaries to exist; on a host where /srv/llm is not deployed yet this is only a warning.
        if systemd-analyze verify "$td/$f" >/dev/null 2>"$td/err"; then ok "$f passed systemd-analyze verify"
        elif grep -qE "Command .* (is not executable|not found)|No such file" "$td/err"; then warn "$f: toolkit/runtime not deployed here yet; syntax checked only"
        else err "$f failed systemd-analyze verify:"; cat "$td/err" >&2; rm -rf "$td"; die "refusing to install an invalid unit"; fi
      done
    else warn "systemd-analyze not available: units not verified"; fi
    write_file "$SYSTEMD_DIR/$(guard_unit "$gw")" 0644 root:root "installs the free-guard unit for $gw (not enabled, not started)" < "$td/$(guard_unit "$gw")"
    write_file "$SYSTEMD_DIR/$(audit_unit "$gw")" 0644 root:root "installs the audit service for $gw (not enabled)" < "$td/$(audit_unit "$gw")"
    write_file "$SYSTEMD_DIR/llm-free-audit-$gw.timer" 0644 root:root "installs the 10-minute audit timer for $gw (not enabled)" < "$td/llm-free-audit-$gw.timer"
    rm -rf "$td"
  done
  if [ -d "$SYSTEMD_RUN_DIR" ]; then act "reloads systemd's unit list (affects no running service)" systemctl daemon-reload; else warn "systemd not running here: skipping daemon-reload"; fi
}

step_enable() {
  local gw="${ARGS[0]:-}"; valid "$gw" || die "usage: enable <freellmapi|omniroute>"
  local gp; gp="$(guard_port "$gw")"
  [ -f "$SYSTEMD_DIR/$(guard_unit "$gw")" ] || [ "$APPLY" != 1 ] || die "run 'units' first"
  if port_listening "$gp" && ! { [ -d "$SYSTEMD_RUN_DIR" ] && systemctl is-active --quiet "$(guard_unit "$gw")"; }; then die "guard port $gp is in use by another process"; fi
  act "starts the $gw guard on 127.0.0.1:$gp (runs as $(gw_user "$gw"), 192 MB cap)" systemctl enable --now "$(guard_unit "$gw")"
  act "starts the 10-minute audit timer for $gw" systemctl enable --now "llm-free-audit-$gw.timer"
  if [ "$APPLY" = 1 ]; then
    local code=000; for _ in 1 2 3 4 5 6 7 8 9 10; do code="$(HTTP_TIMEOUT=3 http_code "http://127.0.0.1:$gp/__guard/status")"; [ "$code" = 200 ] && break; sleep 1; done
    if [ "$code" = 200 ]; then ok "guard for $gw answers on 127.0.0.1:$gp"
    else err "guard for $gw did not answer (HTTP $code); disabling it again"; systemctl disable --now "$(guard_unit "$gw")" "llm-free-audit-$gw.timer" >/dev/null 2>&1; exit 1; fi
  fi
}

step_status() {
  local gw gp
  for gw in freellmapi omniroute; do
    gp="$(guard_port "$gw")"
    info "$gw: guard-unit=$([ -f "$SYSTEMD_DIR/$(guard_unit "$gw")" ] && echo installed || echo none) active=$( [ -d "$SYSTEMD_RUN_DIR" ] && systemctl is-active "$(guard_unit "$gw")" 2>/dev/null || echo n/a) port=$gp listening=$(port_listening "$gp" && echo yes || echo no) kill-switch=$([ -e "$LLM_ROOT/$gw/state/free-audit.flag" ] && echo ENGAGED || echo off) audit-timer=$( [ -d "$SYSTEMD_RUN_DIR" ] && systemctl is-active "llm-free-audit-$gw.timer" 2>/dev/null || echo n/a)"
  done
}

step_remove() {
  local gw="${ARGS[0]:-}"; valid "$gw" || die "usage: remove <freellmapi|omniroute>"
  [ -d "$SYSTEMD_RUN_DIR" ] && act "stops and disables ONLY the $gw guard and audit timer" systemctl disable --now "$(guard_unit "$gw")" "llm-free-audit-$gw.timer"
  act "removes ONLY the $gw guard/audit unit files" rm -f "$SYSTEMD_DIR/$(guard_unit "$gw")" "$SYSTEMD_DIR/$(audit_unit "$gw")" "$SYSTEMD_DIR/llm-free-audit-$gw.timer"
  [ -d "$SYSTEMD_RUN_DIR" ] && act "reloads systemd's unit list" systemctl daemon-reload
  return 0
}

case "$STEP" in
  units) step_units ;; enable) step_enable ;; status) step_status ;; remove) step_remove ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
