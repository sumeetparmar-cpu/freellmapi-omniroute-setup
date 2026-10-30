#!/usr/bin/env bash
# Unprivileged test of vps/free-install.sh: renders into a throwaway LLM_ROOT / SYSTEMD_DIR, never touches real systemd.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; fi; }
export LLM_ROOT="$T/srv/llm" SYSTEMD_DIR="$T/units" SYSTEMD_RUN_DIR="$T/no-systemd"
mkdir -p "$SYSTEMD_DIR"
FI="bash $ROOT/vps/free-install.sh"

t "dry run writes nothing"              bash -c "$FI units; [ -z \"\$(ls $SYSTEMD_DIR)\" ]"
t "dry run says WOULD WRITE"            bash -c "$FI units 2>&1 | grep -q 'WOULD WRITE'"
t "--apply needs root (non-root refused)" bash -c "[ \"\$(id -u)\" = 0 ] || ! $FI --apply units"
if [ "$(id -u)" = 0 ]; then
  t "apply renders 6 unit files"         bash -c "$FI --apply units && [ \"\$(ls $SYSTEMD_DIR | wc -l)\" = 6 ]"
else
  # render into the sandbox as the current user by bypassing the root check only in this test harness
  t "apply renders 6 unit files"         bash -c "sed 's/is_root || die \"--apply needs root\"; //' $ROOT/vps/free-install.sh > $T/fi.sh && cp -r $ROOT/vps/lib $ROOT/vps/systemd $T/ && cp $T/fi.sh $T/free-install.sh && bash $T/free-install.sh --apply units && [ \"\$(ls $SYSTEMD_DIR | wc -l)\" = 6 ]"
fi
U="$SYSTEMD_DIR"
t "no unreplaced placeholders"          bash -c "! grep -hE '@(LLM_ROOT|USER|PORT|GPORT|GW|EXTRA)@' $U/*"
t "guard is loopback only"              bash -c "grep -q -- '--listen 127.0.0.1:3101' $U/llm-guard-freellmapi.service && grep -q -- '--listen 127.0.0.1:20228' $U/llm-guard-omniroute.service"
t "guard targets the right upstream"    bash -c "grep -q -- '--upstream http://127.0.0.1:3001' $U/llm-guard-freellmapi.service && grep -q -- '--upstream http://127.0.0.1:20128' $U/llm-guard-omniroute.service"
t "guards run as the gateway users"     bash -c "grep -q '^User=llmfree' $U/llm-guard-freellmapi.service && grep -q '^User=llmomni' $U/llm-guard-omniroute.service"
t "kill-file shared by guard and audit" bash -c "grep -q 'state/free-audit.flag' $U/llm-guard-omniroute.service && grep -q -- '--flag-file $LLM_ROOT/omniroute/state/free-audit.flag' $U/llm-free-audit-omniroute.service"
t "catalog-audited only when asked"     bash -c "! grep -q catalog-audited $U/llm-guard-freellmapi.service"
t "client keys are opt-in"              bash -c "! grep -q client-keys $U/llm-guard-omniroute.service && rm -f $U/* && $FI --apply units --client-keys >/dev/null 2>&1 && grep -q -- '--client-keys-file $LLM_ROOT/omniroute/config/free-guard.clients --upstream-key-file $LLM_ROOT/omniroute/config/free-guard.upstream.key' $U/llm-guard-omniroute.service"
t "units are sandboxed"                 bash -c "grep -q '^NoNewPrivileges=yes' $U/llm-guard-omniroute.service && grep -q '^ProtectSystem=strict' $U/llm-guard-omniroute.service && grep -q '^CapabilityBoundingSet=\$' $U/llm-guard-omniroute.service"
t "no secrets in any unit"              bash -c "! grep -hiE 'password|token=|apikey|secret' $U/* | grep -v '^#'"
t "audit credential file is optional (-) and outside the unit" bash -c "grep -q '^EnvironmentFile=-$LLM_ROOT/freellmapi/config/free-audit.env' $U/llm-free-audit-freellmapi.service"
t "status runs read-only"               bash -c "$FI status"
t "same ports are refused"              bash -c "! GUARD_PORT_FREELLMAPI=4000 GUARD_PORT_OMNIROUTE=4000 $FI units"
t "unknown step is a usage error"       bash -c "! $FI bogus"
echo "free-install: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
