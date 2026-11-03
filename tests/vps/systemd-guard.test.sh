#!/usr/bin/env bash
# Real-systemd validation of the free-only guard + audit units. Meant for disposable CI runners (ubuntu-24.04 / ubuntu-26.04).
#   sudo LLM_TEST_ALLOW_SYSTEM_CHANGES=1 bash tests/vps/systemd-guard.test.sh
# Makes REAL changes: two throw-away system users, /srv/llmtest-sd-PID, and llm-guard-*/llm-free-audit-* unit files in
# /etc/systemd/system. It refuses to run if: not root, the flag is missing, systemd is not PID 1, or any llm-guard-* unit already exists
# (so it can never touch a real install). Everything is removed on exit.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$(id -u)" = 0 ] && [ "${LLM_TEST_ALLOW_SYSTEM_CHANGES:-}" = 1 ] || { echo "refusing: needs root and LLM_TEST_ALLOW_SYSTEM_CHANGES=1"; exit 2; }
if [ ! -d /run/systemd/system ]; then
  [ "${REQUIRE_SYSTEMD:-}" = 1 ] && { echo "FAIL: systemd is not running but REQUIRE_SYSTEMD=1"; exit 1; }
  echo "SKIP: systemd is not running here (set REQUIRE_SYSTEMD=1 to make this a failure)"; exit 0
fi
ls /etc/systemd/system/llm-guard-*.service /etc/systemd/system/llm-free-audit-*.service >/dev/null 2>&1 && { echo "refusing: real llm-guard/audit units already exist on this host"; exit 2; }
command -v node >/dev/null || { echo "node is required"; exit 2; }

SFX=$$; UF="llmsdf$SFX"; UO="llmsdo$SFX"
export LLM_ROOT="/srv/llmtest-sd-$SFX" LLM_USER_FREELLMAPI="$UF" LLM_USER_OMNIROUTE="$UO"
SD=/etc/systemd/system; TK="$LLM_ROOT/toolkit"; NODE="$LLM_ROOT/runtime/node/bin/node"
PF=$((31000 + SFX % 1000)); PO=$((PF + 1)); GF=$((PF + 2)); GO=$((PF + 3))   # gateway + guard ports (loopback)
export GUARD_PORT_FREELLMAPI="$GF" GUARD_PORT_OMNIROUTE="$GO"
PASS=0; FAIL=0; PIDS=()
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; fi; }

cleanup() {
  kill "${PIDS[@]}" 2>/dev/null
  for gw in freellmapi omniroute; do
    systemctl disable --now "llm-guard-$gw.service" "llm-free-audit-$gw.timer" >/dev/null 2>&1
    systemctl stop "llm-free-audit-$gw.service" >/dev/null 2>&1
    rm -f "$SD/llm-guard-$gw.service" "$SD/llm-free-audit-$gw.service" "$SD/llm-free-audit-$gw.timer"
  done
  rm -f "$SD/llm-sbxa.service" "$SD/llm-sbxb.service"; systemctl daemon-reload >/dev/null 2>&1
  case "$LLM_ROOT" in /srv/llmtest-sd-*) rm -rf -- "$LLM_ROOT";; esac
  getent passwd "$UF" >/dev/null && userdel "$UF" 2>/dev/null; getent passwd "$UO" >/dev/null && userdel "$UO" 2>/dev/null
}
trap cleanup EXIT

echo "# host: $(. /etc/os-release; echo "$PRETTY_NAME"), systemd $(systemctl --version | head -n1 | cut -d' ' -f2), node $(node -v)"
# ---- layout identical to deploy.sh's, with a copy of the running node as the pinned runtime
useradd --system --no-create-home --shell /usr/sbin/nologin -U "$UF" && useradd --system --no-create-home --shell /usr/sbin/nologin -U "$UO" || { echo "cannot create users"; exit 2; }
install -d -m 0755 "$LLM_ROOT" "$LLM_ROOT/runtime/node/bin" "$TK"
cp "$(command -v node)" "$NODE"
tar -C "$ROOT" -cf - termux tools vps config | tar -C "$TK" -xf - --no-same-owner
chown -R root:root "$LLM_ROOT/runtime" "$TK"; chmod -R go-w "$LLM_ROOT/runtime" "$TK"
for gw in freellmapi omniroute; do
  u=$([ "$gw" = freellmapi ] && echo "$UF" || echo "$UO")
  install -d -m 0700 -o "$u" -g "$u" "$LLM_ROOT/$gw" "$LLM_ROOT/$gw/config" "$LLM_ROOT/$gw/state" "$LLM_ROOT/$gw/logs" "$LLM_ROOT/$gw/home"
