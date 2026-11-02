#!/usr/bin/env bash
# Architecture C (OmniRoute only): --only omniroute / GATEWAYS= in deploy.conf. FreeLLMAPI must never be created, installed, enabled,
# verified, monitored or port-checked, and the default (both gateways) must be unchanged. Read-only / dry-run only; no system changes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; sed 's/^/       /' "$T/out" | tail -6; fi; }
printf 'ID=ubuntu\nVERSION_ID="26.04"\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' > "$T/os26"
printf 'MemTotal: 8388608 kB\nMemAvailable: 6291456 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$T/mem"
printf '127.0.0.1\t3001\tdocker-proxy\n0.0.0.0\t80\tcaddy\n' > "$T/listen"     # port 3001 taken, like the real VPS
printf '/dev/vda1 / ext4 rw,relatime 0 0\n' > "$T/mounts"; printf 'max\n' > "$T/cg"; printf '0\n' > "$T/oc"; printf '32768\t60999\n' > "$T/range"; printf '\n' > "$T/resv"
mkdir -p "$T/fake-sd" "$T/units"
pf() { env OS_RELEASE="$T/os26" MEMINFO_FILE="$T/mem" SYSTEMD_RUN_DIR="$T/fake-sd" SYSTEMD_DIR="$T/units" LISTENERS_FILE="$T/listen" MOUNTS_FILE="$T/mounts" \
  CGROUP_MEM_FILE="$T/cg" OVERCOMMIT_FILE="$T/oc" PORT_RANGE_FILE="$T/range" RESERVED_PORTS_FILE="$T/resv" LLM_ROOT="$T/nonexistent/llm" \
  LLM_USER_FREELLMAPI=llmxfree LLM_USER_OMNIROUTE=llmxomni "$@"; }

echo "# preflight"
pf "$ROOT/vps/preflight.sh" --offline > "$T/both.txt" 2>&1
pf "$ROOT/vps/preflight.sh" --offline --only omniroute > "$T/only.txt" 2>&1
t "default (both gateways): the taken port 3001 is a BLOCK with a proposal"  grep -q "^\[BLOCK\] port 3001 for freellmapi is already in use" "$T/both.txt"
t "--only omniroute: the taken port 3001 is NOT checked (no BLOCK)"          bash -c '! grep -q "^\[BLOCK\] port 3001" "$0"' "$T/only.txt"
t "--only omniroute: says freellmapi is not selected"                        grep -q "freellmapi not selected" "$T/only.txt"
t "--only omniroute: omniroute port 20128 and its guard 20228 are checked"   bash -c 'grep -q "port 20128 free for omniroute" "$0" && grep -q "port 20228 free for the optional omniroute guard" "$0"' "$T/only.txt"
t "--only omniroute: no freellmapi guard port line, no FreeLLMAPI proposal"  bash -c '! grep -q "optional freellmapi guard" "$0" && ! grep -q PROPOSED_PORT_FREELLMAPI "$0"' "$T/only.txt"
t "--only omniroute: proposes the omniroute port and records the selection"  bash -c 'grep -q "PROPOSED_PORT_OMNIROUTE=20128" "$0" && grep -q "GATEWAYS_SELECTED=omniroute" "$0"' "$T/only.txt"
t "--only omniroute: no block overall"                                       grep -q "RESULT: PASS" "$T/only.txt"
printf '127.0.0.1\t20128\tx\n' > "$T/listen2"
pf LISTENERS_FILE="$T/listen2" "$ROOT/vps/preflight.sh" --offline --only omniroute > "$T/neg.txt" 2>&1
t "negative control: an occupied omniroute port still BLOCKs under --only"   grep -q "^\[BLOCK\] port 20128 for omniroute" "$T/neg.txt"
t "bad --only value is refused"                                              bash -c '! pf_run=1 "$0/vps/preflight.sh" --offline --only nonsense' "$ROOT"

