#!/usr/bin/env bash
# Claude-endpoint (/v1/messages) test for FreeLLMAPI and OmniRoute against a local MOCK upstream. Mock-only: no provider key,
# no provider traffic. It proves the gateways' Anthropic translation layer, not real provider behaviour.
#
#   LLM_CE_SANDBOX=1 GW_HOME=<disposable dir> termux/freellmapi.sh install      # once, in a THROWAWAY GW_HOME
#   LLM_CE_SANDBOX=1 GW_HOME=<same dir>       tests/claude-endpoint/run.sh [freellmapi|omniroute|both]
#
# SANDBOX ONLY. It changes the installs it runs against: FreeLLMAPI's env file gets a test admin + mock provider (the file is
# restored on exit); OmniRoute's database gets a test provider node/connection, two Claude-name aliases and client keys (these
# cannot be undone, so never point GW_HOME at an install you use). Refuses to run without LLM_CE_SANDBOX=1.
# Needs Node 22.22.2+ (OmniRoute) on PATH, installs already present under GW_HOME, and free ports.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/claude-endpoint"
[ "${LLM_CE_SANDBOX:-}" = 1 ] || { echo "refusing: set LLM_CE_SANDBOX=1 and point GW_HOME at a throwaway install (this modifies it)"; exit 2; }
[ -n "${GW_HOME:-}" ] || { echo "refusing: GW_HOME must be set explicitly (no default, to avoid touching a real install)"; exit 2; }
WHICH="${1:-both}"; case "$WHICH" in freellmapi|omniroute|both) ;; *) echo "usage: $0 [freellmapi|omniroute|both]"; exit 2;; esac
export GW_HOME
TMP="$(mktemp -d)"; MOCK_PORT="${CE_MOCK_PORT:-18703}"; FL_PORT="${FREELLMAPI_PORT:-3001}"; OM_PORT="${OMNIROUTE_PORT:-20128}"
export FREELLMAPI_PORT="$FL_PORT" OMNIROUTE_PORT="$OM_PORT"
FLENV="$GW_HOME/config/freellmapi.env"; OMENV="$GW_HOME/config/omniroute.env"
MOCK_PID=""; FL_BACKUP=""; RC=0

up() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
cleanup() {
  [ -x "$ROOT/termux/freellmapi.sh" ] && "$ROOT/termux/freellmapi.sh" stop >/dev/null 2>&1
  [ -x "$ROOT/termux/omniroute.sh" ] && "$ROOT/termux/omniroute.sh" stop >/dev/null 2>&1
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  [ -n "$FL_BACKUP" ] && [ -f "$FL_BACKUP" ] && cp -p "$FL_BACKUP" "$FLENV"
  rm -rf -- "$TMP"
}
trap cleanup EXIT
for p in $MOCK_PORT $([ "$WHICH" != omniroute ] && echo "$FL_PORT") $([ "$WHICH" != freellmapi ] && echo "$OM_PORT"); do
  up "$p" && { echo "refusing: port $p is already in use"; exit 2; }
done
jf() { node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{process.stdout.write(String(JSON.parse(s)[process.argv[1]]||""))}catch{}})' "$1"; }
start_mock() { : > "$TMP/mock.log"; node "$HERE/mock-openai-tools.mjs" "$MOCK_PORT" "$TMP/mock.log" >/dev/null 2>&1 & MOCK_PID=$!; for _ in $(seq 30); do up "$MOCK_PORT" && return 0; sleep 0.2; done; echo "mock did not start"; return 1; }
report_mock() { echo "  upstream (mock) received $(wc -l < "$TMP/mock.log") requests"; }

run_freellmapi() {
  echo "== FreeLLMAPI (mock upstream; Claude names are mapped to 'auto' by the gateway itself)"
  [ -d "$GW_HOME/freellmapi/server/dist" ] || { echo "FAIL - FreeLLMAPI not installed under $GW_HOME"; return 1; }
  FL_BACKUP="$TMP/freellmapi.env.bak"; cp -p "$FLENV" "$FL_BACKUP"
  sed -i '/^FREEAPI_CONFIG_JSON=/d' "$FLENV"
  # supportsTools:true is required or the router skips the model for tool requests ("model lacks tool-calling")
  printf 'FREEAPI_CONFIG_JSON={"admin":{"email":"ce@example.test","password":"ce-test-password-1"},"customProviders":[{"baseUrl":"http://127.0.0.1:%s/v1","label":"MockLocal","apiKey":"mock-key","models":[{"model":"mock-model","displayName":"Mock","supportsTools":true}]}]}\n' "$MOCK_PORT" >> "$FLENV"
  start_mock || return 1
  "$ROOT/termux/freellmapi.sh" start >/dev/null 2>&1 || { echo "FAIL - start"; return 1; }
  local tok key
  tok="$(curl -s -X POST "localhost:$FL_PORT/api/auth/login" -H 'content-type: application/json' -d '{"email":"ce@example.test","password":"ce-test-password-1"}' | jf token)"
  key="$(curl -s "localhost:$FL_PORT/api/settings/api-key" -H "Authorization: Bearer $tok" | jf apiKey)"
  [ -n "$key" ] || { echo "FAIL - could not obtain the unified key (an earlier admin account may already exist in this sandbox)"; return 1; }
  GWKEY="$key" node "$HERE/anthropic-check.mjs" "http://127.0.0.1:$FL_PORT" mock-model /v1 || RC=1
  report_mock
  "$ROOT/termux/freellmapi.sh" stop >/dev/null 2>&1; kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""; cp -p "$FL_BACKUP" "$FLENV"
}

