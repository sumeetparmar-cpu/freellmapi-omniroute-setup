#!/usr/bin/env bash
# earnix-discover.sh: finds an existing EARNIX project, inventories it, recovers requirement documents, and is READ-ONLY and secret-free.
# Uses a throw-away fake "VPS tree" (EARNIX_ROOTS) with planted secrets: none of them may appear in the output, and nothing may change.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; sed 's/^/       /' "$T/out" | tail -5; fi; }
V="$T/vps"; E="$V/opt/earnix"
mkdir -p "$E/agents" "$E/workflows" "$E/docs" "$E/src" "$V/opt/n8n" "$V/opt/other"
printf 'ADMIN_PASSWORD=PLANTED_SECRET_ONE\nAPI_KEY=PLANTED_SECRET_TWO\n' > "$E/.env"
printf '# EARNIX requirements\nThe platform needs 555 agents.\nThe list has 185 methods.\napi_token: PLANTED_SECRET_THREE 555 agent\n' > "$E/docs/requirements.md"
printf 'export const a = 1;\n' > "$E/agents/scout.ts"; printf 'export const b = 2;\n' > "$E/agents/closer.ts"; printf '{}\n' > "$E/workflows/lead-flow.json"
printf '{"name":"earnix","version":"0.3.0","scripts":{"start":"node src/index.js","test":"node --test"},"dependencies":{"express":"^4"}}\n' > "$E/package.json"
printf 'console.log(1)\n' > "$E/src/index.js"
printf 'services:\n  app:\n    image: earnix:1\n    ports:\n      - "127.0.0.1:4000:4000"\n    environment:\n      - DB_PASSWORD=PLANTED_SECRET_FOUR\n    env_file:\n      - .env\n' > "$E/docker-compose.yml"
printf 'unrelated 555 agents 185 methods in another project\n' > "$V/opt/other/notes.md"
( cd "$E" && git init -q && git config user.email t@t && git config user.name t && git add -A -- . ':!.env' && git commit -q -m "first earnix commit" && git remote add origin https://user:PLANTED_SECRET_FIVE@example.com/x/earnix.git && echo "wip" > src/wip.js )
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$V/opt/n8n/database.sqlite" "create table workflow_entity(name text, active int, updatedAt text, nodes text); insert into workflow_entity values('earnix lead intake',1,'2026-01-02','PLANTED_SECRET_SIX'),('other flow',0,'2026-01-01','x');"
fi
snap() { ( cd "$V" && find . -type f -print0 | sort -z | xargs -0 sha256sum; find . -type d | sort; ) | sha256sum | cut -d' ' -f1; }
BEFORE="$(snap)"; GITBEFORE="$(cd "$E" && git status --porcelain | sha256sum | cut -d' ' -f1)"
EARNIX_ROOTS="$V" bash "$ROOT/vps/earnix-discover.sh" > "$T/report.txt" 2>&1
AFTER="$(snap)"; GITAFTER="$(cd "$E" && git status --porcelain | sha256sum | cut -d' ' -f1)"

t "locates the EARNIX directory"                          grep -q "$E" "$T/report.txt"
t "reports the git repo: branch, last commit, uncommitted/untracked entry" bash -c 'grep -q "first earnix commit" "$0" && grep -q "uncommitted: " "$0" && grep -q "src/wip.js" "$0"' "$T/report.txt"
t "git remote shown with credentials hidden"               bash -c 'grep -q "example.com/x/earnix.git" "$0" && ! grep -q PLANTED_SECRET_FIVE "$0"' "$T/report.txt"
t "lists structure and agent/workflow files"               bash -c 'grep -q "agents/scout.ts" "$0" && grep -q "agents/closer.ts" "$0" && grep -q "workflows/lead-flow.json" "$0"' "$T/report.txt"
t "package.json name, scripts and deps (names only)"       bash -c 'grep -q "name: earnix" "$0" && grep -q "scripts: start, test" "$0" && grep -q "deps: express" "$0"' "$T/report.txt"
t "recovers the requirements file naming 555 agents / 185 methods" bash -c 'grep -q "docs/requirements.md" "$0" && grep -q "555 agents" "$0" && grep -q "185 methods" "$0"' "$T/report.txt"
t "docker-compose structure shown, environment block hidden" bash -c 'grep -q "image: earnix:1" "$0" && grep -q "127.0.0.1:4000:4000" "$0" && ! grep -q "DB_PASSWORD" "$0"' "$T/report.txt"
if command -v sqlite3 >/dev/null 2>&1; then
  t "n8n workflow names read (active flag + name), nodes column never read" bash -c 'grep -q "1 | earnix lead intake" "$0" && grep -q "0 | other flow" "$0"' "$T/report.txt"
fi
t "NO planted secret appears anywhere in the report"       bash -c '! grep -q PLANTED_SECRET "$0"' "$T/report.txt"
t ".env contents are not printed (file not even listed)"   bash -c '! grep -qE "ADMIN_PASSWORD|API_KEY" "$0" && ! grep -qE "^\s+\.env\s" "$0"' "$T/report.txt"
t "READ-ONLY: every file and directory identical before/after, git status unchanged" bash -c '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$BEFORE" "$AFTER" "$GITBEFORE" "$GITAFTER"
t "the unrelated project is not part of EARNIX's own structure listing" bash -c 'awk "/^=== PROJECT STRUCTURE/{f=1;next} /^=== /{f=0} f" "$0" | grep -q "other/notes" && exit 1; exit 0' "$T/report.txt"
t "ends with the no-changes statement"                     grep -q "nothing was changed; no secrets printed" "$T/report.txt"

echo "# through remote-survey.sh --earnix (fake ssh, report also saved)"
cat > "$T/fakessh" <<'S'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o|-p|-i) shift 2;; -*) shift;; *) break;; esac; done; shift; exec bash -c "$1"
S
chmod +x "$T/fakessh"
env HOME="$T" SSH_BIN="$T/fakessh" EARNIX_ROOTS="$V" bash "$ROOT/vps/remote-survey.sh" me@host --earnix --out "$T/phone.txt" > "$T/sv.out" 2>&1
t "wrapper runs the discovery and prints/saves it on the phone side" bash -c 'grep -q "first earnix commit" "$0" && ! grep -q PLANTED_SECRET "$0"' "$T/phone.txt"
t "wrapper keeps a copy on the VPS side (falls back to HOME/llm-deploy when not root)" bash -c 'ls "$0"/llm-deploy/earnix-discovery-*.txt >/dev/null 2>&1 || ls /root/llm-deploy/earnix-discovery-*.txt >/dev/null 2>&1' "$T"
rm -f /root/llm-deploy/earnix-discovery-*.txt 2>/dev/null
echo "# earnix-db-inspect.sh (snapshot comparison; sqlite3 is available in this test only when installed)"
if command -v sqlite3 >/dev/null 2>&1; then
  mkdir -p "$V/opt/vyora-workspace/backups"; B="$V/opt/vyora-workspace/backups"
  sqlite3 "$B/earnix-old.sqlite" "create table agents(id integer,name text,status text,updated_at text); create table api_keys(k text); insert into agents values(1,'PLANTED_NAME_A','draft','2026-01-01'),(2,'PLANTED_NAME_B','draft','2026-01-02'); insert into api_keys values('PLANTED_SECRET_SEVEN');"
  sqlite3 "$B/earnix-new.sqlite" "create table agents(id integer,name text,status text,updated_at text); create table api_keys(k text); insert into agents values(1,'PLANTED_NAME_A','active','2026-03-01'),(2,'PLANTED_NAME_B','active','2026-03-02'),(3,'PLANTED_NAME_C','draft','2026-03-03'); insert into api_keys values('PLANTED_SECRET_SEVEN');"
  DB0="$(cd "$V" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  bash "$ROOT/vps/earnix-db-inspect.sh" "$B" > "$T/db.txt" 2>&1
  DB1="$(cd "$V" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  t "lists both snapshots with size, time and checksum"          bash -c 'grep -c "sqlite " "$0" | grep -q "^2$" && grep -q "sha256:" "$0"' "$T/db.txt"
  t "row counts and newest timestamp per snapshot"               bash -c 'grep -q "agents  *rows=3 .*updated_at.max=2026-03-03" "$0" && grep -q "agents  *rows=2 .*updated_at.max=2026-01-02" "$0"' "$T/db.txt"
  t "agent table: columns and counts per status, no names"      bash -c 'grep -q "columns = id, name, status, updated_at" "$0" && grep -q "by status: active=2 draft=1" "$0"' "$T/db.txt"
  t "ranking puts the newest snapshot first"                     bash -c 'awk "/^=== RANKING/{f=1;next} f" "$0" | grep -m1 -q "1\. newest=2026-03-03.*earnix-new.sqlite"' "$T/db.txt"
  t "no row content or secret printed"                           bash -c '! grep -qE "PLANTED_NAME|PLANTED_SECRET" "$0"' "$T/db.txt"
  t "READ-ONLY: snapshots and the whole tree byte-identical after" bash -c '[ "$1" = "$2" ]' _ "$DB0" "$DB1"
  env HOME="$T" SSH_BIN="$T/fakessh" LLM_VPS_TARGET_FILE="$T/mem2" bash "$ROOT/vps/remote-survey.sh" me@host --earnix-db "$B" --out "$T/dbphone.txt" > /dev/null 2>&1
  t "wrapper --earnix-db runs it and returns the report"        bash -c 'grep -q "RANKING" "$0" && ! grep -q PLANTED "$0"' "$T/dbphone.txt"