done
printf 'PORT_FREELLMAPI=%s\nPORT_OMNIROUTE=%s\n' "$PF" "$PO" > "$LLM_ROOT/deploy.conf"
# mock gateways (as root; they only listen on loopback)
MD_F="$(mktemp -d)"; MD_O="$(mktemp -d)"
"$NODE" "$ROOT/tests/vps/mock-gateway.mjs" "$PF" "$MD_F" & PIDS+=("$!")
"$NODE" "$ROOT/tests/vps/mock-gateway.mjs" "$PO" "$MD_O" & PIDS+=("$!")
sleep 1

# ---- install through the real installer
t "installer renders + verifies the 6 units"   bash -c "bash '$ROOT/vps/free-install.sh' --apply units --client-keys"
t "units are on disk and systemd knows them"   bash -c "systemctl cat llm-guard-omniroute.service llm-free-audit-freellmapi.timer >/dev/null"
FK="$LLM_ROOT/freellmapi/config"; OK="$LLM_ROOT/omniroute/config"
CKF="$(runuser -u "$UF" -- "$NODE" "$TK/tools/free-guard.mjs" --new-client-key ci --client-keys-file "$FK/free-guard.clients")"
CKO="$(runuser -u "$UO" -- "$NODE" "$TK/tools/free-guard.mjs" --new-client-key ci --client-keys-file "$OK/free-guard.clients")"
printf 'ups-token-freellmapi\n' | runuser -u "$UF" -- sh -c "umask 077; cat > '$FK/free-guard.upstream.key'"
printf 'ups-token-omniroute\n' | runuser -u "$UO" -- sh -c "umask 077; cat > '$OK/free-guard.upstream.key'"
printf 'FREELLMAPI_ADMIN_TOKEN=adm-token-f\n' > "$FK/free-audit.env"; chown "$UF:$UF" "$FK/free-audit.env"; chmod 600 "$FK/free-audit.env"
printf 'OMNIROUTE_MGMT_TOKEN=mgmt-token-o\n' > "$OK/free-audit.env"; chown "$UO:$UO" "$OK/free-audit.env"; chmod 600 "$OK/free-audit.env"
t "enable omniroute guard (answers on its port)"  bash -c "bash '$ROOT/vps/free-install.sh' --apply enable omniroute"
t "enable freellmapi guard (answers on its port)" bash -c "bash '$ROOT/vps/free-install.sh' --apply enable freellmapi"
t "both guards active"                         bash -c "systemctl is-active --quiet llm-guard-omniroute.service && systemctl is-active --quiet llm-guard-freellmapi.service"
t "audit timers active"                        bash -c "systemctl is-active --quiet llm-free-audit-omniroute.timer && systemctl is-active --quiet llm-free-audit-freellmapi.timer"

# ---- effective unit properties as systemd sees them
prop() { systemctl show "$1" -p "$2" --value; }
t "guard runs as its gateway's user"           bash -c "[ \"\$(systemctl show llm-guard-omniroute.service -p User --value)\" = '$UO' ] && [ \"\$(systemctl show llm-guard-freellmapi.service -p User --value)\" = '$UF' ]"
t "guard process really runs as that user (uid)" bash -c "[ \"\$(ps -o uid= -p \$(systemctl show llm-guard-omniroute.service -p MainPID --value) | tr -d ' ')\" = \"\$(id -u '$UO')\" ]"
t "NoNewPrivileges + ProtectSystem=strict"     bash -c "[ \"\$(systemctl show llm-guard-omniroute.service -p NoNewPrivileges --value)\" = yes ] && [ \"\$(systemctl show llm-guard-omniroute.service -p ProtectSystem --value)\" = strict ]"
t "Restart=always, MemoryMax capped"           bash -c "[ \"\$(systemctl show llm-guard-omniroute.service -p Restart --value)\" = always ] && [ \"\$(systemctl show llm-guard-omniroute.service -p MemoryMax --value)\" != infinity ]"

