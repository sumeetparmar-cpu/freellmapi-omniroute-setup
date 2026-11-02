#!/usr/bin/env bash
# READ-ONLY trace of a failed OpenCode request through the FreeLLMAPI chain: OpenCode log -> guard :3101 -> gateway :3001 -> OVH.
# Changes nothing, sends no request, prints no secret (keys are redacted from every line).
#   bash opencode-trace.sh [ERROR_REF e.g. err_c6d300ee]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
REF="${1:-}"
red() { sed -E 's/(fg_|gsk_|AIza|sk-)[A-Za-z0-9_-]{8,}/[redacted]/g; s/(Bearer|authorization:?) +[^ "]+/\1 [redacted]/Ig' | cut -c1-300; }
CFG="${OPENCODE_CFG_DIR:-$HOME/.config/opencode}/opencode.json"
echo "== 1. configured model ids (case matters: the provider id is 'freellmapi', all lowercase)"
node -e 'const c=require(process.argv[1]);console.log("model        :",c.model);console.log("small_model  :",c.small_model);for(const [p,v] of Object.entries(c.provider))console.log("provider",p,"->",v.options.baseURL,"models:",Object.keys(v.models).join(","))' "$CFG" 2>&1 | red
echo "== 2. OpenCode's own log (lines around the error; newest log file)"
LOGDIR="$HOME/.local/share/opencode/log"
if [ -n "$REF" ]; then
  echo "-- searching ALL OpenCode logs, storage and the config dir for $REF (the ref is made by OpenCode: neither the guard nor FreeLLMAPI writes err_ references)"
  hits="$(grep -rl "$REF" "$HOME/.local/share/opencode" "$HOME/.config/opencode" 2>/dev/null | head -5)"
  if [ -n "$hits" ]; then for f in $hits; do echo "found in: $f"; grep -n -B4 -A8 "$REF" "$f" | red | head -40; done; else echo "NOT FOUND anywhere under ~/.local/share/opencode or ~/.config/opencode"; fi
fi
echo "-- all ERROR lines that involve freellmapi (provider 20B), newest 8, with timestamps"
grep -h "level=ERROR" "$LOGDIR"/*.log 2>/dev/null | grep -i "freellmapi" | tail -8 | red
echo "-- count of ERROR lines by provider in the newest log"
L="$(ls -t "$LOGDIR"/*.log 2>/dev/null | head -1)"; [ -n "$L" ] && grep "level=ERROR" "$L" | grep -o 'providerID=[a-z]*' | sort | uniq -c
echo "== 3. FreeLLMAPI guard :3101 (last 12 events; ev=pass|deny|bad_*)"
tail -n 12 "$GW_LOG_DIR/free-guard-freellmapi.log" 2>/dev/null | red
echo "== 4. FreeLLMAPI gateway :3001 (last 15 proxy lines: which route, status, error)"
grep -E '\[Proxy\]|\[FallbackLoop\]' "$GW_LOG_DIR/freellmapi.log" 2>/dev/null | tail -n 15 | red
echo "== 5. guard status today"
bash "$HERE/gateways.sh" usage 2>&1 | red
