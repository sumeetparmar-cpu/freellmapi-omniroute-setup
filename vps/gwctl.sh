#!/usr/bin/env bash
# Operate one gateway on the VPS. Always acts as the gateway's own service user; never touches anything else.
#
#   gwctl.sh <freellmapi|omniroute> <action> [args]
#
#   service:   start stop restart status enable disable          (systemctl; LLM_NO_SYSTEMD=1 = test-only toolkit process control)
#   read-only: health logs journal list-backups quota-report credentials   (quota-report: GET-only, no model requests)
#   secrets:   put-key [NAME]      read a secret from stdin (hidden on a TTY) into <gw>/config/NAME (0600); default NAME: client.key (freellmapi) / mgmt.token (omniroute)
#   stateful:  backup restore update rollback rebuild test-model   (stateful ones stop the service, act, restart; update auto-rolls back on a failed health check)
#   export-backup ARCHIVE OUT (--gpg-recipient R | --age-recipient R)   encrypt a backup so it can leave the server
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vps-common.sh
. "$HERE/lib/vps-common.sh"
GW="${1:-}"; ACT="${2:-}"; [ $# -ge 2 ] && shift 2 || { sed -n '2,13p' "$0"; exit 2; }
valid_gw "$GW" || die "unknown gateway '$GW'"
USER_="$(gw_user "$GW")"; HOME_="$(gw_home "$GW")"; UNIT="$(gw_unit "$GW")"
TK="${TOOLKIT_DIR:-$LLM_ROOT/toolkit}"; SCRIPT="$TK/termux/$GW.sh"
PORT="$(grep -E "^PORT_$(echo "$GW" | tr a-z A-Z)=" "$LLM_ROOT/deploy.conf" 2>/dev/null | cut -d= -f2)"
case "$GW" in freellmapi) PING=/api/ping; DEFKEY="$HOME_/config/client.key"; KEYOPT=--key-file;; omniroute) PING=/api/health/ping; DEFKEY="$HOME_/config/mgmt.token"; KEYOPT=--token-file;; esac
use_systemd() { [ -d "$SYSTEMD_RUN_DIR" ] && [ -z "${LLM_NO_SYSTEMD:-}" ]; }
as_svc() { # run a command as the service user (or directly when already that user), scrubbed environment (+ opt-in LLM_PASSTHROUGH_ENV)
  local pt=(); mapfile -t pt < <(passthrough_env)
  if [ "$(id -un)" = "$USER_" ]; then env -i HOME="$HOME_/home" PATH="$LLM_ROOT/runtime/node/bin:/usr/bin:/bin" GW_HOME="$HOME_" LANG=C.UTF-8 TERM=dumb "${pt[@]}" "$@"
  else is_root || die "run as root (sudo) or as $USER_"
       runuser -u "$USER_" -- env -i HOME="$HOME_/home" PATH="$LLM_ROOT/runtime/node/bin:/usr/bin:/bin" GW_HOME="$HOME_" LANG=C.UTF-8 TERM=dumb "${pt[@]}" "$@"; fi
}
is_active() { if use_systemd; then systemctl is-active --quiet "$UNIT"; else as_svc "$SCRIPT" status 2>&1 | grep -q "running"; fi; }
svc() { # svc start|stop|restart
  if use_systemd; then systemctl "$1" "$UNIT"; else as_svc "$SCRIPT" "$1"; fi; }
healthy() { wait_for_http "http://127.0.0.1:${PORT:?no port in $LLM_ROOT/deploy.conf}$PING" "${GWCTL_HEALTH_WAIT:-${1:-120}}"; }
with_stopped() { # with_stopped cmd... : stop if running, run, restart if it was running (even on failure)
  local was=0 rc; is_active && was=1
  [ "$was" = 1 ] && { info "stopping $GW for a consistent operation"; svc stop || true; }
  "$@"; rc=$?
  if [ "$was" = 1 ]; then info "starting $GW again"; svc start || { err "could not restart $GW"; rc=1; }; fi
  return $rc
}