# ---- behaviour through the real service
G="http://127.0.0.1:$GO"; GFL="http://127.0.0.1:$GF"
body='{"model":"groq/openai/gpt-oss-20b","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}'
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
t "no client key => 401"                       bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $G/v1/chat/completions -H 'content-type: application/json' -d '$body')\" = 401 ]"
t "allowed model with client key => 200"       bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $G/v1/chat/completions -H 'authorization: Bearer $CKO' -H 'content-type: application/json' -H 'x-omniroute-connection: paid' -d '$body')\" = 200 ]"
t "paid model => 403 and never reaches the gateway" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $G/v1/chat/completions -H 'authorization: Bearer $CKO' -H 'content-type: application/json' -d '{\"model\":\"openai/gpt-4o\",\"messages\":[]}')\" = 403 ] && ! grep -q gpt-4o '$MD_O/seen.jsonl'"
t "gateway got the UPSTREAM key, not the client key, and no routing header" bash -c "tail -n 3 '$MD_O/seen.jsonl' | grep chat/completions | grep -q 'ups-token-omniroute' && ! grep -q '$CKO' '$MD_O/seen.jsonl' && ! grep -q 'x-omniroute-connection' '$MD_O/seen.jsonl'"
t "unlisted route => 403"                      bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $G/v1/images/generations -H 'authorization: Bearer $CKO' -X POST -H 'content-type: application/json' -d '{}')\" = 403 ]"
t "FreeLLMAPI guard serves an allowed raw model id too" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $GFL/v1/chat/completions -H 'authorization: Bearer $CKF' -H 'content-type: application/json' -d '{\"model\":\"openai/gpt-oss-120b\",\"messages\":[]}')\" = 200 ]"
t "state + log files are 0600 and owned by the service user" bash -c "sleep 1; ls -l '$LLM_ROOT/omniroute/state/free-guard.json' '$LLM_ROOT/omniroute/logs/free-guard.log' | grep -c -- '-rw-------.* $UO ' | grep -q 2"
t "guard log has no credentials"               bash -c "! grep -qE '$CKO|ups-token|mgmt-token' '$LLM_ROOT/omniroute/logs/free-guard.log'"

# ---- sandbox: re-use the rendered guard unit's directives but run a probe instead of node.
# Probe A runs as root with the unit's empty capability set, so ProtectSystem/ReadWritePaths/ProtectHome are the only barriers.
# Probe B runs as the service user and must still be able to write its own state dir.
probe() { # probe NAME USER COMMAND
  sed -e "s~^ExecStart=.*~ExecStart=/bin/sh -c '$3'~" -e "s~^User=.*~User=$2~" -e "s~^Group=.*~Group=$2~" \
      -e 's~^Restart=always~Restart=no~' -e 's~^Type=simple~Type=oneshot~' -e '/^\[Install\]/,$d' "$SD/llm-guard-omniroute.service" > "$SD/$1.service"
  systemctl daemon-reload; systemctl start "$1.service" || echo "# probe $1 exited non-zero"; rm -f "$SD/$1.service"
}
probe llm-sbxa root "touch /usr/lib/sbx-x 2>/dev/null \&\& echo WROTE_USR || echo USR_DENIED; touch /etc/sbx-x 2>/dev/null \&\& echo WROTE_ETC || echo ETC_DENIED; touch $LLM_ROOT/toolkit/sbx 2>/dev/null \&\& echo WROTE_TOOLKIT || echo TOOLKIT_DENIED; ls /root >/dev/null 2>\&1 \&\& echo ROOT_HOME_VISIBLE || echo ROOT_HOME_DENIED"
# Probe A's output goes to the journal (root without CAP_DAC_OVERRIDE cannot create files in the service user's 0700 dir).
sleep 1; OUTA="$(journalctl -u llm-sbxa.service -o cat --no-pager 2>&1)"
t "sandbox (as root!): /usr and /etc are read-only"  bash -c "echo '$OUTA' | grep -q USR_DENIED && echo '$OUTA' | grep -q ETC_DENIED"
t "sandbox: the root-owned toolkit is read-only"     bash -c "echo '$OUTA' | grep -q TOOLKIT_DENIED"
t "sandbox: /root (home) is hidden even from root"   bash -c "echo '$OUTA' | grep -q ROOT_HOME_DENIED"
t "sandbox probe really ran (no WROTE_/VISIBLE markers)" bash -c "echo '$OUTA' | grep -q USR_DENIED && ! echo '$OUTA' | grep -qE 'WROTE_|ROOT_HOME_VISIBLE'"
OUTB="$LLM_ROOT/omniroute/state/probeB.out"
probe llm-sbxb "$UO" "{ touch $LLM_ROOT/omniroute/state/sbx-own \&\& echo OWN_OK || echo OWN_FAIL; } > $OUTB 2>\&1"
t "sandbox: the service user can write its own state dir" bash -c "grep -q OWN_OK '$OUTB'"

# ---- crash recovery: kill -9 => systemd restarts it; counters survive
before="$(curl -s $G/__guard/status | "$NODE" -e 'let t="";process.stdin.on("data",d=>t+=d).on("end",()=>console.log(JSON.parse(t).requestsToday.groq))')"
oldpid="$(prop llm-guard-omniroute.service MainPID)"; kill -9 "$oldpid"
for _ in $(seq 1 30); do sleep 0.5; np="$(prop llm-guard-omniroute.service MainPID)"; [ "$np" != "$oldpid" ] && [ "$np" != 0 ] && systemctl is-active --quiet llm-guard-omniroute.service && break; done
t "kill -9 => restarted automatically with a new PID" bash -c "[ '$np' != '$oldpid' ] && [ '$np' != 0 ] && systemctl is-active --quiet llm-guard-omniroute.service"
sleep 1
after="$(curl -s $G/__guard/status | "$NODE" -e 'let t="";process.stdin.on("data",d=>t+=d).on("end",()=>console.log(JSON.parse(t).requestsToday.groq))')"
t "daily counter survived the crash ($before -> $after)" bash -c "[ -n '$before' ] && [ '$after' -ge '$before' ]"