fi
echo "# placeholder guard and remembered login"
t "a placeholder address is refused before any connection"  bash -c '! env HOME="$1" SSH_BIN="$1/fakessh" bash "$0/vps/remote-survey.sh" root@YOUR_REAL_ADDRESS --earnix 2>&1 | grep -q "connecting"; env HOME="$1" SSH_BIN="$1/fakessh" bash "$0/vps/remote-survey.sh" root@YOUR_REAL_ADDRESS --earnix 2>&1 | grep -q "placeholder"' "$ROOT" "$T"
t "'last' with nothing remembered says so"                   bash -c 'env HOME="$1" LLM_VPS_TARGET_FILE="$1/none" SSH_BIN="$1/fakessh" bash "$0/vps/remote-survey.sh" last --earnix 2>&1 | grep -q "no remembered login"' "$ROOT" "$T"
env HOME="$T" LLM_VPS_TARGET_FILE="$T/mem" SSH_BIN="$T/fakessh" EARNIX_ROOTS="$V" bash "$ROOT/vps/remote-survey.sh" real@203.0.113.9 --earnix --out "$T/p2.txt" > /dev/null 2>&1
t "a successful run remembers the login (0600)"              bash -c '[ "$(cat "$0/mem")" = "real@203.0.113.9" ] && [ "$(stat -c %a "$0/mem")" = 600 ]' "$T"
env HOME="$T" LLM_VPS_TARGET_FILE="$T/mem" SSH_BIN="$T/fakessh" EARNIX_ROOTS="$V" bash "$ROOT/vps/remote-survey.sh" last --earnix --out "$T/p3.txt" > "$T/p3.log" 2>&1
t "'last' reuses it"                                         bash -c 'grep -q "using the remembered login: real@203.0.113.9" "$0" && grep -q "first earnix commit" "$1"' "$T/p3.log" "$T/p3.txt"
echo "earnix-discover: passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1
