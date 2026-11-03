#!/usr/bin/env bash
# termux/claude-free.sh against a stand-in guard and a stand-in `claude` that records what it was started with. No network, no real keys.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; PASS=0; FAIL=0; PIDS=()
cleanup() {
  local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"
  echo "claude-free: passed=$PASS failed=$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1   # an EXIT trap must call exit: bash ignores its last status otherwise
}
trap cleanup EXIT
ck() { local n="$1"; shift; if "$@" >"$TMP/out" 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; sed 's/^/       /' "$TMP/out" | tail -8; fi; }
free_port() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }
GF=$(free_port); GO=$(free_port)
export GW_HOME="$TMP/gw" GUARD_PORT_FREELLMAPI=$GF GUARD_PORT_OMNIROUTE=$GO
L="$ROOT/termux/claude-free.sh"
KEY="fg_$(date +%s%N | sha256sum | cut -c1-32)"
mkdir -p "$GW_HOME/config" "$TMP/bin"
( umask 077; printf '%s\n' "$KEY" > "$GW_HOME/config/guard-freellmapi.clientkey"; printf '%s\n' "$KEY" > "$GW_HOME/config/guard-omniroute.clientkey" )

# stand-in guards: GET /v1/models answers 200 only for the right Bearer key
cat > "$TMP/guard.mjs" <<'JS'
import http from 'node:http';
const [port, key] = process.argv.slice(2);
http.createServer((q, s) => { s.writeHead(q.url === '/v1/models' && q.headers.authorization === `Bearer ${key}` ? 200 : 401, { 'content-type': 'application/json' }); s.end('{"data":[]}'); })
  .listen(Number(port), '127.0.0.1');
JS
# stand-in claude: records its environment and arguments
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
env > "$TMP/claude.env"; printf '%s\n' "\$@" > "$TMP/claude.args"
EOF
chmod +x "$TMP/bin/claude"
start_guard() { node "$TMP/guard.mjs" "$1" "$KEY" & PIDS+=("$!"); for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0; sleep 0.1; done; return 1; }
envv() { grep -E "^$1=" "$TMP/claude.env" | cut -d= -f2-; }
run() { PATH="$TMP/bin:$PATH" ANTHROPIC_API_KEY=sk-ant-real-canary CLAUDE_CODE_OAUTH_TOKEN=oauth-canary CLAUDE_CODE_USE_BEDROCK=1 \
  ANTHROPIC_CUSTOM_HEADERS='x-steer: 1' CLAUDE_CONFIG_DIR="$TMP/my-real-claude" bash "$L" "$@"; }

ck "refuses when the guard is not running"            bash -c "! GW_HOME='$GW_HOME' bash '$L' --check"
start_guard "$GF" || echo "stand-in guard did not start"
start_guard "$GO" || echo "stand-in guard did not start"
ck "--check passes with the guard and the right key"   bash "$L" --check
ck "--gateway omniroute --check"                       bash "$L" --gateway omniroute --check
ck "unknown gateway refused"                           bash -c "! bash '$L' --gateway foo --check"
ck "odd model id refused"                              bash -c "! bash '$L' --model 'a b' --check"

