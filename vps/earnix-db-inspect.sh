#!/usr/bin/env bash
# READ-ONLY comparison of EARNIX database snapshots and the active database (sqlite files; dumps are listed and their tables counted).
# Opens every sqlite file with mode=ro&immutable=1 (no WAL/journal writes), reads ONLY: table names, row COUNTS, newest/oldest value of
# timestamp-like columns, column NAMES of agent/method tables, and counts per status/type-like column. Never prints row contents, never restores
# or modifies anything. Output ends with a ranking of which snapshot looks like the authoritative current state, with the evidence.
#   earnix-db-inspect.sh [DIR ...]      default DIR: /opt/vyora-workspace
set -uo pipefail
DIRS=("$@"); [ ${#DIRS[@]} -gt 0 ] || DIRS=(/opt/vyora-workspace)
command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is not installed on this host: nothing can be inspected (this script installs nothing)."; exit 0; }
sec() { printf '\n=== %s ===\n' "$1"; }
Q() { sqlite3 -readonly "file:$1?mode=ro&immutable=1" "${@:2}" 2>/dev/null; }
sec "FILES (sqlite/db files and dumps under: ${DIRS[*]})"
mapfile -t FILES < <(for d in "${DIRS[@]}"; do [ -d "$d" ] && find "$d" -maxdepth 6 \( -path '*/node_modules' -o -path '*/.git' \) -prune -o -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' -o -name '*.sql' -o -name '*.sql.gz' -o -name '*.dump' -o -name '*.bak' \) -print 2>/dev/null; done | sort -u | head -80)
[ ${#FILES[@]} -gt 0 ] || { echo "  none found"; exit 0; }
SQL=()
for f in "${FILES[@]}"; do
  kind=other; head -c 15 "$f" 2>/dev/null | grep -q 'SQLite format 3' && kind=sqlite
  printf '  %-9s %10s bytes  %s  sha256:%s  %s\n' "$kind" "$(stat -c %s "$f")" "$(date -u -d @"$(stat -c %Y "$f")" +%FT%TZ)" "$(sha256sum "$f" | cut -c1-12)" "$f"
  [ "$kind" = sqlite ] && SQL+=("$f")
done
sec "SQLITE: tables, row counts, timestamp ranges"
RANK=""
for f in "${SQL[@]}"; do
  echo "- $f"
  integ=$(Q "$f" 'pragma quick_check' | head -1); echo "    quick_check: ${integ:-n/a}"
  tot=0; ntab=0; newest=""
  while IFS= read -r t; do [ -n "$t" ] || continue
    c=$(Q "$f" "select count(*) from \"$t\""); c=${c:-0}; tot=$((tot + c)); ntab=$((ntab + 1))
    ts=""
    for col in $(Q "$f" "select name from pragma_table_info('$t') where lower(name) in ('updated_at','updatedat','created_at','createdat','timestamp','ts','last_run','finished_at','completed_at') limit 3"); do
      mx=$(Q "$f" "select max(\"$col\") from \"$t\""); [ -n "$mx" ] && { ts="$ts $col.max=$mx"; case "$mx" in 20*|1[67]*) [ "$mx" \> "$newest" ] && newest="$mx";; esac; }
    done
    printf '    %-34s rows=%-8s%s\n' "$t" "$c" "$ts"
  done < <(Q "$f" "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by 1" | head -120)
  echo "    TOTAL: $ntab tables, $tot rows, newest timestamp seen: ${newest:-none}"
  RANK="$RANK$newest|$tot|$f"$'\n'
done
sec "AGENT / METHOD / TASK TABLES (column names; counts per status/type-like column; no row contents)"
for f in "${SQL[@]}"; do
  tabs=$(Q "$f" "select name from sqlite_master where type='table' and (lower(name) like '%agent%' or lower(name) like '%method%' or lower(name) like '%task%' or lower(name) like '%workflow%' or lower(name) like '%run%' or lower(name) like '%revenue%' or lower(name) like '%lead%') order by 1")
  [ -n "$tabs" ] || continue; echo "- $f"
  for t in $tabs; do
    echo "    $t: columns = $(Q "$f" "select group_concat(name, ', ') from pragma_table_info('$t')")"
    for col in $(Q "$f" "select name from pragma_table_info('$t') where lower(name) in ('status','state','type','kind','category','role','enabled','active','tier') limit 3"); do
      echo "        by $col: $(Q "$f" "select v||'='||c from (select coalesce(\"$col\",'(null)') v, count(*) c from \"$t\" group by 1 order by 2 desc limit 8)" | tr '\n' ' ')"
    done
  done
done
sec "RANKING (newest data timestamp first, then total rows): the top entry is the likely authoritative current state"
printf '%s' "$RANK" | sort -r | awk -F'|' 'NF==3{printf "  %d. newest=%s rows=%s  %s\n", NR, ($1==""?"none":$1), $2, $3}'
echo "  (evidence only: confirm against which file the running service actually opens before restoring or using any snapshot; nothing was restored or modified)"
sec "END (read-only; no row contents printed)"
