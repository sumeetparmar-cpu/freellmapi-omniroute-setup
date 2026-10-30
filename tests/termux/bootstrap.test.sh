#!/usr/bin/env bash
# REAL end-to-end test of termux/bootstrap.sh on Linux: real git clone + npm install of the pinned FreeLLMAPI and OmniRoute, real API provisioning,
# real guards, real restart/crash recovery. It does NOT prove anything about Android/Termux (Bionic libc, pkg, battery management):
# see docs/PHONE-TERMUX.md "What needs a real phone". Real OVH inference is opt-in (LLM_TEST_INFERENCE=1): OVH's anonymous tier allows
# 2 requests/minute/model per IP, which a shared CI runner must not depend on.
#   LLM_TEST_BOOTSTRAP=1 bash tests/termux/bootstrap.test.sh        (takes ~4-8 minutes, needs network, ~3 GB disk)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "${LLM_TEST_BOOTSTRAP:-}" = 1 ] || { echo "SKIP: set LLM_TEST_BOOTSTRAP=1 (real installs, ~3 GB, network)"; exit 0; }
TMP="$(mktemp -d)"; PASS=0; FAIL=0
free_port() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }
export GW_HOME="$TMP/gw" HOME="$TMP/home"; mkdir -p "$HOME"
distinct_ports() { local out="" p; while [ "$(wc -w <<<"$out")" -lt 4 ]; do p="$(free_port)"; case " $out " in *" $p "*) ;; *) out="$out $p";; esac; done; echo "$out"; }
read -r FREELLMAPI_PORT OMNIROUTE_PORT GUARD_PORT_FREELLMAPI GUARD_PORT_OMNIROUTE <<<"$(distinct_ports)"
export FREELLMAPI_PORT OMNIROUTE_PORT GUARD_PORT_FREELLMAPI GUARD_PORT_OMNIROUTE
P_ALL="$FREELLMAPI_PORT $OMNIROUTE_PORT $GUARD_PORT_FREELLMAPI $GUARD_PORT_OMNIROUTE"
T="$ROOT/termux"; C="$GW_HOME/config"
cleanup() {
  bash "$T/gateways.sh" stop >/dev/null 2>&1
  local f p; for f in "$GW_HOME"/run/*.pid; do [ -f "$f" ] || continue; p="$(cat "$f")"; kill -KILL -- "-$p" 2>/dev/null; done
  rm -rf "$TMP"; echo "bootstrap (real install): passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
}
trap cleanup EXIT
ck() { local n="$1"; shift; if "$@" >"$TMP/out" 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; sed 's/^/       /' "$TMP/out" | tail -10; fi; }
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@"; }
listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
fingerprint() { (cd "$C" && sha256sum ./*.key ./*.clientkey ./*.admin ./*.apikey ./*.clients 2>/dev/null | sha256sum); }
loopback_only() { # every listener on our ports is bound to 127.0.0.1
  local p hex bad=0 found=0
  for p in $P_ALL; do
    hex=$(printf '%04X' "$p")
    while read -r addr; do found=$((found+1)); [ "$addr" = "0100007F:$hex" ] || bad=$((bad+1)); done < <(awk -v h=":$hex" 'NR>1 && $4=="0A" && index($2,h)>0 {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
  done
  [ "$found" -ge 4 ] && [ "$bad" -eq 0 ]
}

echo "# bootstrap #1 (real installs of the pinned versions; --no-packages: no pkg on Linux)"
bash "$T/bootstrap.sh" --no-packages --no-inference >"$TMP/b1.log" 2>&1; rc=$?
ck "bootstrap exits 0" test "$rc" = 0
[ "$rc" = 0 ] || tail -30 "$TMP/b1.log"
ck "FreeLLMAPI is the pinned v0.16.12 commit (36826e7)"  bash -c "head -c 7 '$GW_HOME/state/freellmapi.installed_commit' | grep -qx 36826e7"
ck "OmniRoute is the pinned 3.8.52"                       bash -c "grep -qx 3.8.52 '$GW_HOME/state/omniroute.installed_version'"
ck "every credential file is mode 600"                    bash -c "cd '$C' && for f in *; do [ \"\$(stat -c %a \"\$f\")\" = 600 ] || { echo \"\$f is \$(stat -c %a \"\$f\")\"; exit 1; }; done"
ck "all four listeners are bound to 127.0.0.1 only"       loopback_only
ck "FreeLLMAPI + OmniRoute health 200"                    bash -c "[ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' http://127.0.0.1:$FREELLMAPI_PORT/api/ping)\" = 200 ] && [ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' http://127.0.0.1:$OMNIROUTE_PORT/api/health/ping)\" = 200 ]"
FK="$(cat "$C/guard-freellmapi.clientkey")"; OK="$(cat "$C/guard-omniroute.clientkey")"
ck "FreeLLMAPI gateway: unified key 200, bad key 401"     bash -c "[ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$(cat '$C/freellmapi.unified.key')\" http://127.0.0.1:$FREELLMAPI_PORT/v1/models)\" = 200 ] && [ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' http://127.0.0.1:$FREELLMAPI_PORT/v1/models)\" = 401 ]"
ck "OmniRoute gateway: api key 200, bad key 401"          bash -c "[ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$(cat '$C/omniroute.apikey')\" http://127.0.0.1:$OMNIROUTE_PORT/v1/models)\" = 200 ] && [ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' http://127.0.0.1:$OMNIROUTE_PORT/v1/models)\" = 401 ]"
ck "FreeLLMAPI guard: guard key lists gpt-oss-20b"        bash -c "curl -s -m15 -H 'Authorization: Bearer $FK' http://127.0.0.1:$GUARD_PORT_FREELLMAPI/v1/models | grep -q '\"gpt-oss-20b\"'"
ck "OmniRoute guard: guard key can list models (HTTP 200); custom-node models are called by name, OmniRoute does not list them" bash -c "[ \"\$(curl -s -m15 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $OK' http://127.0.0.1:$GUARD_PORT_OMNIROUTE/v1/models)\" = 200 ]"
ck "guards: no key -> 401 (both)"                         bash -c "[ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' http://127.0.0.1:$GUARD_PORT_FREELLMAPI/v1/chat/completions)\" = 401 ] && [ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' http://127.0.0.1:$GUARD_PORT_OMNIROUTE/v1/chat/completions)\" = 401 ]"
ck "paid models refused by both guards (HTTP 403)"        bash -c "[ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer $FK' -H 'content-type: application/json' -d '{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}' http://127.0.0.1:$GUARD_PORT_FREELLMAPI/v1/chat/completions)\" = 403 ] && [ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer $OK' -H 'content-type: application/json' -d '{\"model\":\"openai/gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}' http://127.0.0.1:$GUARD_PORT_OMNIROUTE/v1/chat/completions)\" = 403 ]"
ck "fallback/routing body fields refused (OmniRoute guard)" bash -c "[ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer $OK' -H 'content-type: application/json' -d '{\"model\":\"ovhanon/gpt-oss-120b\",\"models\":[\"openai/gpt-4o\"],\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}' http://127.0.0.1:$GUARD_PORT_OMNIROUTE/v1/chat/completions)\" = 403 ]"
ck "free-only audit is clean (FreeLLMAPI + OmniRoute)"    bash -c ". '$C/freellmapi.admin'; export FREELLMAPI_ADMIN_EMAIL FREELLMAPI_ADMIN_PASSWORD; export OMNIROUTE_ADMIN_PASSWORD=\$(grep ^INITIAL_PASSWORD= '$C/omniroute.env' | cut -d= -f2-); node '$ROOT/tools/free-policy.mjs' freellmapi audit --base-url http://127.0.0.1:$FREELLMAPI_PORT && node '$ROOT/tools/free-policy.mjs' omniroute audit --base-url http://127.0.0.1:$OMNIROUTE_PORT"
ck "no gateway key or password leaked into logs/output"   bash -c "cd '$C'; for s in \$(head -n1 freellmapi.unified.key) \$(head -n1 omniroute.apikey) \$(grep ^FREELLMAPI_ADMIN_PASSWORD= freellmapi.admin | cut -d= -f2-) \$(grep ^INITIAL_PASSWORD= omniroute.env | cut -d= -f2-); do grep -rqF -- \"\$s\" '$TMP/b1.log' '$GW_HOME/logs' && { echo leak; exit 1; }; done; exit 0"
ck "summary shows endpoints, models and dashboards"       bash -c "grep -q 'Endpoints' '$TMP/b1.log' && grep -q 'Dashboards' '$TMP/b1.log' && grep -q 'gpt-oss-20b' '$TMP/b1.log' && grep -q 'ovhanon/gpt-oss-120b' '$TMP/b1.log'"
ck "provision refuses a non-loopback target"              bash -c "! node '$T/lib/provision.mjs' freellmapi --base http://example.com --cred-file '$TMP/c' --key-out '$TMP/k'"

if [ "${LLM_TEST_INFERENCE:-}" = 1 ]; then
  echo "# REAL inference (opt-in): OVH anonymous tier"
  ck "genuine completion through both guards"             bash "$T/gateways.sh" test
else echo "# real inference: not run (set LLM_TEST_INFERENCE=1; OVH allows 2 requests/minute/model per IP)"; fi

echo "# bootstrap #2: must change nothing"
F1="$(fingerprint)"
bash "$T/bootstrap.sh" --no-packages --no-inference >"$TMP/b2.log" 2>&1; rc=$?
ck "second run exits 0"                                    test "$rc" = 0
ck "keys and passwords are byte-identical after a re-run"  test "$(fingerprint)" = "$F1"
ck "re-run reports everything already done"               bash -c "grep -q 'already installed' '$TMP/b2.log' && grep -q 'already present' '$TMP/b2.log'"
ck "no duplicate FreeLLMAPI endpoint / OmniRoute node / connection" bash -c "
  TOK=\$(curl -s -m10 -X POST http://127.0.0.1:$FREELLMAPI_PORT/api/auth/login -H 'content-type: application/json' -d \"{\\\"email\\\":\\\"owner@gateway.invalid\\\",\\\"password\\\":\\\"\$(grep ^FREELLMAPI_ADMIN_PASSWORD= '$C/freellmapi.admin' | cut -d= -f2-)\\\"}\" | node -pe 'JSON.parse(require(\"fs\").readFileSync(0)).token')
  n1=\$(curl -s -m10 http://127.0.0.1:$FREELLMAPI_PORT/api/keys -H \"authorization: Bearer \$TOK\" | node -pe 'const d=JSON.parse(require(\"fs\").readFileSync(0));(Array.isArray(d)?d:d.keys).filter(k=>k.platform===\"custom\").length')
  curl -s -m10 -c '$TMP/cj' -X POST http://127.0.0.1:$OMNIROUTE_PORT/api/auth/login -H 'content-type: application/json' -d \"{\\\"password\\\":\\\"\$(grep ^INITIAL_PASSWORD= '$C/omniroute.env' | cut -d= -f2-)\\\"}\" -o /dev/null
  n2=\$(curl -s -m10 -b '$TMP/cj' http://127.0.0.1:$OMNIROUTE_PORT/api/provider-nodes | node -pe 'JSON.parse(require(\"fs\").readFileSync(0)).nodes.length')
  n3=\$(curl -s -m10 -b '$TMP/cj' http://127.0.0.1:$OMNIROUTE_PORT/api/providers | node -pe 'JSON.parse(require(\"fs\").readFileSync(0)).connections.length')
  echo \"endpoints=\$n1 nodes=\$n2 connections=\$n3\"; [ \"\$n1\" = 1 ] && [ \"\$n2\" = 1 ] && [ \"\$n3\" = 1 ]"

echo "# stop / start / crash recovery"
ck "stop closes all four ports"                            bash -c "bash '$T/gateways.sh' stop >/dev/null 2>&1; for p in $P_ALL; do (exec 3<>/dev/tcp/127.0.0.1/\$p) 2>/dev/null && exit 1; done; exit 0"
ck "start brings all four back and doctor is clean"        bash -c "bash '$T/gateways.sh' start >/dev/null 2>&1 && bash '$T/gateways.sh' doctor >/dev/null 2>&1"
kill -KILL "$(cat "$GW_HOME/run/freellmapi.pid")" 2>/dev/null; sleep 2
ck "doctor notices a killed FreeLLMAPI (zombie ignored)"   bash -c "! bash '$T/gateways.sh' doctor >/dev/null 2>&1"
ck "start recovers it"                                     bash -c "bash '$T/gateways.sh' start >/dev/null 2>&1 && bash '$T/gateways.sh' doctor >/dev/null 2>&1"
kill -KILL "$(cat "$GW_HOME/run/omniroute.pid")" 2>/dev/null; sleep 2
ck "OmniRoute orphaned child still counts as running"      bash -c "bash '$T/gateways.sh' status 2>&1 | grep -E 'OmniRoute +running'"
ck "restart cleans the orphan and brings everything back"  bash -c "bash '$T/gateways.sh' restart >/dev/null 2>&1 && bash '$T/gateways.sh' doctor >/dev/null 2>&1"
ck "after stop, no process of any gateway group remains"   bash -c "bash '$T/gateways.sh' stop >/dev/null 2>&1; for p in $P_ALL; do (exec 3<>/dev/tcp/127.0.0.1/\$p) 2>/dev/null && exit 1; done; exit 0"