case "$ACT" in
  start|stop|restart) svc "$ACT" ;;
  enable|disable) use_systemd || die "systemd not in use"; if [ "$ACT" = enable ]; then systemctl enable --now "$UNIT"; else systemctl disable --now "$UNIT"; fi ;;
  status) if use_systemd; then systemctl --no-pager status "$UNIT" | head -n 12; fi; as_svc "$SCRIPT" status ;;
  health|logs|list-backups|credentials) as_svc "$SCRIPT" "$ACT" "$@" ;;
  journal) use_systemd || die "systemd not in use"; journalctl --no-pager -u "$UNIT" -n "${LINES:-80}" ;;
  quota-report)
    extra=(); [ -f "$DEFKEY" ] && extra=("$KEYOPT" "$DEFKEY") || warn "no $DEFKEY: run '$0 $GW put-key' first (otherwise only public sections are reported)"
    as_svc "$SCRIPT" quota-report "${extra[@]}" "$@" ;;
  test-model) [ -f "$DEFKEY" ] || die "no key file: run '$0 $GW put-key' first"; as_svc "$SCRIPT" test-model --key-file "$DEFKEY" "$@" ;;
  put-key)
    name="${1:-$(basename "$DEFKEY")}"; case "$name" in */*|.*|'') die "invalid key file name";; esac
    if [ -t 0 ]; then read -r -s -p "Secret for $GW/$name (hidden): " val; printf '\n' >&2; else val="$(cat)"; fi
    [ -n "$val" ] || die "empty secret"
    printf '%s' "$val" | as_svc sh -c 'umask 077; cat > "$GW_HOME/config/$1"; chmod 600 "$GW_HOME/config/$1"' sh "$name" && ok "stored $HOME_/config/$name (mode 600, owner $USER_; never printed)"; unset val ;;
  backup)   with_stopped as_svc "$SCRIPT" backup "$@" ;;
  restore|rebuild) with_stopped as_svc "$SCRIPT" "$ACT" "$@" ;;
  rollback) with_stopped as_svc "$SCRIPT" rollback "$@" ;;
  update)
    was=0; is_active && was=1
    [ "$was" = 1 ] && svc stop
    as_svc "$SCRIPT" update "$@"; rc=$?
    if [ "$rc" -ne 0 ]; then err "update failed (rc=$rc); rolling back code+data from the automatic pre-update backup"; as_svc "$SCRIPT" rollback --with-data --yes; [ "$was" = 1 ] && svc start; exit 1; fi
    if [ "$was" = 1 ]; then
      svc start
      if healthy 120; then ok "update healthy"; else
        err "$GW not healthy after update: AUTOMATIC ROLLBACK (code + data)"; svc stop || true
        as_svc "$SCRIPT" rollback --with-data --yes && svc start && healthy 120 && warn "rolled back; $GW is healthy on the previous version" || err "rollback did not restore health: investigate manually"
        exit 1
      fi
    fi ;;
  export-backup)
    arc="${1:-}"; out="${2:-}"; shift 2 2>/dev/null || true; [ -f "$arc" ] && [ -n "$out" ] || die "usage: export-backup ARCHIVE OUT (--gpg-recipient R | --age-recipient R)"
    case "$arc" in "$HOME_"/backups/*) ;; *) die "archive must live under $HOME_/backups";; esac
    [ ! -e "$out" ] || die "refusing to overwrite $out"
    case "${1:-}" in
      --gpg-recipient) have gpg || die "gpg not installed"; ( umask 077; gpg --batch --yes --trust-model always -r "$2" -o "$out" --encrypt "$arc" ) ;;
      --age-recipient) have age || die "age not installed"; ( umask 077; age -r "$2" -o "$out" "$arc" ) ;;
      *) die "refusing to export unencrypted: give --gpg-recipient or --age-recipient" ;;
    esac && ok "encrypted copy written to $out (mode 600)" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
