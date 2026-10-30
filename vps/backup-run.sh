#!/usr/bin/env bash
# Scheduled backup for one gateway: stop (seconds), back up config+data, restart, prune old SCHEDULED backups only.
#   backup-run.sh <freellmapi|omniroute> [--keep N] [--keep-days D]
# Pruning removes only files named *-scheduled.tar.gz inside <gw>/backups/<gw>/, always keeping the newest N (default 8) and anything
# younger than D days (default 14). Manual, pre-update, pre-restore and pre-rollback backups are never deleted by this script.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vps-common.sh
. "$HERE/lib/vps-common.sh"
GW="${1:-}"; valid_gw "$GW" || die "usage: backup-run.sh <freellmapi|omniroute> [--keep N] [--keep-days D]"; shift
KEEP=8; DAYS=14
while [ $# -gt 0 ]; do case "$1" in --keep) KEEP="$2"; shift;; --keep-days) DAYS="$2"; shift;; *) die "unknown option $1";; esac; shift; done
case "$KEEP$DAYS" in *[!0-9]*|'') die "--keep and --keep-days must be numbers";; esac
[ "$KEEP" -ge 1 ] || die "--keep must be >= 1"
GWCTL="${GWCTL:-$HERE/gwctl.sh}"
"$GWCTL" "$GW" backup --label scheduled || die "backup failed; nothing pruned"
D="$(gw_home "$GW")/backups/$GW"
[ -d "$D" ] || { warn "no backup directory $D"; exit 0; }
mapfile -t files < <(ls -1t "$D"/*-scheduled.tar.gz 2>/dev/null)
n=0
for f in "${files[@]}"; do
  n=$((n+1)); [ "$n" -le "$KEEP" ] && continue
  [ -n "$(find "$f" -mtime -"$DAYS" 2>/dev/null)" ] && continue
  case "$f" in "$D"/*-scheduled.tar.gz) rm -f -- "$f" && info "pruned $(basename "$f")";; esac
done
ok "backup complete; $(ls -1 "$D"/*-scheduled.tar.gz 2>/dev/null | wc -l) scheduled backup(s) retained"
