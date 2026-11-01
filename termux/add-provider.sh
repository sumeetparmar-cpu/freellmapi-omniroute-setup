#!/usr/bin/env bash
# Add your Groq or Gemini FREE-tier API key to the two gateways, behind the free-only guards. Safe to re-run (never duplicates).
#
#   bash add-provider.sh groq   [--key-file F]
#   bash add-provider.sh gemini [--key-file F] [--accept-training]
#
# The key is typed at a hidden prompt (or read from --key-file); it is never printed, never put on a command line, never written to a log or
# to a file by this script. Only the two gateways store it (encrypted by them). Nothing is verified as "free" by this script alone:
# the guard allowlist, per-provider limits and the audit watcher keep enforcing it afterwards.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
PROV="${1:-}"; [ $# -gt 0 ] && shift
KEYFILE=""; ACCEPT=0
while [ $# -gt 0 ]; do case "$1" in --key-file) KEYFILE="${2:-}"; shift;; --accept-training) ACCEPT=1;; *) die "unknown option $1";; esac; shift; done
case "$PROV" in
  groq)   LABEL=Groq;   MODEL="${GROQ_MODEL:-groq/openai/gpt-oss-120b}"; SHAPE='^gsk_[A-Za-z0-9]{20,}$' ;;
  gemini) LABEL=Gemini; MODEL="${GEMINI_MODEL:-gemini/gemini-2.5-flash}"; SHAPE='^AIza[A-Za-z0-9_-]{20,}$' ;;
  *) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
have node || die "node not found"
GUARD_PORT_OMNIROUTE="${GUARD_PORT_OMNIROUTE:-20228}"; OR_CKEY="$GW_CONFIG_DIR/guard-omniroute.clientkey"
[ -s "$OR_CKEY" ] || die "guard keys missing: run termux/bootstrap.sh first"

echo "== Adding a $LABEL FREE-tier key (it stays on this phone, inside the gateways) =="
if [ "$PROV" = groq ]; then
  echo "Before you continue: the Groq account must be on the FREE plan. Never upgrade to Developer (that is the paid, card-backed plan)."
else
  echo "Before you continue: use a Gemini API key from a Google AI Studio project with NO billing account linked."
  echo "WARNING: on the Gemini free tier Google may use your prompts AND responses to improve its products, and humans may review them."
  echo "         Do not send secrets, customer data or private code through Gemini. (Groq's default is no retention.)"
  if [ "$ACCEPT" -ne 1 ]; then
    [ -t 0 ] || die "Gemini needs your acknowledgement of the data-use warning: run interactively, or pass --accept-training"
    printf 'Type  I ACCEPT  to continue: '; read -r ans; [ "$ans" = "I ACCEPT" ] || die "not acknowledged; nothing was changed"
  fi
fi

if [ -n "$KEYFILE" ]; then [ -r "$KEYFILE" ] || die "cannot read $KEYFILE"; KEY="$(head -n1 "$KEYFILE" | tr -d '[:space:]')"
else
  [ -t 0 ] || die "no terminal for the hidden prompt: use --key-file FILE"
  printf 'Paste your %s API key (nothing is shown) and press Enter: ' "$LABEL"; read -rs KEY; echo
  KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
fi
printf '%s' "$KEY" | grep -Eq "$SHAPE" || { unset KEY; die "that does not look like a $LABEL API key (wrong prefix or length). Nothing was changed."; }

if ! { port_in_use "${FREELLMAPI_PORT:-3001}" && port_in_use "${OMNIROUTE_PORT:-20128}" && port_in_use "${GUARD_PORT_OMNIROUTE}"; }; then info "starting the gateways first"; bash "$HERE/gateways.sh" start || { unset KEY; die "gateways did not start: bash $HERE/gateways.sh doctor"; }; fi

info "[1/4] storing the key in both gateways"
PROVIDER_KEY="$KEY" node "$HERE/lib/add-provider.mjs" --provider "$PROV" --gateway both \
  --fl-base "http://127.0.0.1:${FREELLMAPI_PORT:-3001}" --or-base "http://127.0.0.1:${OMNIROUTE_PORT:-20128}" \
  --cred-file "$GW_CONFIG_DIR/freellmapi.admin" --env-file "$GW_CONFIG_DIR/omniroute.env"
rc=$?; unset KEY
[ "$rc" -eq 0 ] || die "could not add the key (see above). Nothing else was changed."

info "[2/4] free-only audit (prunes anything outside the allowlist, then checks)"
(
  # shellcheck disable=SC1091
  . "$GW_CONFIG_DIR/freellmapi.admin" 2>/dev/null
  export FREELLMAPI_ADMIN_EMAIL FREELLMAPI_ADMIN_PASSWORD
  OMNIROUTE_ADMIN_PASSWORD="$(env_get "$GW_CONFIG_DIR/omniroute.env" INITIAL_PASSWORD 2>/dev/null)"; export OMNIROUTE_ADMIN_PASSWORD
  node "$HERE/../tools/free-policy.mjs" freellmapi audit --auto-fix --base-url "http://127.0.0.1:${FREELLMAPI_PORT:-3001}" --flag-file "$GW_STATE_DIR/free-audit-freellmapi.flag" >/dev/null 2>&1
  node "$HERE/../tools/free-policy.mjs" omniroute audit --base-url "http://127.0.0.1:${OMNIROUTE_PORT:-20128}" --flag-file "$GW_STATE_DIR/free-audit-omniroute.flag" 2>&1 | tail -n 4
) || warn "audit reported a problem: bash $HERE/gateways.sh doctor"
[ -e "$GW_STATE_DIR/free-audit-omniroute.flag" ] || [ -e "$GW_STATE_DIR/free-audit-freellmapi.flag" ] && warn "a free-only kill switch is engaged: inference is refused until it is fixed (bash $HERE/gateways.sh doctor)"

info "[3/4] one real request through the guard ($MODEL)"
mkdir -p "$GW_STATE_DIR"; printf 'added %s\n' "$(timestamp)" > "$GW_STATE_DIR/providers.$PROV"
vr=0; node "$HERE/lib/infer.mjs" --name "OmniRoute/$LABEL" --base "http://127.0.0.1:$GUARD_PORT_OMNIROUTE/v1" --key-file "$OR_CKEY" --model "$MODEL" --tries 2 --provider-label "$LABEL free tier" || vr=1

info "[4/4] OpenCode config"
if [ -f "$GW_HOME/opencode/runner" ]; then bash "$HERE/opencode-setup.sh" config && bash "$HERE/opencode-setup.sh" check; else info "OpenCode not installed yet; the models are added when you install it"; fi
bash "$HERE/gateways.sh" usage
if [ "$vr" -eq 0 ]; then ok "$LABEL works behind the guard. Model name for apps: $MODEL"
else warn "the real request failed. Common causes: key typed wrongly, key from a billed project, or $LABEL rate limit. The key was stored; re-test with:  bash $HERE/gateways.sh usage  and  node $HERE/lib/infer.mjs"; exit 1; fi
