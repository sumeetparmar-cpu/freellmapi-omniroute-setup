#!/usr/bin/env bash
# Claude Code on the free-only gateways: runs `claude` against a local free-guard's Anthropic route (/v1/messages), pinned to a
# free model, with its own config directory. Everything stays on 127.0.0.1.
#
#   bash termux/claude-free.sh [--gateway freellmapi|omniroute] [--model ID] [--check] [--] [claude arguments...]
#
#   --gateway  freellmapi (default: guard 127.0.0.1:3101, model gpt-oss-20b) or omniroute (guard 127.0.0.1:20228, model ovhanon/gpt-oss-120b)
#   --model    another model the free-only policy allows on that gateway (the guard refuses anything else before any upstream call)
#   --check    only test that the guard answers and accepts the key (GET /v1/models, no inference), then exit
#   Anything else is passed to claude, e.g.:  bash termux/claude-free.sh -p "explain this repo"
#
# Needs bootstrap.sh done (guards running, client keys in $GW_HOME/config/guard-<gateway>.clientkey) and Claude Code installed.
# Isolation: CLAUDE_CONFIG_DIR=$GW_HOME/claude-code, so your normal ~/.claude (login, settings, history) is not read or changed.
# Your real Anthropic/Bedrock/Vertex credentials are removed from Claude Code's environment so they can never reach the gateway; the
# guard key travels only in the environment (never on a command line) and Anthropic telemetry/update traffic is switched off.
# OVH's keyless route allows 2 requests/minute/model: Claude Code then waits and retries by itself (HTTP 429 + retry-after).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

GW=freellmapi; MODEL=""; CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gateway) GW="${2:-}"; shift ;;
    --model) MODEL="${2:-}"; shift ;;
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    *) break ;;   # first argument that is not ours: it and everything after it go to claude
  esac; shift
done

case "$GW" in
  freellmapi) PORT="${GUARD_PORT_FREELLMAPI:-3101}"; MODEL="${MODEL:-${FL_MODEL:-gpt-oss-20b}}" ;;
  omniroute)  PORT="${GUARD_PORT_OMNIROUTE:-20228}"; MODEL="${MODEL:-${OR_MODEL:-ovhanon/gpt-oss-120b}}" ;;
  *) die "--gateway must be freellmapi or omniroute" ;;
esac
[[ "$MODEL" =~ ^[A-Za-z0-9._:/@-]{1,120}$ ]] || die "--model must be a plain model id"
BASE="http://127.0.0.1:$PORT"

KEYF="$GW_CONFIG_DIR/guard-$GW.clientkey"
[ -s "$KEYF" ] || die "no guard client key at $KEYF; run first: bash $HERE/bootstrap.sh"
case "$(stat -c %a "$KEYF" 2>/dev/null)" in 600|400) ;; *) die "$KEYF must be readable by you only: chmod 600 $KEYF" ;; esac
KEY="$(tr -d '\r\n' < "$KEYF")"
[[ "$KEY" =~ ^[A-Za-z0-9_-]{16,200}$ ]] || die "$KEYF does not hold a guard client key"

# Preflight (no inference): does the guard answer, and does it accept this key? The key goes to curl on stdin, not argv.
code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -K - "$BASE/v1/models" <<< "header = \"Authorization: Bearer $KEY\"" || true)"
case "$code" in
  200) [ "$CHECK" = 1 ] && { ok "$GW guard on $BASE accepts the key; model $MODEL"; exit 0; } ;;
  401) die "the $GW guard on $BASE rejected the key in $KEYF" ;;
  000|"") die "no $GW guard on $BASE; start everything with: bash $HERE/bootstrap.sh" ;;
  *) die "the $GW guard on $BASE answered HTTP $code to GET /v1/models" ;;
esac

command -v claude >/dev/null 2>&1 || die "Claude Code is not installed ('claude' not found); see https://code.claude.com/docs/en/setup"

# Nothing from your own Claude Code setup may leak into this one: credentials, providers, custom headers, config dir.
for v in $(compgen -e); do
  case "$v" in ANTHROPIC_*|CLAUDE_CODE_USE_*|CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_API_KEY_*|AWS_BEARER_TOKEN_BEDROCK|CLAUDE_CONFIG_DIR) unset "$v" ;; esac
done
export CLAUDE_CONFIG_DIR="$GW_HOME/claude-code"
( umask 077; mkdir -p "$CLAUDE_CONFIG_DIR" ); chmod 700 "$CLAUDE_CONFIG_DIR"
export ANTHROPIC_BASE_URL="$BASE" ANTHROPIC_AUTH_TOKEN="$KEY"
# Every model slot (main, opus/sonnet/haiku aliases, background tasks, subagents) points at the one free model.
export ANTHROPIC_MODEL="$MODEL" ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL" ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
unset KEY
info "Claude Code -> $GW guard $BASE, model $MODEL (config: $CLAUDE_CONFIG_DIR)"
exec claude "$@"
