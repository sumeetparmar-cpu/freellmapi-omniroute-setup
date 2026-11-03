#!/usr/bin/env bash
# termux/free-guard.sh against a stand-in gateway (no network, no real keys). Runs on Linux; the Termux-specific parts are only pkg/Android.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; PASS=0; FAIL=0; PIDS=()
cleanup() {
  local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  GW_HOME="$TMP/gw" bash "$ROOT/termux/free-guard.sh" stop >/dev/null 2>&1; rm -rf "$TMP"
  echo "free-guard (termux): passed=$PASS failed=$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1   # an EXIT trap must call exit: bash ignores its last status otherwise (a failing run would report success)
}
trap cleanup EXIT
ck() { local n="$1"; shift; if "$@" >"$TMP/out" 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; sed 's/^/       /' "$TMP/out" | tail -8; fi; }
free_port() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }
FP=$(free_port); OP=$(free_port); GF=$(free_port); GO=$(free_port)
export GW_HOME="$TMP/gw" FREELLMAPI_PORT=$FP OMNIROUTE_PORT=$OP GUARD_PORT_FREELLMAPI=$GF GUARD_PORT_OMNIROUTE=$GO
G="$ROOT/termux/free-guard.sh"
GWKEY="gwkey-$(date +%s%N | sha256sum | cut -c1-24)"; echo "$GWKEY" > "$TMP/gwkey"
# stand-in gateway: records the Authorization it receives
cat > "$TMP/up.mjs" <<'JS'
import http from 'node:http'; import { appendFileSync } from 'node:fs';
const [port, rec] = process.argv.slice(2);
http.createServer((q, s) => { let b = ''; q.on('data', (c) => (b += c)); q.on('end', () => { appendFileSync(rec, (q.headers.authorization ?? '-') + '\n'); s.writeHead(200, { 'content-type': 'application/json' }); s.end('{"choices":[{"message":{"content":"ok"}}]}'); }); }).listen(+port, '127.0.0.1');
JS
node "$TMP/up.mjs" "$FP" "$TMP/rec-fl" & PIDS+=($!); node "$TMP/up.mjs" "$OP" "$TMP/rec-om" & PIDS+=($!); sleep 1
code() { curl -s -m 8 -o /dev/null -w '%{http_code}' "$@"; }
body='{"model":"gpt-oss-20b","messages":[{"role":"user","content":"hi"}]}'

ck "start refuses before setup"                      bash -c "! bash '$G' start freellmapi"
ck "setup needs a key (no tty, none given)"          bash -c "! bash '$G' setup freellmapi </dev/null"
bash "$G" setup freellmapi --key-file "$TMP/gwkey" >"$TMP/setup.out" 2>&1
CK="$(grep -oE 'fg_[A-Za-z0-9_-]+' "$TMP/setup.out" | head -1)"
ck "setup prints a guard key once (fg_...)"          test -n "$CK"
ck "the gateway key was NOT printed by setup"        bash -c "! grep -q '$GWKEY' '$TMP/setup.out'"
ck "upstream key file is mode 600"                   bash -c "[ \"\$(stat -c %a '$GW_HOME/config/free-guard-freellmapi.upstream.key')\" = 600 ]"
ck "client file is mode 600 and holds a hash, not the key" bash -c "[ \"\$(stat -c %a '$GW_HOME/config/free-guard-freellmapi.clients')\" = 600 ] && ! grep -q '$CK' '$GW_HOME/config/free-guard-freellmapi.clients'"
ck "start freellmapi guard"                          bash "$G" start freellmapi
ck "start again is idempotent"                       bash "$G" start freellmapi
ck "status reports running"                          bash -c "bash '$G' status freellmapi 2>&1 | grep -q 'running'"
ck "no client key -> 401"                            bash -c "[ \"\$(curl -s -m8 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '$body' http://127.0.0.1:$GF/v1/chat/completions)\" = 401 ]"
ck "guard key -> 200 through to the gateway"         bash -c "[ \"\$(curl -s -m8 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -H 'Authorization: Bearer $CK' -d '$body' http://127.0.0.1:$GF/v1/chat/completions)\" = 200 ]"
ck "gateway received ITS key, not the guard key"     bash -c "grep -qx 'Bearer $GWKEY' '$TMP/rec-fl' && ! grep -q '$CK' '$TMP/rec-fl'"
ck "paid model refused locally (nothing upstream)"   bash -c "n0=\$(wc -l < '$TMP/rec-fl'); [ \"\$(curl -s -m8 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -H 'Authorization: Bearer $CK' -d '{\"model\":\"gpt-4o\",\"messages\":[]}' http://127.0.0.1:$GF/v1/chat/completions)\" = 403 ] && [ \"\$(wc -l < '$TMP/rec-fl')\" = \"\$n0\" ]"
ck "guard listens on loopback only"                  bash -c "grep -q ':0100007F:' <(awk 'NR>1 && \$4==\"0A\"{print \":\"\$2\":\"}' /proc/net/tcp) || awk 'NR>1 && \$4==\"0A\"' /proc/net/tcp | grep -qi '0100007F:$(printf '%04X' $GF)'"
ck "log has no keys"                                 bash -c "! grep -rq -e '$GWKEY' -e '$CK' '$GW_HOME/logs'"
# omniroute guard is independent
bash "$G" setup omniroute --key-file "$TMP/gwkey" >"$TMP/setup2.out" 2>&1; CK2="$(grep -oE 'fg_[A-Za-z0-9_-]+' "$TMP/setup2.out" | head -1)"
ck "start omniroute guard"                           bash "$G" start omniroute
ck "omniroute guard: model must carry a policy prefix" bash -c "[ \"\$(curl -s -m8 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -H 'Authorization: Bearer $CK2' -d '{\"model\":\"gpt-oss-20b\",\"messages\":[]}' http://127.0.0.1:$GO/v1/chat/completions)\" = 403 ]"
ck "stop freellmapi guard only"                      bash "$G" stop freellmapi
ck "freellmapi guard port released"                  bash -c "! (exec 3<>/dev/tcp/127.0.0.1/$GF) 2>/dev/null"
ck "omniroute guard still serving"                   bash -c "[ \"\$(curl -s -m8 -o /dev/null -w '%{http_code}' http://127.0.0.1:$GO/__guard/status)\" = 200 ]"
ck "port conflict is refused"                        bash -c "node -e 'require(\"net\").createServer().listen($GF,\"127.0.0.1\")' & p=\$!; sleep 1; ! bash '$G' start freellmapi; r=\$?; kill \$p; [ \$r = 0 ]"
ck "stop both"                                       bash "$G" stop