rm -f "$TMP/claude.env" "$TMP/claude.args"
ck "launches claude with the arguments passed through" run -p "hello there" --output-format json
ck "argv is exactly what the caller gave"              bash -c "[ \"\$(cat '$TMP/claude.args')\" = \"\$(printf '%s\n' -p 'hello there' --output-format json)\" ]"
ck "the guard key never appears in argv"               bash -c "! grep -qF '$KEY' '$TMP/claude.args'"
ck "base URL is the local FreeLLMAPI guard"            bash -c "[ \"\$(grep '^ANTHROPIC_BASE_URL=' '$TMP/claude.env' | cut -d= -f2-)\" = 'http://127.0.0.1:$GF' ]"
ck "guard key passed via ANTHROPIC_AUTH_TOKEN"         bash -c "[ \"\$(grep '^ANTHROPIC_AUTH_TOKEN=' '$TMP/claude.env' | cut -d= -f2-)\" = '$KEY' ]"
ck "real credentials and provider switches removed"   bash -c "! grep -qE '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_USE_BEDROCK|ANTHROPIC_CUSTOM_HEADERS)=' '$TMP/claude.env' && ! grep -q canary '$TMP/claude.env'"
ck "own config dir (not the caller's), mode 700"      bash -c "[ \"\$(grep '^CLAUDE_CONFIG_DIR=' '$TMP/claude.env' | cut -d= -f2-)\" = '$GW_HOME/claude-code' ] && [ \"\$(stat -c %a '$GW_HOME/claude-code')\" = 700 ] && [ ! -e '$TMP/my-real-claude' ]"
ck "every model slot pinned to the free model"         bash -c "for v in ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do [ \"\$(grep \"^\$v=\" '$TMP/claude.env' | cut -d= -f2-)\" = gpt-oss-20b ] || exit 1; done"
ck "Anthropic telemetry/update traffic switched off"   bash -c "grep -q '^CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1$' '$TMP/claude.env'"
ck "omniroute: its guard and its free model"           bash -c "PATH='$TMP/bin':\$PATH bash '$L' --gateway omniroute -p x && grep -q '^ANTHROPIC_BASE_URL=http://127.0.0.1:$GO$' '$TMP/claude.env' && grep -q '^ANTHROPIC_MODEL=ovhanon/gpt-oss-120b$' '$TMP/claude.env'"
ck "--model overrides the default"                     bash -c "PATH='$TMP/bin':\$PATH bash '$L' --model mistral-small-latest -- -p x && grep -q '^ANTHROPIC_DEFAULT_HAIKU_MODEL=mistral-small-latest$' '$TMP/claude.env' && [ \"\$(cat '$TMP/claude.args')\" = \"\$(printf '%s\n' -p x)\" ]"

printf '%s\n' "fg_wrong-wrong-wrong-wrong" > "$TMP/wrong"; chmod 600 "$TMP/wrong"; cp -p "$GW_HOME/config/guard-freellmapi.clientkey" "$TMP/right"
cp -p "$TMP/wrong" "$GW_HOME/config/guard-freellmapi.clientkey"
ck "a key the guard rejects stops before claude starts" bash -c "rm -f '$TMP/claude.env'; ! PATH='$TMP/bin':\$PATH bash '$L' -p x && [ ! -e '$TMP/claude.env' ]"
cp -p "$TMP/right" "$GW_HOME/config/guard-freellmapi.clientkey"; chmod 644 "$GW_HOME/config/guard-freellmapi.clientkey"
ck "a key file others can read is refused"             bash -c "! bash '$L' --check"
chmod 600 "$GW_HOME/config/guard-freellmapi.clientkey"
mkdir -p "$TMP/nodeonly"; ln -sf "$(command -v node)" "$TMP/nodeonly/node"   # only node: its folder may also hold a real claude
ck "missing claude is reported, not crashed"           bash -c "out=\$(PATH=/usr/bin:/bin:'$TMP/nodeonly' bash '$L' -p x 2>&1); [ \$? -ne 0 ] && echo \"\$out\" | grep -q 'Claude Code is not installed'"

# config folder ownership: another user must not be able to plant settings/hooks that Claude Code would run as you
mkdir -p "$TMP/mine"
ck "CLAUDE_FREE_CONFIG_DIR is used (mode 700)"          bash -c "PATH='$TMP/bin':\$PATH CLAUDE_FREE_CONFIG_DIR='$TMP/mine/cc' bash '$L' -p x && grep -q '^CLAUDE_CONFIG_DIR=$TMP/mine/cc$' '$TMP/claude.env' && [ \"\$(stat -c %a '$TMP/mine/cc')\" = 700 ]"
if [ "$(id -u)" = 0 ]; then mkdir -p "$TMP/foreign" && chown 65534 "$TMP/foreign"; FOREIGN="$TMP/foreign"; else FOREIGN=""; fi   # as non-root, / belongs to someone else
ck "a config folder inside another user's folder is refused (claude never starts)" bash -c "rm -f '$TMP/claude.env'; ! PATH='$TMP/bin':\$PATH CLAUDE_FREE_CONFIG_DIR='$FOREIGN/cc-free-test' bash '$L' -p x && [ ! -e '$TMP/claude.env' ] && [ ! -e '$FOREIGN/cc-free-test' ]"
if [ "$(id -u)" = 0 ]; then
  mkdir -p "$TMP/mine/theirs" && chown 65534 "$TMP/mine/theirs"
  ck "an existing config folder owned by another user is refused" bash -c "! PATH='$TMP/bin':\$PATH CLAUDE_FREE_CONFIG_DIR='$TMP/mine/theirs' bash '$L' -p x"
fi
