#!/usr/bin/env bash
# Offline unit tests for the Termux scripts. No installs, no network, no real secrets.
#   bash tests/termux/run-tests.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; MOCK_PIDS=()
cleanup() { for p in "${MOCK_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

export GW_HOME="$TMP/gw" HOME="$TMP/home"; mkdir -p "$HOME"
unset FREELLMAPI_PORT OMNIROUTE_PORT GATEWAY_BIND_HOST FREELLMAPI_REF OMNIROUTE_VERSION
# shellcheck source=../../termux/lib/common.sh
. "$ROOT/termux/lib/common.sh"
set +e   # common.sh enables nothing, but be explicit: tests assert on exit codes themselves

PASS=0; FAIL=0
t() { # t "name" command...   (passes when command exits 0)
  local name="$1"; shift
  if ( "$@" ) >"$TMP/out" 2>&1; then PASS=$((PASS + 1)); echo "ok   - $name"; else FAIL=$((FAIL + 1)); echo "FAIL - $name"; sed 's/^/       /' "$TMP/out" | head -15; fi
}
tn() { local name="$1"; shift; if ( "$@" ) >"$TMP/out" 2>&1; then FAIL=$((FAIL + 1)); echo "FAIL - $name (expected failure)"; else PASS=$((PASS + 1)); echo "ok   - $name"; fi; }

echo "# version helpers"
t "ver_ge equal"            ver_ge 22.22.2 22.22.2
t "ver_ge 24 > 22.22.2"     ver_ge 24.0.0 22.22.2
tn "ver_ge 22.22.0 < 22.22.2" ver_ge 22.22.0 22.22.2
t "omniroute accepts 22.22.2" node_ok_omniroute 22.22.2
t "omniroute accepts 24.11.0" node_ok_omniroute 24.11.0
tn "omniroute rejects 22.22.0" node_ok_omniroute 22.22.0
tn "omniroute rejects 23.5.0 (gap)" node_ok_omniroute 23.5.0
tn "omniroute rejects 20.18.0" node_ok_omniroute 20.18.0
tn "omniroute rejects 27.0.0" node_ok_omniroute 27.0.0
t "freellmapi accepts 20.18.0 (non-Termux)" env -u TERMUX_VERSION bash -c ". '$ROOT/termux/lib/common.sh'; is_termux && exit 0; node_ok_freellmapi 20.18.0"
tn "freellmapi rejects 25.0.0" node_ok_freellmapi 25.0.0
tn "freellmapi rejects 18.0.0" node_ok_freellmapi 18.0.0
t "freellmapi on Termux needs 22.13 (rejects 20.x)" bash -c "export TERMUX_VERSION=0.118; . '$ROOT/termux/lib/common.sh'; ! node_ok_freellmapi 20.19.0 && node_ok_freellmapi 22.13.0"

echo "# ports"
t "defaults distinct" assert_distinct_ports
tn "equal ports refused" bash -c ". '$ROOT/termux/lib/common.sh'; FREELLMAPI_PORT=4000 OMNIROUTE_PORT=4000 assert_distinct_ports"
tn "non-numeric port refused" bash -c ". '$ROOT/termux/lib/common.sh'; FREELLMAPI_PORT=abc assert_distinct_ports"
tn "privileged port refused" bash -c ". '$ROOT/termux/lib/common.sh'; FREELLMAPI_PORT=80 assert_distinct_ports"
node -e 'require("net").createServer().listen(0,"127.0.0.1",function(){console.log(this.address().port)})' > "$TMP/port" &
MOCK_PIDS+=("$!"); sleep 0.6
t "port_in_use detects listener" port_in_use "$(cat "$TMP/port")"
tn "port_in_use false for free port" port_in_use 1

echo "# env files & secrets"
ensure_dirs
F="$GW_CONFIG_DIR/t.env"
env_set "$F" A 1; env_set "$F" B 'x=y'; env_set "$F" A 2
t "env_get latest value"      test "$(env_get "$F" A)" = 2
t "env_get value with '='"    test "$(env_get "$F" B)" = 'x=y'
t "env file mode 600"         test "$(stat -c %a "$F")" = 600
t "no duplicate keys"         test "$(grep -c '^A=' "$F")" = 1
printf 'SAFE=ok\nEVIL=$(touch %s/pwned)\nBAD KEY=1\n' "$TMP" > "$GW_CONFIG_DIR/evil.env"
( load_env_file "$GW_CONFIG_DIR/evil.env"; [ "$SAFE" = ok ] && [ "$EVIL" = "\$(touch $TMP/pwned)" ] ) >/dev/null 2>&1
t "load_env_file does not execute values" test ! -e "$TMP/pwned"
t "gen_hex length"            test "$(gen_hex 32 | tr -d "\n" | wc -c)" = 64
tn "gen_hex values differ"    test "$(gen_hex 16)" = "$(gen_hex 16)"
t "gw home is 700"            test "$(stat -c %a "$GW_HOME")" = 700

echo "# backup / restore"
mkdir -p "$TMP/data"; echo v1 > "$TMP/data/db"; echo K=1 > "$TMP/cfg.env"
A="$(backup_paths unit test "$TMP/cfg.env" "$TMP/data")"
t "backup archive created"    test -s "$A"
t "backup mode 600"           test "$(stat -c %a "$A")" = 600
echo v2 > "$TMP/data/db"; restore_archive "$A" "$TMP/cfg.env" "$TMP/data"
t "restore returns old data"  test "$(cat "$TMP/data/db")" = v1
tn "backup with no paths fails" backup_paths unit empty "$TMP/does-not-exist"
mkdir -p "$TMP/evil/x"; echo hi > "$TMP/evil/x/f"
( cd "$TMP/evil/x" && tar -czf "$TMP/trav.tar.gz" --transform 's#^f$#../escape#' f )
tn "restore refuses '..' paths" restore_archive "$TMP/trav.tar.gz" "$TMP/data"
tn "restore refuses missing file" restore_archive "$TMP/nope.tar.gz" "$TMP/data"
mkdir -p "$TMP/victim"; echo orig > "$TMP/victim/rc"
A2="$(backup_paths unit other "$TMP/victim/rc")"
echo changed > "$TMP/victim/rc"
tn "restore refuses entries outside allowed paths" restore_archive "$A2" "$TMP/cfg.env" "$TMP/data"
t  "...and left the file untouched" test "$(cat "$TMP/victim/rc")" = changed
tn "restore with no allowed paths refused" restore_archive "$A"
t  "restore allows listed file and dir" restore_archive "$A" "$TMP/cfg.env" "$TMP/data"
echo stale > "$TMP/data/db-wal"
restore_archive "$A" "$TMP/cfg.env" "$TMP/data"
t  "restore removes stale files (e.g. SQLite -wal) from data dir" test ! -e "$TMP/data/db-wal"
t  "...and still restores the database" test "$(cat "$TMP/data/db")" = v1
t "latest_backup finds newest" test -n "$(latest_backup unit)"

echo "# process helpers"
( sleep 60 & echo $! > "$(pid_file unitproc)" )
t "gw_running true"           gw_running unitproc
gw_stop unitproc >/dev/null 2>&1
tn "gw_running false after stop" gw_running unitproc
t "stop on stopped is a no-op" gw_stop unitproc

echo "# model_test against mock (key delivered via curl config, not argv)"
start_mock() { node "$ROOT/tests/mock-openai-server.mjs" "$1" "$2" >/dev/null 2>&1 & MOCK_PIDS+=("$!"); for _ in $(seq 20); do [ "$(http_code "http://127.0.0.1:$1/v1/models")" != 000 ] && return; sleep 0.2; done; }
start_mock 18101 ok;    start_mock 18102 quota; start_mock 18103 empty; start_mock 18104 auth
t  "model_test OK path"              model_test http://127.0.0.1:18101 anykey mock-model
tn "model_test quota (429) fails"    model_test http://127.0.0.1:18102 anykey mock-model
tn "model_test empty choices fails"  model_test http://127.0.0.1:18103 anykey mock-model
tn "model_test wrong key fails"      model_test http://127.0.0.1:18104 wrong mock-model
t  "model_test right key passes"     model_test http://127.0.0.1:18104 mock-key mock-model
tn "model_test unreachable fails"    model_test http://127.0.0.1:1 k m
t  "read_api_key from env"           bash -c ". '$ROOT/termux/lib/common.sh'; K=abc; [ \"\$(read_api_key K)\" = abc ]"
printf 'filekey\n' > "$TMP/k"
t  "read_api_key from file"          bash -c ". '$ROOT/termux/lib/common.sh'; [ \"\$(read_api_key NOPE '$TMP/k')\" = filekey ]"
tn "read_api_key non-interactive w/o key fails" bash -c ". '$ROOT/termux/lib/common.sh'; unset NOPE; read_api_key NOPE < /dev/null"

echo "# CLI behaviour"
for g in freellmapi omniroute; do
  t  "$g help exits 0"                 bash "$ROOT/termux/$g.sh" help
  tn "$g unknown action exits non-zero" bash "$ROOT/termux/$g.sh" bogus
  tn "$g start before install refuses" bash "$ROOT/termux/$g.sh" start
  t  "$g status works when not installed" bash "$ROOT/termux/$g.sh" status
  tn "$g health fails when down"       env FREELLMAPI_PORT=39001 OMNIROUTE_PORT=39002 bash "$ROOT/termux/$g.sh" health
  tn "$g test-model without key (non-interactive) fails" env -u FREELLMAPI_KEY -u OMNIROUTE_KEY bash "$ROOT/termux/$g.sh" test-model --model x < /dev/null
  tn "$g rollback with no history refuses" bash "$ROOT/termux/$g.sh" rollback --yes
  tn "$g refuses equal ports"          env FREELLMAPI_PORT=4100 OMNIROUTE_PORT=4100 bash "$ROOT/termux/$g.sh" start
done
# Node-ABI guard: fake "installed" layouts whose recorded build Node differs from the current one.
mkdir -p "$GW_HOME/freellmapi/server/dist" "$GW_HOME/omniroute/node_modules/omniroute/bin"
touch "$GW_HOME/omniroute/node_modules/omniroute/bin/omniroute.mjs"
echo 0.0.1 > "$GW_STATE_DIR/freellmapi.node_version"; echo 0.0.1 > "$GW_STATE_DIR/omniroute.node_version"
for g in freellmapi omniroute; do
  t "$g start refuses when Node changed since build" bash -c "bash '$ROOT/termux/$g.sh' start 2>&1 | grep -q 'Node changed'"
done
rm -rf "$GW_HOME/freellmapi" "$GW_HOME/omniroute" "$GW_STATE_DIR"/*.node_version
tn "omniroute test-model requires --model" bash -c "OMNIROUTE_KEY=x bash '$ROOT/termux/omniroute.sh' test-model < /dev/null"
t  "audit --offline runs and reports"  bash -c "bash '$ROOT/termux/audit-env.sh' --offline | grep -q 'Summary:'"
tn "audit blocks equal ports"          env FREELLMAPI_PORT=4100 OMNIROUTE_PORT=4100 bash "$ROOT/termux/audit-env.sh" --offline
t  "scripts never write secrets into the repo tree" bash -c "cd '$ROOT' && [ -z \"\$(git status --porcelain 2>/dev/null | grep -E '\\.env\$|\\.sqlite|\\.tar\\.gz')\" ]"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
