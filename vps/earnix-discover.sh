#!/usr/bin/env bash
# READ-ONLY discovery of the existing EARNIX project on this host (started by remote-survey.sh --earnix, or run directly).
# Finds directories/repos/containers/units/cron/n8n workflows/databases that belong to EARNIX and recovers the requirement documents
# (the 185-method list, the 555-agent requirements). Prints structure, names, counts and git state. NEVER prints environment values, key/token/
# secret/password lines, .env contents, database rows or credentials; never writes (git runs with --no-optional-locks), never restarts anything.
#   earnix-discover.sh [--roots "/opt /srv /root /home /var/www /usr/local"] [--name earnix]
set -uo pipefail
ROOTS="${EARNIX_ROOTS:-/opt /srv /root /home /var/www /usr/local /data}"; NAME="${EARNIX_NAME:-earnix}"
while [ $# -gt 0 ]; do case "$1" in --roots) ROOTS="$2"; shift;; --name) NAME="$2"; shift;; esac; shift; done
sec() { printf '\n=== %s ===\n' "$1"; }
# mask: any line that names a secret-ish key is replaced; URLs lose user:password@
mask() { sed -E 's#(://)[^/@[:space:]]+@#\1<hidden>@#g; /([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss]|[Cc][Rr][Ee][Dd]|[Bb][Ee][Aa][Rr][Ee][Rr])/ s#[=:].*#=<hidden>#' ; }
NOSEC=( ! -name .env ! -name '.env.*' ! -name '*.pem' ! -name '*.key' ! -name 'id_*' ! -name '*secret*' ! -name '*credential*' ! -name '*.sqlite' ! -name '*.db' )
G() { git -c safe.directory='*' --no-optional-locks "$@"; }
PRUNE=( -path '*/node_modules' -o -path '*/.git' -o -path '*/.cache' -o -path '/proc' -o -path '/sys' -o -path /var/lib/docker -o -path '*/.next' -o -path '*/dist' )

sec "HOST"; echo "user=$(id -un) host=$(hostname) time=$(date -u +%FT%TZ) roots=[$ROOTS] name=$NAME"

sec "DIRECTORIES AND FILES NAMED *$NAME* (depth <= 5; paths only)"
DIRS=""
for r in $ROOTS; do [ -d "$r" ] || continue
  while IFS= read -r p; do echo "  $p"; [ -d "$p" ] && DIRS="$DIRS $p"; done < <(find "$r" -maxdepth 5 \( "${PRUNE[@]}" \) -prune -o -iname "*$NAME*" -print 2>/dev/null | head -40)
done
[ -n "$DIRS" ] || echo "  (none under the searched roots; widen with --roots)"

sec "GIT REPOSITORIES (EARNIX-named or inside an EARNIX dir): branch, remote (credentials hidden), last commits, uncommitted state"
REPOS=""
for r in $ROOTS; do [ -d "$r" ] || continue
  while IFS= read -r g; do d=$(dirname "$g"); case "$d" in *"$NAME"*|*"${NAME^^}"*) REPOS="$REPOS $d";; esac; for x in $DIRS; do case "$d/" in "$x"/*) REPOS="$REPOS $d";; esac; done
  done < <(find "$r" -maxdepth 6 \( -path '*/node_modules' -o -path /var/lib/docker \) -prune -o -name .git -print 2>/dev/null | head -60)
done
REPOS=$(printf '%s\n' $REPOS | sort -u)
for d in $REPOS; do
  echo "- $d"
  echo "    branch: $(G -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)   head: $(G -C "$d" rev-parse --short HEAD 2>/dev/null)   branches: $(G -C "$d" branch -a 2>/dev/null | wc -l)   stashes: $(G -C "$d" stash list 2>/dev/null | wc -l)"
  echo "    remotes: $(G -C "$d" remote -v 2>/dev/null | awk '{print $1" "$2}' | sort -u | mask | tr '\n' ';')"
  echo "    last commits:"; G -C "$d" log --oneline -10 2>/dev/null | cut -c1-110 | sed 's/^/      /'
  st=$(G -C "$d" status --porcelain 2>/dev/null); echo "    uncommitted: $(printf '%s' "$st" | grep -c .) entries ($(printf '%s' "$st" | grep -c '^??') untracked)"; printf '%s\n' "$st" | head -25 | cut -c1-110 | sed 's/^/      /'
done
[ -n "$REPOS" ] || echo "  (no git repository found under EARNIX directories)"

sec "PROJECT STRUCTURE (names and sizes; depth 3; secrets/db files excluded)"
for d in $DIRS $REPOS; do [ -d "$d" ] || continue; echo "- $d  ($(du -sm "$d" --exclude=node_modules --exclude=.git 2>/dev/null | cut -f1) MB without node_modules/.git)"
  find "$d" -maxdepth 3 \( "${PRUNE[@]}" \) -prune -o \( -type f "${NOSEC[@]}" \) -printf '    %P  %s\n' 2>/dev/null | sort | head -80
  echo "    files by extension:"; find "$d" \( "${PRUNE[@]}" \) -prune -o -type f -printf '%f\n' 2>/dev/null | sed -n 's/.*\.\([A-Za-z0-9]\{1,6\}\)$/\1/p' | sort | uniq -c | sort -rn | head -8 | sed 's/^/      /'
  [ -f "$d/package.json" ] && { echo "    package.json: name/scripts/deps (names only):"; node -e 'const p=require(process.argv[1]);console.log("      name:",p.name,"version:",p.version);console.log("      scripts:",Object.keys(p.scripts||{}).join(", "));console.log("      deps:",Object.keys(p.dependencies||{}).slice(0,25).join(", "))' "$d/package.json" 2>/dev/null; }
  [ -f "$d/docker-compose.yml" ] && { echo "    docker-compose.yml structure (environment/env_file blocks and secret-like lines hidden):"; awk '/^[[:space:]]*(environment|env_file|secrets):/{skip=match($0,/[^ ]/); next} skip&&match($0,/[^ ]/)>skip{next} {skip=0; print}' "$d/docker-compose.yml" | mask | head -50 | sed 's/^/      /'; }
