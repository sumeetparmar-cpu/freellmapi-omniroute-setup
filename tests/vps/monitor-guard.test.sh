#!/usr/bin/env bash
# monitor.sh must surface the free-only guard: unit installed + guard answering, kill switch, cooldowns, quota, dead guard.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; PIDS=(); trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; fi; }
mkdir -p "$T/units" "$T/llm"
mock() { # mock PORT JSON
  node -e "require('http').createServer((q,r)=>{r.writeHead(200,{'content-type':'application/json'});r.end(process.argv[2])}).listen(+process.argv[1],'127.0.0.1')" "$1" "$2" & PIDS+=("$!"); sleep 0.6; }
unit() { printf '[Service]\nExecStart=/x --listen 127.0.0.1:%s\n' "$1" > "$T/units/llm-guard-omniroute.service"; }
mon() { env LLM_ROOT="$T/llm" SYSTEMD_DIR="$T/units" SYSTEMD_RUN_DIR=/nonexistent/x bash "$ROOT/vps/monitor.sh" check 2>&1; }

rm -f "$T/units"/*
t "no guard unit installed => no guard lines (monitor unchanged)" bash -c "! env LLM_ROOT='$T/llm' SYSTEMD_DIR='$T/units' SYSTEMD_RUN_DIR=/nonexistent/x bash '$ROOT/vps/monitor.sh' check 2>&1 | grep -q 'guard'"

P1=$((20000 + RANDOM % 5000)); unit "$P1"
mock "$P1" '{"killSwitch":false,"cooldownsSec":{},"requestsToday":{"groq":3}}'
OUT="$(mon)"
t "healthy guard => OK lines"                 bash -c "echo '$OUT' | grep -q 'OK    omniroute.guard.kill-switch'"
t "quota line is reported"                    bash -c "echo '$OUT' | grep -q 'omniroute.guard.quota.groq'"

P2=$((25000 + RANDOM % 5000)); unit "$P2"
mock "$P2" '{"killSwitch":true,"cooldownsSec":{"groq:x":40},"requestsToday":{"groq":1000}}'
OUT="$(mon)"
t "kill switch => CRIT"                       bash -c "echo '$OUT' | grep -q 'CRIT  omniroute.guard.kill-switch'"
t "cooldown => WARN"                          bash -c "echo '$OUT' | grep -q 'WARN  omniroute.guard.cooldowns'"
t "daily cap reached => WARN"                 bash -c "echo '$OUT' | grep -q 'WARN  omniroute.guard.quota.groq'"
t "overall exit status is CRIT (2)"           bash -c "env LLM_ROOT='$T/llm' SYSTEMD_DIR='$T/units' SYSTEMD_RUN_DIR=/nonexistent/x bash '$ROOT/vps/monitor.sh' check >/dev/null 2>&1; rc=\$?; [ \$rc = 2 ]"

unit 1   # nothing listens there
OUT="$(mon)"
t "dead guard => CRIT guard not answering"    bash -c "echo '$OUT' | grep -q 'CRIT  omniroute.guard.guard'"
t "--json output stays valid JSON"            bash -c "env LLM_ROOT='$T/llm' SYSTEMD_DIR='$T/units' SYSTEMD_RUN_DIR=/nonexistent/x bash '$ROOT/vps/monitor.sh' check --json 2>/dev/null | node -e 'JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"))'"
echo "monitor-guard: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
