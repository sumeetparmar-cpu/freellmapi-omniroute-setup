#!/usr/bin/env bash
# END-TO-END rehearsal of the VPS deployment on a DISPOSABLE machine (CI runner or sandbox). Uses the real deploy.sh, the real pinned Node
# download, real installs of both gateways as separate users, and a local MOCK upstream (no provider key, no provider traffic).
#
#   sudo LLM_TEST_ALLOW_SYSTEM_CHANGES=1 bash tests/vps/e2e-sandbox.sh
#
# It creates users llme2efree / llme2eomni and /srv/llme2e-PID, and removes them at the end. systemd is not required: services are started
# with LLM_NO_SYSTEMD=1 (the toolkit's own process control), so the systemd path itself is NOT exercised here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$(id -u)" = 0 ] && [ "${LLM_TEST_ALLOW_SYSTEM_CHANGES:-}" = 1 ] || { echo "refusing: needs root and LLM_TEST_ALLOW_SYSTEM_CHANGES=1 (creates real users/directories)"; exit 2; }
TMP="$(mktemp -d)"; E="/srv/llme2e-$$"; UF=llme2efree; UO=llme2eomni; PF=${E2E_PORT_FL:-18701}; PO=${E2E_PORT_OM:-18702}; PM=${E2E_PORT_MOCK:-18703}
export LLM_ROOT="$E" LLM_USER_FREELLMAPI=$UF LLM_USER_OMNIROUTE=$UO SYSTEMD_DIR="$TMP/units" SYSTEMD_RUN_DIR=/nonexistent LLM_NO_SYSTEMD=1
mkdir -p "$TMP/units"
# Run from a directory the service users cannot enter (like /root/llm-deploy on a real server): they must not inherit it as cwd.
cd "$TMP" || exit 2
PASS=0; FAIL=0; MOCK=""
ck() { local n="$1"; shift; if "$@" >"$TMP/o" 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; tail -8 "$TMP/o" | sed 's/^/       /'; fi; }
cleanup() {
  echo "# cleanup"
  [ -n "$MOCK" ] && kill "$MOCK" 2>/dev/null
  for g in freellmapi omniroute; do [ -x "$E/toolkit/vps/gwctl.sh" ] && "$E/toolkit/vps/gwctl.sh" $g stop >/dev/null 2>&1; done
  sleep 1; pkill -u $UF 2>/dev/null; pkill -u $UO 2>/dev/null; sleep 1
  for u in $UF $UO; do getent passwd $u >/dev/null && userdel $u 2>/dev/null; done
  case "$E" in /srv/llme2e-*) rm -rf -- "$E";; esac; rm -rf -- "$TMP"
  echo "passed=$PASS failed=$FAIL"
}
trap cleanup EXIT
D() { "$ROOT/vps/deploy.sh" --apply "$@"; }
G() { "$E/toolkit/vps/gwctl.sh" "$@"; }
jget() { node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const d=JSON.parse(s);process.stdout.write(String(eval(process.argv[1])))})' "$1"; }

echo "# gates: preflight + inventory baseline (read-only)"
"$ROOT/vps/preflight.sh" --freellmapi-port $PF --omniroute-port $PO --out "$TMP/pf.txt" >"$TMP/pf.log" 2>&1; grep -E "^\[(BLOCK|WARN)" "$TMP/pf.log" | sed 's/^/       /'
# Preflight BLOCKs here only because systemd is not running in a plain container; that is expected and the gate must then REFUSE.
if grep -q '^RESULT: BLOCKED' "$TMP/pf.txt"; then
  ck "deploy refuses to start with a BLOCKED preflight (gate works)" bash -c "! '$ROOT/vps/deploy.sh' --apply users --preflight '$TMP/pf.txt' --baseline /dev/null"
  # rehearsal override: record that this machine is a container without systemd, the only blocker allowed
  [ "$(grep -c '^\[BLOCK\]' "$TMP/pf.txt")" = 1 ] && grep -q '^\[BLOCK\] systemd' "$TMP/pf.txt" && sed -i 's/^RESULT: BLOCKED/RESULT: PASS-WITH-WARNINGS (rehearsal: systemd absent)/' "$TMP/pf.txt"
fi
"$ROOT/vps/inventory.sh" snapshot --out "$TMP/base.snap" >/dev/null 2>&1
ck "baseline snapshot exists" test -s "$TMP/base.snap"
GATE=(--preflight "$TMP/pf.txt" --baseline "$TMP/base.snap")

echo "# deploy: users dirs runtime toolkit config"
ck "users"   D users "${GATE[@]}"
ck "dirs"    D dirs
ck "runtime (REAL Node download, SHA-256 pinned)" D runtime
ck "pinned Node is v24.x"  bash -c "$E/runtime/node/bin/node -v | grep -q '^v24\.'"
ck "toolkit" D toolkit
ck "config"  D config --freellmapi-port $PF --omniroute-port $PO

echo "# install both gateways as their own users (real npm/git work; takes a few minutes)"
ck "install freellmapi (as $UF)" D install freellmapi
ck "install omniroute (as $UO)"  D install omniroute
ck "secrets generated server-side, 0600, owned by the service user" bash -c "[ \"\$(stat -c '%a %U' $E/freellmapi/config/freellmapi.env)\" = '600 $UF' ] && [ \"\$(stat -c '%a %U' $E/omniroute/config/omniroute.env)\" = '600 $UO' ]"
ck "no secret values leaked into the deploy log" bash -c "! grep -qE '[A-Fa-f0-9]{48}' $E/deploy.log"
ck "units render+verify" D units
ck "OmniRoute runs on the pinned Node, not the system one" bash -c "grep -q 'v24' <(runuser -u $UO -- env PATH=$E/runtime/node/bin:/usr/bin node -v)"

