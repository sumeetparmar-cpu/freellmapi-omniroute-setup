#!/usr/bin/env bash
# A LARGER real coding task for OpenCode on this phone (multi-file project, 4 independent bugs, 11 tests). Judged by `node --test` and git, never by the model.
#   bash opencode-bigtask.sh            run it with the OmniRoute 120B (expect 15-40 minutes: OVH allows 2 requests/minute/model)
#   BIGTASK_SETUP_ONLY=1 bash ...       only build the project and show the failing baseline (no OpenCode, no inference)
# Success = all tests pass AND the test files are untouched AND at least 3 source files changed. Uses a throw-away folder under the toolkit home.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
LAUNCH="$GW_HOME/bin/opencode-free"; MODEL="${BIGTASK_MODEL:-omniroute/ovhanon/gpt-oss-120b}"; LIMIT="${BIGTASK_TIMEOUT:-2700}"
have node && have git || die "node and git are required"
mkdir -p "$GW_HOME/tmp"; P="$(mktemp -d "$GW_HOME/tmp/bigtask.XXXXXX")"; cd "$P" || exit 1
git init -q; git config user.email t@t.invalid; git config user.name t
mkdir -p src test
cat > package.json <<'J'
{ "name": "shop", "version": "1.0.0", "private": true, "scripts": { "test": "node --test" } }
J
cat > src/money.js <<'J'
// Prices come in as decimal currency (19.99) and are stored as integer cents.
function toCents(amount) { return Math.floor(amount * 100); }
function fromCents(cents) { return cents / 100; }
module.exports = { toCents, fromCents };
J
cat > src/cart.js <<'J'
const { toCents } = require('./money');
// items: [{ name, price (decimal), qty }]  -> subtotal in cents
function subtotal(items) { return items.reduce((sum, it) => sum + toCents(it.price), 0); }
function count(items) { return items.reduce((n, it) => n + it.qty, 0); }
module.exports = { subtotal, count };
J
cat > src/discount.js <<'J'
// pct is a whole-number percentage (10 = 10% off). Result in cents, rounded to the nearest cent.
function applyDiscount(cents, pct) { return Math.round(cents - pct); }
module.exports = { applyDiscount };
J
cat > src/format.js <<'J'
// Format integer cents as "$12.34".
function formatMoney(cents) { return '$' + Math.floor(cents / 100) + '.' + (cents % 100); }
module.exports = { formatMoney };
J
cat > src/checkout.js <<'J'
const { subtotal, count } = require('./cart');
const { applyDiscount } = require('./discount');
const { formatMoney } = require('./format');
function receipt(items, pct) {
  const sub = subtotal(items); const total = applyDiscount(sub, pct);
  return { items: count(items), subtotal: formatMoney(sub), total: formatMoney(total) };
}
module.exports = { receipt };
J
cat > test/money.test.js <<'J'
const test = require('node:test'); const assert = require('node:assert');
const { toCents, fromCents } = require('../src/money');
test('19.99 is 1999 cents', () => assert.strictEqual(toCents(19.99), 1999));
test('0.1 + 0.2 style amounts round to the nearest cent', () => assert.strictEqual(toCents(0.29), 29));
test('fromCents', () => assert.strictEqual(fromCents(1999), 19.99));
J
cat > test/cart.test.js <<'J'
const test = require('node:test'); const assert = require('node:assert');
const { subtotal, count } = require('../src/cart');
const items = [{ name: 'a', price: 2.5, qty: 2 }, { name: 'b', price: 1, qty: 3 }];
test('subtotal multiplies by quantity', () => assert.strictEqual(subtotal(items), 800));
test('count adds quantities', () => assert.strictEqual(count(items), 5));
test('empty cart', () => assert.strictEqual(subtotal([]), 0));
J
cat > test/discount.test.js <<'J'
const test = require('node:test'); const assert = require('node:assert');
const { applyDiscount } = require('../src/discount');
test('10% off 1000 cents', () => assert.strictEqual(applyDiscount(1000, 10), 900));
test('0% changes nothing', () => assert.strictEqual(applyDiscount(1234, 0), 1234));
test('rounds to the nearest cent', () => assert.strictEqual(applyDiscount(999, 15), 849));
J
cat > test/checkout.test.js <<'J'
const test = require('node:test'); const assert = require('node:assert');
const { formatMoney } = require('../src/format'); const { receipt } = require('../src/checkout');
test('formatMoney pads cents', () => assert.strictEqual(formatMoney(105), '$1.05'));
test('receipt end to end', () => assert.deepStrictEqual(receipt([{ name: 'a', price: 2.5, qty: 2 }, { name: 'b', price: 1, qty: 3 }], 10), { items: 5, subtotal: '$8.00', total: '$7.20' }));
J
printf '{ "permission": { "edit": "allow", "bash": "allow" } }\n' > opencode.json
git add -A; git commit -q -m baseline
echo "project: $P"
if node --test >/dev/null 2>&1; then die "baseline unexpectedly passes: fixture is wrong"; fi
echo "baseline: $(node --test 2>&1 | grep -E '^(# |ℹ )(pass|fail)' | tr '\n' ' ')   (must fail before the task)"
[ "${BIGTASK_SETUP_ONLY:-0}" = 1 ] && exit 0
[ -x "$LAUNCH" ] || die "OpenCode is not set up: run bash $HERE/opencode-install.sh"
bash "$HERE/gateways.sh" start >/dev/null || die "gateways did not start: bash $HERE/gateways.sh doctor"
echo "(do not type or paste in this window until it finishes; up to $((LIMIT / 60)) minutes)"
TASK='This Node project has failing tests. Run: node --test. Fix every failing test by changing ONLY the files under src/ (never edit anything under test/). Use only relative paths. Re-run node --test after each fix until all tests pass, then say which files you changed.'
start=$(date +%s)
timeout "$LIMIT" "$LAUNCH" run --model "$MODEL" "$TASK" > "$P/../bigtask.out" 2>&1 < /dev/null; rc=$?
echo "opencode exit $rc after $(( $(date +%s) - start )) s (124 = hit the time limit)"
echo "-- last lines the agent said:"; tail -n 8 "$P/../bigtask.out" | cut -c1-160 | sed 's/^/   > /'
echo "-- files changed:"; git status --short | sed 's/^/   /'
pass=0; fail=0
ck() { if "${@:2}" >/dev/null 2>&1; then pass=$((pass + 1)); echo "PASS  $1"; else fail=$((fail + 1)); echo "FAIL  $1"; fi; }
ck "all tests pass (node --test, run by this script)" node --test
ck "test files untouched" bash -c '[ -z "$(git status --porcelain -- test)" ]'
ck "nothing outside src/ was changed (the task said: only src/)" bash -c '[ -z "$(git status --porcelain | grep -v " src/")" ]'
ck "at least 3 source files changed" bash -c '[ "$(git status --porcelain -- src | wc -l)" -ge 3 ]'
echo "-- node --test now: $(node --test 2>&1 | grep -E '^(# |ℹ )(pass|fail)' | tr '\n' ' ')"
bash "$HERE/gateways.sh" usage
echo "== bigtask: $pass passed, $fail failed   (project kept at $P)"
[ "$fail" -eq 0 ]
