#!/usr/bin/env bash
# opencode-setup.sh config/check (no OpenCode, no network): the generated config must expose ONLY our two guarded providers and no secret.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; T="$(mktemp -d)"; PASS=0; FAIL=0
cleanup() { rm -rf "$T"; echo "opencode-setup: passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1; }; trap cleanup EXIT
ck() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then PASS=$((PASS + 1)); echo "ok   - $n"; else FAIL=$((FAIL + 1)); echo "FAIL - $n"; sed 's/^/       /' "$T/out" | tail -6; fi; }
export HOME="$T/home" GW_HOME="$T/gw"; mkdir -p "$GW_HOME/config" "$HOME"
KEY1="fg_$(date +%s%N | sha256sum | cut -c1-30)"; KEY2="fg_$(date +%N | sha256sum | cut -c1-30)"
printf '%s\n' "$KEY1" > "$GW_HOME/config/guard-freellmapi.clientkey"; printf '%s\n' "$KEY2" > "$GW_HOME/config/guard-omniroute.clientkey"; chmod 600 "$GW_HOME"/config/*
S="$ROOT/termux/opencode-setup.sh"; CFG="$HOME/.config/opencode/opencode.json"
ck "config refuses to run without guard keys"          bash -c "rm -f '$GW_HOME/config/guard-omniroute.clientkey'; ! bash '$S' config; printf '%s\n' '$KEY2' > '$GW_HOME/config/guard-omniroute.clientkey'; chmod 600 '$GW_HOME/config/guard-omniroute.clientkey'"
ck "config writes the file and the launcher"           bash -c "bash '$S' config && [ -f '$CFG' ] && [ -x '$GW_HOME/bin/opencode-free' ]"
ck "config file is mode 600"                           bash -c "[ \"\$(stat -c %a '$CFG')\" = 600 ]"
ck "config check passes"                               bash "$S" check
ck "no guard key is inside the config, launcher or inner script" bash -c "! grep -qF -e '$KEY1' -e '$KEY2' '$CFG' '$GW_HOME/bin/opencode-free' '$GW_HOME/opencode/inner.sh'"
ck "the inner script reads the keys from their files"  bash -c "grep -q 'guard-freellmapi.clientkey' '$GW_HOME/opencode/inner.sh' && grep -q 'guard-omniroute.clientkey' '$GW_HOME/opencode/inner.sh'"
ck "only freellmapi + omniroute are enabled providers" bash -c "node -e 'const c=JSON.parse(require(\"fs\").readFileSync(process.argv[1]));process.exit(JSON.stringify(c.enabled_providers.sort())===JSON.stringify([\"freellmapi\",\"omniroute\"])?0:1)' '$CFG'"
ck "small_model (background chores) is ours"           bash -c "node -e 'const c=JSON.parse(require(\"fs\").readFileSync(process.argv[1]));process.exit(/^freellmapi\\//.test(c.small_model)?0:1)' '$CFG'"
ck "re-running config changes nothing and makes no backup" bash -c "bash '$S' config >/dev/null && ! ls '$CFG'.bak-* >/dev/null 2>&1"
# mutations: check must catch each way the free-only property could be lost
mut() { local n="$1" expr="$2"; ck "check CATCHES: $n" bash -c "cp '$CFG' '$T/good.json'; node -e 'const fs=require(\"fs\");const c=JSON.parse(fs.readFileSync(process.argv[1]));$expr;fs.writeFileSync(process.argv[1],JSON.stringify(c))' '$CFG'; ! bash '$S' check; r=\$?; cp '$T/good.json' '$CFG'; [ \$r = 0 ]"; }
mut "an extra provider enabled (anthropic)"             'c.enabled_providers.push("anthropic")'
mut "enabled_providers removed (all built-ins active)"  'delete c.enabled_providers'
mut "small_model pointing at another provider"          'c.small_model="anthropic/claude-haiku-4-5"'
mut "a literal key instead of an env reference"         'c.provider.freellmapi.options.apiKey="fg_AAAAAAAAAAAAAAAAAAAAAAAA"'
mut "baseURL pointing at the raw gateway port"          'c.provider.omniroute.options.baseURL="http://127.0.0.1:20128/v1"'
mut "sharing enabled"                                   'c.share="auto"'
ck "a pre-existing different config is backed up, not lost" bash -c "echo '{\"theme\":\"x\"}' > '$CFG'; bash '$S' config >/dev/null; ls '$CFG'.bak-* >/dev/null 2>&1 && grep -q theme '$CFG'.bak-*"