run_omniroute() {
  echo "== OmniRoute (mock upstream; Claude names need explicit aliases)"
  [ -f "$GW_HOME/omniroute/node_modules/omniroute/bin/omniroute.mjs" ] || { echo "FAIL - OmniRoute not installed under $GW_HOME"; return 1; }
  start_mock || return 1
  "$ROOT/termux/omniroute.sh" start >/dev/null 2>&1 || { echo "FAIL - start"; return 1; }
  local B="http://127.0.0.1:$OM_PORT" CJ="$TMP/om.cj" pw node_id conn_id key
  pw="$(grep '^INITIAL_PASSWORD=' "$OMENV" | cut -d= -f2-)"
  [ "$(curl -s -c "$CJ" -o /dev/null -w '%{http_code}' -X POST "$B/api/auth/login" -H 'content-type: application/json' -d "{\"password\":\"$pw\"}")" = 200 ] || { echo "FAIL - dashboard login"; return 1; }
  node_id="$(curl -s -b "$CJ" -X POST "$B/api/provider-nodes" -H 'content-type: application/json' -d "{\"name\":\"MockLocal\",\"prefix\":\"mock\",\"apiType\":\"chat\",\"baseUrl\":\"http://127.0.0.1:$MOCK_PORT/v1\",\"type\":\"openai-compatible\"}" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{process.stdout.write(JSON.parse(s).node.id)}catch{}})')"
  [ -n "$node_id" ] || { echo "FAIL - provider node (loopback base URL rejected?)"; return 1; }
  conn_id="$(curl -s -b "$CJ" -X POST "$B/api/providers" -H 'content-type: application/json' -d "{\"provider\":\"$node_id\",\"name\":\"mock-conn\",\"apiKey\":\"mock-key\"}" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{process.stdout.write(JSON.parse(s).connection.id)}catch{}})')"
  [ -n "$conn_id" ] || { echo "FAIL - provider connection"; return 1; }
  curl -s -b "$CJ" -o /dev/null -X PUT "$B/api/providers/$conn_id" -H 'content-type: application/json' -d '{"isActive":true}'
  for a in claude-sonnet-4-5 claude-3-5-haiku-20241022; do
    curl -s -b "$CJ" -o /dev/null -X PUT "$B/api/models/alias" -H 'content-type: application/json' -d "{\"model\":\"mock/mock-model\",\"alias\":\"$a\"}"
  done
  key="$(curl -s -b "$CJ" -X POST "$B/api/keys" -H 'content-type: application/json' -d '{"name":"claude-endpoint-test"}' | jf key)"
  [ -n "$key" ] || { echo "FAIL - client key"; return 1; }
  GWKEY="$key" node "$HERE/anthropic-check.mjs" "$B" mock/mock-model /v1 || RC=1
  # a Claude name with NO alias must be refused rather than silently routed somewhere
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/messages" -H "x-api-key: $key" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-opus-4-1","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}')"
  if [ "$code" = 400 ]; then echo "PASS - unaliased Claude name is refused (HTTP 400), not guessed"; else echo "FAIL - unaliased Claude name returned HTTP $code"; RC=1; fi
  report_mock
  "$ROOT/termux/omniroute.sh" stop >/dev/null 2>&1; kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
}

command -v node >/dev/null || { echo "node not found"; exit 2; }
[ "$WHICH" != omniroute ] && { run_freellmapi || RC=1; }
[ "$WHICH" != freellmapi ] && { run_omniroute || RC=1; }
[ "$RC" = 0 ] && echo "RESULT: PASS (mock upstream only)" || echo "RESULT: FAIL"
exit "$RC"
