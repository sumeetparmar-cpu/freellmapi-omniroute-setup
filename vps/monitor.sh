#!/usr/bin/env bash
# Resource + health monitor. READ-ONLY. Exit 0 = OK, 1 = WARN, 2 = CRIT (Nagios-style).
#   monitor.sh check [--json] [--log FILE]
# Thresholds (env): MON_DISK_WARN_GB=8 MON_DISK_CRIT_GB=3 MON_AVAIL_WARN_MB=800 MON_AVAIL_CRIT_MB=400 MON_MEM_WARN_PCT=85 MON_LOAD_FACTOR=1.5 MON_RESTART_WARN=3
# Needs no secrets: it only calls the public liveness endpoints. Backup age needs root (the backup dirs are 0700 service-user owned).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vps-common.sh
. "$HERE/lib/vps-common.sh"
JSON=0; LOGF=""
[ "${1:-}" = check ] && shift || { sed -n '2,6p' "$0"; exit 2; }
while [ $# -gt 0 ]; do case "$1" in --json) JSON=1;; --log) LOGF="$2"; shift;; *) die "unknown option $1";; esac; shift; done
DW="${MON_DISK_WARN_GB:-8}"; DC="${MON_DISK_CRIT_GB:-3}"; AW="${MON_AVAIL_WARN_MB:-800}"; AC="${MON_AVAIL_CRIT_MB:-400}"
WORST=0; RES=()
rec() { # rec LEVEL name detail   LEVEL: 0 OK 1 WARN 2 CRIT
  local l="$1" n="$2"; shift 2; [ "$l" -gt "$WORST" ] && WORST="$l"; RES+=("$l|$n|$*"); }
lvl() { case "$1" in 0) echo OK;; 1) echo WARN;; *) echo CRIT;; esac; }

# system
FREE_GB=$(( $(df -Pk "${LLM_ROOT_PROBE:-$([ -d "$LLM_ROOT" ] && echo "$LLM_ROOT" || echo /)}" | awk 'NR==2{print $4}') / 1024 / 1024 ))
if [ "$FREE_GB" -lt "$DC" ]; then rec 2 disk "free ${FREE_GB} GB < ${DC}"; elif [ "$FREE_GB" -lt "$DW" ]; then rec 1 disk "free ${FREE_GB} GB < ${DW}"; else rec 0 disk "free ${FREE_GB} GB"; fi
MA=$(( $(mem_kb MemAvailable) / 1024 )); MT=$(( $(mem_kb MemTotal) / 1024 ))
if [ "$MA" -lt "$AC" ]; then rec 2 memory "available ${MA}/${MT} MB < ${AC}"; elif [ "$MA" -lt "$AW" ]; then rec 1 memory "available ${MA}/${MT} MB < ${AW}"; else rec 0 memory "available ${MA}/${MT} MB"; fi
SW=$(( ($(mem_kb SwapTotal) - $(mem_kb SwapFree)) / 1024 )); [ "$SW" -gt 256 ] && rec 1 swap "${SW} MB in use" || rec 0 swap "${SW} MB in use"
NC="$(nproc 2>/dev/null || echo 1)"; L1="$(cut -d' ' -f1 /proc/loadavg)"
if awk -v l="$L1" -v n="$NC" -v f="${MON_LOAD_FACTOR:-1.5}" 'BEGIN{exit !(l > n*f)}'; then rec 1 load "load1 $L1 on $NC CPU(s)"; else rec 0 load "load1 $L1 on $NC CPU(s)"; fi

