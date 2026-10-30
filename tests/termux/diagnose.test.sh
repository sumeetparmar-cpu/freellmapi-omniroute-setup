#!/usr/bin/env bash
# termux/diagnose.sh must be read-only and secret-free. Builds a fake "phone" (a partial install with secret-looking files) and checks both.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; PASS=0; FAIL=0; trap 'rm -rf "$TMP"; echo "diagnose: passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]' EXIT
ck() { local n="$1"; shift; if "$@" >"$TMP/out" 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; sed 's/^/       /' "$TMP/out" | tail -6; fi; }
export HOME="$TMP/home"; export GW_HOME="$HOME/llm-gateways"; mkdir -p "$GW_HOME"/{config,state,freellmapi/server/dist,freellmapi-data}
SECRET="sup3rS3cretValue-$(date +%s%N | sha256sum | cut -c1-16)"
printf 'ENCRYPTION_KEY=%s\nPORT=3001\n' "$SECRET" > "$GW_HOME/config/freellmapi.env"; chmod 600 "$GW_HOME/config/freellmapi.env"
printf '%s\n' "$SECRET" > "$GW_HOME/config/guard-freellmapi.clientkey"; chmod 600 "$GW_HOME/config/guard-freellmapi.clientkey"
printf '{"name":"freellmapi","version":"0.16.12"}\n' > "$GW_HOME/freellmapi/package.json"; echo db > "$GW_HOME/freellmapi-data/freeapi.db"
before="$(cd "$HOME" && find . -printf '%p %s %T@ %m\n' | sort | sha256sum)"
bash "$ROOT/termux/diagnose.sh" > "$TMP/report" 2>&1; rc=$?
after="$(cd "$HOME" && find . -printf '%p %s %T@ %m\n' | sort | sha256sum)"
ck "exits 0"                                              test "$rc" = 0
ck "changes nothing (files, sizes, mtimes, modes)"        test "$before" = "$after"
ck "no secret value in the report"                        bash -c "! grep -qF -- '$SECRET' '$TMP/report'"
ck "setting NAMES are shown, not values"                  bash -c "grep -q 'ENCRYPTION_KEY' '$TMP/report'"
ck "detects the PARTIAL FreeLLMAPI (no node_modules) and says repair, not reinstall" bash -c "grep -q 'PARTIAL' '$TMP/report' && grep -q 'keeps source and data' '$TMP/report'"
ck "reports OmniRoute as not found"                       bash -c "grep -q 'OmniRoute: not found' '$TMP/report'"
ck "lists credential file names with modes"               bash -c "grep -q 'guard-freellmapi.clientkey .*mode 600' '$TMP/report'"
