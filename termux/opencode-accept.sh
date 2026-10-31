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
echo "== 3. independent review (OmniRoute 120B reviews a KNOWN-BAD and a KNOWN-GOOD diff; the right verdicts are REJECT and APPROVE)"
RULE='A test requires add(2,3) to equal 5 and add(-1,1) to equal 0.'
bad_diff='--- a/math.js
+++ b/math.js
-function add(a, b) { return a - b; }
+function add(a, b) { return a * b; }'
good_diff='--- a/math.js
+++ b/math.js
-function add(a, b) { return a - b; }
+function add(a, b) { return a + b; }'
verdict() { grep -m1 -E '^(APPROVE|REJECT)' "$1" | cut -c1-120; }
"$LAUNCH" run --model omniroute/ovhanon/gpt-oss-120b "$RULE Review this diff. The first line of your answer must be exactly APPROVE or REJECT, then one sentence why. DIFF:
$bad_diff" > "$T/rev_bad.out" 2>&1
"$LAUNCH" run --model omniroute/ovhanon/gpt-oss-120b "$RULE Review this diff. The first line of your answer must be exactly APPROVE or REJECT, then one sentence why. DIFF:
$good_diff" > "$T/rev_good.out" 2>&1
echo "   verdict on the BAD diff : $(verdict "$T/rev_bad.out")"; echo "   verdict on the GOOD diff: $(verdict "$T/rev_good.out")"
ck "reviewer REJECTs the known-bad diff"  bash -c "verdict_line=\$(grep -m1 -E '^(APPROVE|REJECT)' '$T/rev_bad.out'); case \"\$verdict_line\" in REJECT*) exit 0;; *) echo \"got: \$verdict_line\"; exit 1;; esac"
ck "reviewer APPROVEs the known-good diff" bash -c "verdict_line=\$(grep -m1 -E '^(APPROVE|REJECT)' '$T/rev_good.out'); case \"\$verdict_line\" in APPROVE*) exit 0;; *) echo \"got: \$verdict_line\"; exit 1;; esac"
echo "== 4. no paid fallback"
"$LAUNCH" run --model anthropic/claude-sonnet-4-5 "say hi" > "$T/paid.out" 2>&1; rc=$?
echo "   anthropic attempt, what OpenCode said:"; tail -n 4 "$T/paid.out" | cut -c1-150 | sed 's/^/   > /'
ck "OpenCode refuses a non-enabled provider (exit $rc, no Anthropic route)" bash -c "[ $rc -ne 0 ]"
paid_code() { # paid_code PORT KEYFILE MODEL -> HTTP status of a chat request for that model, using the key that belongs to THAT guard
  curl -s -m15 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $(head -n1 "$2")" -H 'content-type: application/json' -d "{\"model\":\"$3\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}" "http://127.0.0.1:$1/v1/chat/completions"; }
export -f paid_code
ck "OmniRoute guard refuses openai/gpt-4o with HTTP 403 (its own key)"            bash -c "[ \"\$(paid_code $ORP '$GW_CONFIG_DIR/guard-omniroute.clientkey' openai/gpt-4o)\" = 403 ]"
ck "OmniRoute guard refuses anthropic/claude-sonnet-4-5 with HTTP 403 (its own key)" bash -c "[ \"\$(paid_code $ORP '$GW_CONFIG_DIR/guard-omniroute.clientkey' anthropic/claude-sonnet-4-5)\" = 403 ]"
echo "-- guard counters after:  $(counts | tr '\n' ' ')   (allowed, blocked, requests by provider)"
echo "-- what the guards BLOCKED during this run, by reason (from their own logs; reasons only, no keys):"
for g in freellmapi omniroute; do f="$GW_LOG_DIR/free-guard-$g.log"; [ -f "$f" ] && { printf '   %-10s ' "$g"; grep -o '"type":"[a-z_]*"' "$f" | sort | uniq -c | sort -rn | tr -s ' ' | tr '\n' ';'; echo; }; done
echo "   (local_rate_limit / cooldown = OVH's 2 requests/minute enforced locally: slow, not paid. model_blocked / param_blocked / route_blocked = something tried a name or field outside the free policy.)"
echo "== acceptance: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1