# gateways
for gw in freellmapi omniroute; do
  [ -f "$LLM_ROOT/deploy.conf" ] || { rec 1 "$gw" "not deployed ($LLM_ROOT/deploy.conf missing)"; continue; }
  key="PORT_$(echo "$gw" | tr a-z A-Z)"; port="${!key:-$(grep -E "^$key=" "$LLM_ROOT/deploy.conf" | cut -d= -f2)}"
  case "$gw" in freellmapi) ping=/api/ping;; omniroute) ping=/api/health/ping;; esac
  unit="$(gw_unit "$gw")"
  if [ -d "$SYSTEMD_RUN_DIR" ] && [ -f "$SYSTEMD_DIR/$unit" ]; then
    st="$(systemctl is-active "$unit" 2>/dev/null)"; [ "$st" = active ] && rec 0 "$gw.unit" "active" || rec 2 "$gw.unit" "$st"
    mem="$(systemctl show -p MemoryCurrent --value "$unit" 2>/dev/null)"; max="$(systemctl show -p MemoryMax --value "$unit" 2>/dev/null)"
    if [ -n "$mem" ] && [ "$mem" != "[not set]" ] && [ "$mem" -gt 0 ] 2>/dev/null; then
      mb=$((mem/1024/1024))
      if [ -n "$max" ] && [ "$max" != infinity ] && [ "$max" -gt 0 ] 2>/dev/null && [ $((mem*100/max)) -ge "${MON_MEM_WARN_PCT:-85}" ]; then rec 1 "$gw.memory" "${mb} MB = $((mem*100/max))% of MemoryMax"; else rec 0 "$gw.memory" "${mb} MB"; fi
    fi
    nr="$(systemctl show -p NRestarts --value "$unit" 2>/dev/null)"; [ "${nr:-0}" -ge "${MON_RESTART_WARN:-3}" ] 2>/dev/null && rec 1 "$gw.restarts" "$nr restarts since start" || rec 0 "$gw.restarts" "${nr:-0}"
  fi
  t0=$(date +%s%N); code="$(HTTP_TIMEOUT=5 http_code "http://127.0.0.1:$port$ping")"; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  if [ "$code" = 200 ]; then [ "$ms" -gt 2000 ] && rec 1 "$gw.health" "HTTP 200 but slow: ${ms} ms" || rec 0 "$gw.health" "HTTP 200 in ${ms} ms"; else rec 2 "$gw.health" "HTTP $code on 127.0.0.1:$port$ping"; fi
  if is_root && [ -d "$(gw_home "$gw")/backups/$gw" ]; then
    newest="$(ls -1t "$(gw_home "$gw")/backups/$gw"/*.tar.gz 2>/dev/null | head -n1)"
    if [ -z "$newest" ]; then rec 1 "$gw.backup" "no backup yet"; else age=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 86400 )); [ "$age" -gt "${MON_BACKUP_WARN_DAYS:-10}" ] && rec 1 "$gw.backup" "newest is ${age} days old" || rec 0 "$gw.backup" "newest is ${age} day(s) old"; fi
  fi
  lg="$(gw_home "$gw")/logs"; if [ -d "$lg" ] && [ -r "$lg" ]; then sz=$(du -sm "$lg" 2>/dev/null | cut -f1); [ "${sz:-0}" -gt "${MON_LOG_WARN_MB:-500}" ] && rec 1 "$gw.logs" "${sz} MB of logs" || rec 0 "$gw.logs" "${sz:-0} MB"; fi
done

# output
if [ "$JSON" = 1 ]; then
  printf '{"time":"%s","host":"%s","status":"%s","checks":[' "$(date -u +%FT%TZ)" "$(hostname)" "$(lvl $WORST)"
  first=1; for r in "${RES[@]}"; do IFS='|' read -r l n d <<< "$r"; [ $first = 1 ] || printf ','; first=0; printf '{"level":"%s","check":"%s","detail":"%s"}' "$(lvl "$l")" "$n" "${d//\"/\\\"}"; done; printf ']}\n'
else
  for r in "${RES[@]}"; do IFS='|' read -r l n d <<< "$r"; printf '%-5s %-22s %s\n' "$(lvl "$l")" "$n" "$d"; done
  printf 'OVERALL: %s\n' "$(lvl $WORST)"
fi
[ -n "$LOGF" ] && { ( umask 077; printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$(lvl $WORST)" "$(printf '%s;' "${RES[@]}" | tr '|' ' ' | cut -c1-600)" >> "$LOGF" ); }
exit "$WORST"
