#!/usr/bin/env bash
# Regression test for a harness defect: a test script whose EXIT trap ended in `[ "$FAIL" -eq 0 ]` exited 0 even with failures
# (bash ignores the last status of an EXIT trap that does not call exit), so CI reported green for a broken run (seen: passed=8 failed=20).
# Every termux test must exit non-zero when one of its checks fails.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; PASS=0; FAIL=0
ck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# 1. the three tests: break one check on purpose by corrupting what it inspects, and demand a non-zero exit.
# diagnose.test.sh: make diagnose.sh print the secret.
cp -r "$ROOT/termux" "$T/termux"; mkdir -p "$T/tests/termux"; cp "$ROOT"/tests/termux/diagnose.test.sh "$T/tests/termux/"
sed -i 's|^hdr "PHONE"|echo "leak: $(cat "$GW_HOME/config/guard-freellmapi.clientkey" 2>/dev/null)"\nhdr "PHONE"|' "$T/termux/diagnose.sh"
ck "diagnose.test.sh exits non-zero when a check fails"   bash -c "! HOME='$T/hd' bash '$T/tests/termux/diagnose.test.sh'"
# free-guard.test.sh: make the guard script print the gateway key during setup.
cp -r "$ROOT/tools" "$ROOT/config" "$T/" 2>/dev/null; cp "$ROOT"/tests/termux/free-guard.test.sh "$T/tests/termux/"
sed -i 's|^  ok "stored the \$gw gateway key|  echo "$key"; ok "stored the $gw gateway key|' "$T/termux/free-guard.sh"
ck "free-guard.test.sh exits non-zero when a check fails" bash -c "! HOME='$T/hf' bash '$T/tests/termux/free-guard.test.sh'"
# bootstrap.test.sh: its cleanup must exit non-zero when FAIL>0 (cheap structural proof; the real run is the CI job).
ck "bootstrap.test.sh's EXIT handler calls exit on failure" bash -c "grep -q '\[ \"\\\$FAIL\" -eq 0 \] || exit 1' '$ROOT/tests/termux/bootstrap.test.sh'"
echo "harness-exit: passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