done

sec "AGENT AND WORKFLOW DEFINITIONS (files whose name suggests agents/workflows/methods; counts and names)"
for d in $DIRS $REPOS; do [ -d "$d" ] || continue
  n=$(find "$d" \( "${PRUNE[@]}" \) -prune -o -type f \( -ipath '*agent*' -o -ipath '*workflow*' -o -ipath '*method*' \) -print 2>/dev/null | wc -l); echo "- $d: $n files with agent/workflow/method in the path"
  find "$d" \( "${PRUNE[@]}" \) -prune -o -type f \( -ipath '*agent*' -o -ipath '*workflow*' -o -ipath '*method*' \) -printf '    %P\n' 2>/dev/null | sort | head -60
done

sec "REQUIREMENT DOCUMENTS (the 185-method list, the 555-agent requirements): path + matching line (secret-like lines hidden)"
for r in $ROOTS; do [ -d "$r" ] || continue
  find "$r" -maxdepth 7 \( "${PRUNE[@]}" \) -prune -o -type f \( -name '*.md' -o -name '*.txt' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.csv' \) -size -4M "${NOSEC[@]}" -print 2>/dev/null | head -4000 \
   | xargs -r grep -IlE '(^|[^0-9])(555|185)([^0-9]|$)' 2>/dev/null | xargs -r grep -IilE 'agent|method|earnix' 2>/dev/null | head -25 | while IFS= read -r f; do
      echo "  $f  ($(wc -c < "$f") bytes)"; grep -IiE '(^|[^0-9])(555|185)([^0-9]|$)' "$f" 2>/dev/null | grep -iE 'agent|method' | head -3 | mask | cut -c1-140 | sed 's/^/      > /'
   done
done
echo "  (listing is by content match on 555/185 near agent/method; open the named files to read the full requirements)"

sec "DOCKER (names/status/images/ports/mount destinations of EARNIX-related containers; no env, no logs)"
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null | grep -iE "$NAME" | sed 's/^/  /'
  echo "  compose projects: $(docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u | grep . | tr '\n' ' ')"
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE "$NAME"); do echo "  $c mounts:"; docker inspect "$c" --format '{{range .Mounts}}    {{.Type}} {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' 2>/dev/null; done
  echo "  volumes matching: $(docker volume ls -q 2>/dev/null | grep -iE "$NAME" | tr '\n' ' ')"
else echo "  docker not installed"; fi

sec "SYSTEMD UNITS (names, state, Description/User/WorkingDirectory/ExecStart only)"
systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1" "$2}' | grep -iE "$NAME" | sed 's/^/  /'
for u in $(systemctl list-units --all --no-legend 2>/dev/null | awk '{print $1}' | grep -iE "$NAME"); do echo "  $u: $(systemctl is-active "$u" 2>&1)"; systemctl cat "$u" 2>/dev/null | grep -E '^(Description|User|WorkingDirectory|ExecStart)=' | mask | sed 's/^/      /'; done
echo "  other units mentioning the project path: $(grep -lis "$NAME" /etc/systemd/system/*.service 2>/dev/null | tr '\n' ' ')"

sec "CRON AND TIMERS mentioning $NAME (secret-like lines hidden)"
{ crontab -l 2>/dev/null; cat /etc/crontab /etc/cron.d/* 2>/dev/null; } | grep -i "$NAME" | mask | head -10 | sed 's/^/  /'
systemctl list-timers --all --no-legend 2>/dev/null | grep -i "$NAME" | head -5 | sed 's/^/  /'

sec "N8N WORKFLOWS (names + active flag only; read-only sqlite open; credentials/nodes never read)"
found=0
for db in $(find /var/lib/docker/volumes $ROOTS -maxdepth 6 -name database.sqlite 2>/dev/null | head -5); do found=1
  echo "  db: $db ($(stat -c %s "$db") bytes)"
  if command -v sqlite3 >/dev/null 2>&1; then
    echo "    workflows total: $(sqlite3 -readonly "file:$db?mode=ro" 'select count(*) from workflow_entity' 2>&1 | head -1)"
    sqlite3 -readonly "file:$db?mode=ro" "select active||' | '||name from workflow_entity order by updatedAt desc limit 60" 2>&1 | head -60 | sed 's/^/    /'
  else echo "    (sqlite3 not installed: names not read; no package is installed by this script)"; fi
done
[ "$found" = 1 ] || echo "  (no n8n sqlite database found under the searched roots; n8n may use Postgres: names then need its API/credentials, not read here)"

sec "DATABASES belonging to EARNIX (files and tables only; never rows)"
for d in $DIRS; do find "$d" -maxdepth 5 \( "${PRUNE[@]}" \) -prune -o -type f \( -name '*.sqlite' -o -name '*.db' -o -name '*.sqlite3' \) -print 2>/dev/null; done | head -10 | while IFS= read -r f; do
  echo "  $f ($(stat -c %s "$f") bytes)"; command -v sqlite3 >/dev/null 2>&1 && sqlite3 -readonly "file:$f?mode=ro" "select name from sqlite_master where type='table' order by 1" 2>&1 | head -40 | tr '\n' ' ' | sed 's/^/      tables: /'; echo
done
docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -iE 'postgres|mysql|maria|mongo|redis' | sed 's/^/  db container (not queried): /'

sec "END (nothing was changed; no secrets printed)"