echo "# deploy.sh (dry run: prints actions, changes nothing)"
D() { pf LLM_ROOT="$T/llm" "$ROOT/vps/deploy.sh" "$@" 2>&1; }
t "dry-run config --only omniroute plans only omniroute's gateways.env (no freellmapi path)" bash -c 'out=$(env LLM_ROOT="$1/llm" SYSTEMD_DIR="$1/units" SYSTEMD_RUN_DIR="$1/fake-sd" LISTENERS_FILE="$1/listen" "$0/vps/deploy.sh" --only omniroute --omniroute-port 20128 config 2>&1); echo "$out" | grep -q "omniroute/config/gateways.env" && echo "$out" | grep -q "deploy.conf" && ! echo "$out" | grep -q "freellmapi"' "$ROOT" "$T"
t "dry-run config with 3001 taken: both => refused, --only omniroute => fine"  bash -c 'e() { env LLM_ROOT="$1/llm" SYSTEMD_DIR="$1/units" SYSTEMD_RUN_DIR="$1/fake-sd" LISTENERS_FILE="$1/listen" "$0/vps/deploy.sh" "${@:2}" 2>&1; }; ! e "$@" config >/dev/null 2>&1 && e "$@" --only omniroute config >/dev/null 2>&1' "$ROOT" "$T"
t "install freellmapi is refused when the deployment is omniroute-only"        bash -c 'mkdir -p "$1/llm"; printf "GATEWAYS=omniroute\nPORT_OMNIROUTE=20128\n" > "$1/llm/deploy.conf"; ! env LLM_ROOT="$1/llm" "$0/vps/deploy.sh" install freellmapi 2>&1 | grep -q "x" ; env LLM_ROOT="$1/llm" "$0/vps/deploy.sh" install freellmapi 2>&1 | grep -q "not part of this deployment"' "$ROOT" "$T"
t "units dry-run renders only llm-omniroute.service"                           bash -c 'out=$(env LLM_ROOT="$1/llm" SYSTEMD_DIR="$1/units" SYSTEMD_RUN_DIR="$1/fake-sd" "$0/vps/deploy.sh" units 2>&1); echo "$out" | grep -q "omniroute" && ! echo "$out" | grep -q "llm-freellmapi.service"' "$ROOT" "$T"

echo "# selected_gateways()"
sg() { env LLM_ROOT="$T/llm" "$@" bash -c '. "$0/vps/lib/vps-common.sh"; selected_gateways' "$ROOT"; }
t "no deploy.conf, no env => both"                          bash -c '[ "$(env -u LLM_GATEWAYS LLM_ROOT="$1/none" bash -c ". \"$0/vps/lib/vps-common.sh\"; selected_gateways" "$0" "$1")" = "freellmapi omniroute" ]' "$ROOT" "$T"
t "GATEWAYS=omniroute in deploy.conf => omniroute"          bash -c '[ "$(env -u LLM_GATEWAYS LLM_ROOT="$1/llm" bash -c ". \"$0/vps/lib/vps-common.sh\"; selected_gateways" "$0" "$1")" = omniroute ]' "$ROOT" "$T"
t "GATEWAYS=both in deploy.conf => both"                    bash -c 'printf "GATEWAYS=both\n" > "$1/llm/deploy.conf"; [ "$(env -u LLM_GATEWAYS LLM_ROOT="$1/llm" bash -c ". \"$0/vps/lib/vps-common.sh\"; selected_gateways" "$0" "$1")" = "freellmapi omniroute" ]' "$ROOT" "$T"
t "env LLM_GATEWAYS wins over deploy.conf"                  bash -c '[ "$(env LLM_GATEWAYS=freellmapi LLM_ROOT="$1/llm" bash -c ". \"$0/vps/lib/vps-common.sh\"; selected_gateways" "$0" "$1")" = freellmapi ]' "$ROOT" "$T"
echo "only-omniroute: passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1