echo "# test-only mock upstream for FreeLLMAPI (declarative config appended to ITS env file)"
node "$ROOT/tests/mock-openai-server.mjs" $PM ok >/dev/null 2>&1 & MOCK=$!
sleep 1
printf 'FREEAPI_CONFIG_JSON={"admin":{"email":"e2e@example.test","password":"e2e-test-password-1"},"customProviders":[{"baseUrl":"http://127.0.0.1:%s/v1","label":"MockLocal","apiKey":"mock-key","models":[{"model":"mock-model","displayName":"Mock"}]}]}\n' $PM >> "$E/freellmapi/config/freellmapi.env"

echo "# start both (no systemd here) + health + containment verification"
ck "enable freellmapi" D enable freellmapi --baseline "$TMP/base.snap"
ck "enable omniroute"  D enable omniroute --baseline "$TMP/base.snap"
ck "freellmapi health" G freellmapi health
ck "omniroute health"  G omniroute health
ck "both answer on 127.0.0.1 at the configured ports" bash -c "for p in $PF $PO; do (exec 3<>/dev/tcp/127.0.0.1/\$p) 2>/dev/null || exit 1; done"
ck "verify.sh passes (existing server unchanged, services contained)" "$ROOT/vps/verify.sh" --baseline "$TMP/base.snap"
ck "monitor check is OK" bash -c "MON_DISK_WARN_GB=1 MON_DISK_CRIT_GB=1 $E/toolkit/vps/monitor.sh check | grep -q 'OVERALL: OK'"

echo "# credentials and read-only quota reports through gwctl"
TOKEN="$(curl -s -X POST localhost:$PF/api/auth/login -H 'content-type: application/json' -d '{"email":"e2e@example.test","password":"e2e-test-password-1"}' | jget 'd.token')"
KEY="$(curl -s localhost:$PF/api/settings/api-key -H "Authorization: Bearer $TOKEN" | jget 'd.apiKey')"
ck "unified key obtained from the dashboard API (not printed)" test -n "$KEY"
ck "put-key stores it 0600 for the service user" bash -c "printf '%s' '$KEY' | $E/toolkit/vps/gwctl.sh freellmapi put-key && [ \"\$(stat -c '%a %U' $E/freellmapi/config/client.key)\" = '600 $UF' ]"
ck "test-model through the real gateway -> mock upstream" G freellmapi test-model
ck "freellmapi quota-report is labelled and read-only" bash -c "$E/toolkit/vps/gwctl.sh freellmapi quota-report | grep -q '\[GATEWAY\] month'"
ck "quota-report output never contains the key" bash -c "! $E/toolkit/vps/gwctl.sh freellmapi quota-report 2>&1 | grep -qF '$KEY'"
PW="$(grep '^INITIAL_PASSWORD=' "$E/omniroute/config/omniroute.env" | cut -d= -f2)"
curl -s -c "$TMP/cj" -X POST localhost:$PO/api/auth/login -H 'content-type: application/json' -d "{\"password\":\"$PW\"}" -o /dev/null
MT="$(curl -s -b "$TMP/cj" -X POST localhost:$PO/api/cli/tokens -H 'content-type: application/json' -d '{"name":"e2e-read","scope":"read"}' | jget 'd.token')"
ck "read-scope token obtained (not printed)" bash -c "case '$MT' in oma_live_*) exit 0;; *) exit 1;; esac"
ck "put-key stores the token" bash -c "printf '%s' '$MT' | $E/toolkit/vps/gwctl.sh omniroute put-key && [ \"\$(stat -c '%a %U' $E/omniroute/config/mgmt.token)\" = '600 $UO' ]"
ck "omniroute quota-report is labelled and read-only" bash -c "$E/toolkit/vps/gwctl.sh omniroute quota-report | grep -q '\[GATEWAY\] rolling last 30 days'"
ck "quota-report output never contains the token" bash -c "! $E/toolkit/vps/gwctl.sh omniroute quota-report 2>&1 | grep -qF '$MT'"

echo "# backup / restore through gwctl"
ck "gwctl backup (stop, back up, restart)" G freellmapi backup
ck "backup exists, 0600, owned by the service user" bash -c "f=\$(ls -1 $E/freellmapi/backups/freellmapi/*.tar.gz | head -1); [ \"\$(stat -c '%a %U' \"\$f\")\" = '600 $UF' ]"
ck "freellmapi healthy again after the backup cycle" bash -c "$E/toolkit/vps/gwctl.sh freellmapi health"
ck "backup-run (scheduled label + pruning)" "$E/toolkit/vps/backup-run.sh" freellmapi --keep 2
ck "scheduled backup present" bash -c "ls $E/freellmapi/backups/freellmapi/*-scheduled.tar.gz"
ck "verify.sh still passes after all operations" "$ROOT/vps/verify.sh" --baseline "$TMP/base.snap"

echo "# removal leaves the rest alone"
ck "stop omniroute" G omniroute stop
ck "remove --purge omniroute" D remove omniroute --purge --yes-delete-data
ck "omniroute gone, freellmapi and toolkit intact" bash -c "[ ! -e $E/omniroute ] && ! getent passwd $UO && [ -d $E/freellmapi ] && [ -d $E/toolkit ] && getent passwd $UF >/dev/null"
[ "$FAIL" -eq 0 ]
