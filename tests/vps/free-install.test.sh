#!/usr/bin/env bash
# Unprivileged test of vps/free-install.sh: renders into a throwaway LLM_ROOT / SYSTEMD_DIR, never touches real systemd.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; SKIPPED=0
tu() { if [ "$RENDERED" = 1 ]; then t "$@"; else echo "SKIP $1 (no rendered units)"; SKIPPED=$((SKIPPED+1)); fi; }
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; fi; }
export LLM_ROOT="$T/srv/llm" SYSTEMD_DIR="$T/units" SYSTEMD_RUN_DIR="$T/no-systemd"
mkdir -p "$SYSTEMD_DIR"
FI="bash $ROOT/vps/free-install.sh"

t "dry run writes nothing"              bash -c "$FI units; [ -z \"\$(ls $SYSTEMD_DIR)\" ]"
t "dry run says WOULD WRITE"            bash -c "$FI units 2>&1 | grep -q 'WOULD WRITE'"
t "--apply needs root (non-root refused)" bash -c "[ \"\$(id -u)\" = 0 ] || ! $FI --apply units"
# '--apply' writes root-owned unit files, so it needs root. Re-run ourselves under passwordless sudo when we can (CI runners have it);
# otherwise the checks that need rendered units are reported as SKIP (never as a pass).
if [ "$(id -u)" != 0 ]; then
  if [ -z "${FREE_INSTALL_TEST_REEXEC:-}" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    exec sudo -n env PATH="$PATH" FREE_INSTALL_TEST_REEXEC=1 bash "${BASH_SOURCE[0]}"
  fi
  RENDERED=0
else RENDERED=1; fi
if [ "$RENDERED" = 1 ]; then t "apply renders 6 unit files" bash -c "$FI --apply units && [ \"\$(ls $SYSTEMD_DIR | wc -l)\" = 6 ]"
else echo "SKIP apply renders 6 unit files (needs root or passwordless sudo)"; SKIPPED=$((SKIPPED+1)); fi
U="$SYSTEMD_DIR"
tu "no unreplaced placeholders"          bash -c "! grep -hE '@(LLM_ROOT|USER|PORT|GPORT|GW|EXTRA|AUDITFIX)@' $U/*"
tu "guard is loopback only"              bash -c "grep -q -- '--listen 127.0.0.1:3101' $U/llm-guard-freellmapi.service && grep -q -- '--listen 127.0.0.1:20228' $U/llm-guard-omniroute.service"
tu "guard targets the right upstream"    bash -c "grep -q -- '--upstream http://127.0.0.1:3001' $U/llm-guard-freellmapi.service && grep -q -- '--upstream http://127.0.0.1:20128' $U/llm-guard-omniroute.service"
tu "guards run as the gateway users"     bash -c "grep -q '^User=llmfree' $U/llm-guard-freellmapi.service && grep -q '^User=llmomni' $U/llm-guard-omniroute.service"
tu "kill-file shared by guard and audit" bash -c "grep -q 'state/free-audit.flag' $U/llm-guard-omniroute.service && grep -q -- '--flag-file $LLM_ROOT/omniroute/state/free-audit.flag' $U/llm-free-audit-omniroute.service"
tu "catalog-audited only when asked"     bash -c "! grep -q catalog-audited $U/llm-guard-freellmapi.service"
tu "client keys are opt-in"              bash -c "! grep -q client-keys $U/llm-guard-omniroute.service && rm -f $U/* && $FI --apply units --client-keys >/dev/null 2>&1 && grep -q -- '--client-keys-file $LLM_ROOT/omniroute/config/free-guard.clients --upstream-key-file $LLM_ROOT/omniroute/config/free-guard.upstream.key' $U/llm-guard-omniroute.service"
tu "FreeLLMAPI audit self-heals (disable-only), OmniRoute audit is read-only" bash -c "grep -q -- '--auto-fix' $U/llm-free-audit-freellmapi.service && ! grep -q -- '--auto-fix' $U/llm-free-audit-omniroute.service"
tu "units are sandboxed"                 bash -c "grep -q '^NoNewPrivileges=yes' $U/llm-guard-omniroute.service && grep -q '^ProtectSystem=strict' $U/llm-guard-omniroute.service && grep -q '^CapabilityBoundingSet=\$' $U/llm-guard-omniroute.service"
tu "no secrets in any unit"              bash -c "! grep -hiE 'password|token=|apikey|secret' $U/* | grep -v '^#'"
tu "audit credential file is optional (-) and outside the unit" bash -c "grep -q '^EnvironmentFile=-$LLM_ROOT/freellmapi/config/free-audit.env' $U/llm-free-audit-freellmapi.service"
t "status runs read-only"               bash -c "$FI status"
t "same ports are refused"              bash -c "! GUARD_PORT_FREELLMAPI=4000 GUARD_PORT_OMNIROUTE=4000 $FI units"
t "unknown step is a usage error"       bash -c "! $FI bogus"
# --- safety rails (need rendered units, so only when we are root)
if [ "$RENDERED" = 1 ]; then
  rm -f "$U"/*; bash -c "$FI --apply units --client-keys" >/dev/null 2>&1
  t "re-running units WITHOUT --client-keys over a hardened unit is refused" bash -c "! $FI --apply units 2>&1 && grep -q -- '--client-keys-file' $U/llm-guard-omniroute.service"
  t "...and the hardened unit is left untouched"                            bash -c "grep -q -- '--client-keys-file' $U/llm-guard-freellmapi.service"
  t "--allow-downgrade is the explicit escape hatch"                         bash -c "$FI --apply units --allow-downgrade && ! grep -q -- '--client-keys-file' $U/llm-guard-omniroute.service"
  rm -f "$U"/*; bash -c "$FI --apply units --client-keys" >/dev/null 2>&1
  t "enable (dry-run) warns when the key files are missing"                  bash -c "$FI enable omniroute 2>&1 | grep -q 'would refuse to start'"
  t "enable --apply refuses (no crash-loop) when the key files are missing"  bash -c "! $FI --apply enable omniroute 2>&1 && ! systemctl is-active --quiet llm-guard-omniroute.service 2>/dev/null"
  mkdir -p "$LLM_ROOT/omniroute/config"; printf 'h\n' > "$LLM_ROOT/omniroute/config/free-guard.clients"; printf 'k\n' > "$LLM_ROOT/omniroute/config/free-guard.upstream.key"
  t "enable (dry-run) is quiet once the files exist"                         bash -c "! $FI enable omniroute 2>&1 | grep -q 'would refuse'"
else
  echo "SKIP safety-rail checks (need rendered units)"; SKIPPED=$((SKIPPED+1))
fi
echo "free-install: $PASS passed, $FAIL failed, $SKIPPED skipped"; [ "$FAIL" = 0 ]
