#!/usr/bin/env bash
# ACCEPTANCE RUN for OpenCode on THIS phone, through the two free-only guards. UNTESTED until you run it (OpenCode is not installed in the cloud).
# Needs: `termux/opencode-install.sh` done (installs OpenCode and writes the config + launcher), gateways running. Uses a throw-away project; touches nothing else.
# Expect it to be SLOW: OVH's anonymous tier allows 2 requests/minute/model and an agent makes several requests per task (budget ~10-20 minutes).
#   ./opencode-accept.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
LAUNCH="$GW_HOME/bin/opencode-free"
FLP="${GUARD_PORT_FREELLMAPI:-3101}"; ORP="${GUARD_PORT_OMNIROUTE:-20228}"
PASS=0; FAIL=0
ck() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then PASS=$((PASS + 1)); echo "PASS  $n"; else FAIL=$((FAIL + 1)); echo "FAIL  $n"; sed 's/^/        /' "$T/out" | tail -8; fi; }
[ -f "$GW_HOME/opencode/runner" ] || die "OpenCode is not installed yet: run  bash $HERE/opencode-install.sh"
[ -x "$LAUNCH" ] || die "run first: bash $HERE/opencode-setup.sh config"
bash "$HERE/opencode-setup.sh" check || die "config check failed"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
P="$T/proj"; mkdir -p "$P"; cd "$P" || exit 1
git init -q 2>/dev/null; git config user.email t@t.invalid; git config user.name t
cat > math.js <<'JS'
function add(a, b) { return a - b; }   // BUG: should add
module.exports = { add };
JS
cat > math.test.js <<'JS'
const test = require('node:test'); const assert = require('node:assert');
const { add } = require('./math');
test('add', () => { assert.strictEqual(add(2, 3), 5); assert.strictEqual(add(-1, 1), 0); });
JS
printf '{ "name": "accept", "private": true }\n' > package.json
# project-level override applies ONLY inside this throw-away directory so the run can be non-interactive
printf '{ "permission": { "edit": "allow", "bash": "allow" } }\n' > opencode.json
git add -A; git commit -qm base
show() { # show NAME OUTFILE : what the model really did, so a failing check can be understood
  echo "   --- $1: diff of math.js ---"; git diff -- math.js | sed 's/^/   | /' | head -n 14
  echo "   --- $1: last lines the agent said ---"; tail -n 8 "$2" | cut -c1-160 | sed 's/^/   > /'
}
counts() { for p in "$FLP" "$ORP"; do curl -s -m5 "http://127.0.0.1:$p/__guard/status" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const d=JSON.parse(s);console.log(JSON.stringify([d.passed,d.blocked,d.requestsToday]))})'; done; }
TASK='math.js has a bug: add() subtracts. Read math.js, fix the bug, then run: node --test   Report whether the tests pass.'

ck "baseline: the test really fails before any fix" bash -c '! node --test'
echo "-- guard counters before: $(counts | tr '\n' ' ')"
echo "== 1. coding task through FreeLLMAPI (freellmapi/gpt-oss-20b)"
"$LAUNCH" run --model freellmapi/gpt-oss-20b "$TASK" > "$T/fl.out" 2>&1; echo "   opencode exit $?"; show FreeLLMAPI "$T/fl.out"
ck "FreeLLMAPI: file edited and tests pass (checked by node --test, not by the model)" node --test
git diff > "$T/fl.diff"; ck "FreeLLMAPI: the diff really changed math.js" test -s "$T/fl.diff"
git checkout -q -- . ; echo "== 2. same task through OmniRoute (omniroute/ovhanon/gpt-oss-120b)"
"$LAUNCH" run --model omniroute/ovhanon/gpt-oss-120b "$TASK" > "$T/or.out" 2>&1; echo "   opencode exit $?"; show OmniRoute "$T/or.out"
ck "OmniRoute: file edited and tests pass" node --test
git diff > "$T/or.diff"; ck "OmniRoute: the diff really changed math.js" test -s "$T/or.diff"
echo "== 3. independent review: OmniRoute reviews the FreeLLMAPI diff"
"$LAUNCH" run --model omniroute/ovhanon/gpt-oss-120b "Review this diff. First line must be exactly APPROVE or REJECT, then one sentence why. DIFF: $(cat "$T/fl.diff")" > "$T/review.out" 2>&1
ck "review answered with APPROVE/REJECT" grep -qE '^(APPROVE|REJECT)' "$T/review.out"; head -n 3 "$T/review.out" | sed 's/^/   review> /'
echo "== 4. no paid fallback"
"$LAUNCH" run --model anthropic/claude-sonnet-4-5 "say hi" > "$T/paid.out" 2>&1; rc=$?
ck "OpenCode refuses a non-enabled provider (exit $rc, no Anthropic route)" bash -c "[ $rc -ne 0 ] || grep -qiE 'not found|unknown|disabled|not enabled|no provider' '$T/paid.out'"
ck "guard refuses a paid model by name (HTTP 403)" bash -c "[ \"\$(curl -s -m10 -o /dev/null -w '%{http_code}' -X POST -H \"Authorization: Bearer \$(head -n1 '$GW_CONFIG_DIR/guard-freellmapi.clientkey')\" -H 'content-type: application/json' -d '{\"model\":\"openai/gpt-4o\",\"messages\":[]}' http://127.0.0.1:$ORP/v1/chat/completions)\" != 200 ]"
echo "-- guard counters after:  $(counts | tr '\n' ' ')   (allowed, blocked, requests by provider)"
echo "== acceptance: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1