# ---- graceful stop with a never-ending stream open must finish inside the drain window
( curl -s -N -m 30 "$G/v1/chat/completions" -H "authorization: Bearer $CKO" -H 'content-type: application/json' -d '{"model":"groq/openai/gpt-oss-20b","stream":true,"messages":[]}' >/dev/null 2>&1 & )
sleep 1; t0=$(date +%s); systemctl stop llm-guard-omniroute.service; t1=$(date +%s)
t "systemctl stop with an open stream takes <= 10 s ($((t1-t0)) s)" bash -c "[ $((t1-t0)) -le 10 ]"
t "stopped guard is inactive, not failed"      bash -c "[ \"\$(systemctl is-active llm-guard-omniroute.service)\" = inactive ]"
t "independence: the FreeLLMAPI guard kept answering while OmniRoute's was stopped" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $GFL/__guard/status)\" = 200 ]"
systemctl start llm-guard-omniroute.service; sleep 1
t "restarted guard answers again"              bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $G/__guard/status)\" = 200 ]"
t "state files are separate per gateway"       bash -c "[ -f '$LLM_ROOT/omniroute/state/free-guard.json' ] && [ -f '$LLM_ROOT/freellmapi/state/free-guard.json' ] && ! cmp -s '$LLM_ROOT/omniroute/state/free-guard.json' '$LLM_ROOT/freellmapi/state/free-guard.json'"

# ---- audit service -> kill switch -> recovery (OmniRoute: read-only audit)
echo '{"connections":[{"provider":"openai"}]}' > "$MD_O/providers.json"
t "audit service FAILS when a non-free provider is connected" bash -c "! systemctl start llm-free-audit-omniroute.service"
t "kill flag exists (state dir, owned by service user)" bash -c "[ -f '$LLM_ROOT/omniroute/state/free-audit.flag' ]"
t "guard now refuses inference with 503 kill_switch" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $G/v1/chat/completions -H 'authorization: Bearer $CKO' -H 'content-type: application/json' -d '$body')\" = 503 ]"
t "monitor reports the engaged kill switch as CRIT" bash -c "bash '$ROOT/vps/monitor.sh' check 2>&1 | grep -q 'CRIT  omniroute.guard.kill-switch'"
echo '{"connections":[{"provider":"groq"}]}' > "$MD_O/providers.json"
t "audit service passes once the provider is removed" bash -c "systemctl start llm-free-audit-omniroute.service"
t "kill flag cleared and inference works again" bash -c "[ ! -e '$LLM_ROOT/omniroute/state/free-audit.flag' ] && [ \"\$(curl -s -o /dev/null -w '%{http_code}' $G/v1/chat/completions -H 'authorization: Bearer $CKO' -H 'content-type: application/json' -d '$body')\" = 200 ]"

# ---- FreeLLMAPI audit self-heals (disable-only)
echo '[{"id":1,"platform":"groq","modelId":"openai/gpt-oss-20b","enabled":true,"keyId":1},{"id":2,"platform":"openai","modelId":"gpt-4o","enabled":true,"keyId":2}]' > "$MD_F/models.json"
t "FreeLLMAPI audit service auto-fixes drift and exits 0" bash -c "systemctl start llm-free-audit-freellmapi.service"
t "only the non-free model was disabled, nothing was enabled" bash -c "'$NODE' -e 'const m=JSON.parse(require(\"fs\").readFileSync(\"$MD_F/models.json\",\"utf8\"));process.exit(m[0].enabled===true&&m[1].enabled===false?0:1)'"
t "no kill flag left for FreeLLMAPI"           bash -c "[ ! -e '$LLM_ROOT/freellmapi/state/free-audit.flag' ]"

# ---- monitor with the real systemctl
t "monitor: both guard units active, no CRIT from the guards" bash -c "OUT=\$(bash '$ROOT/vps/monitor.sh' check 2>&1); echo \"\$OUT\" | grep -q 'OK    omniroute.guard.unit' && echo \"\$OUT\" | grep -q 'OK    freellmapi.guard.unit' && ! echo \"\$OUT\" | grep -q 'CRIT  .*guard'"

# ---- clean removal touches only this test's units
t "free-install remove deletes only that gateway's units" bash -c "bash '$ROOT/vps/free-install.sh' --apply remove freellmapi && [ ! -e '$SD/llm-guard-freellmapi.service' ] && [ -e '$SD/llm-guard-omniroute.service' ] && systemctl is-active --quiet llm-guard-omniroute.service"

echo "systemd-guard: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
