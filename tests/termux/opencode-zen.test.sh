#!/usr/bin/env bash
# opencode-setup.sh zen-config / zen-check and the generated `opencode-zen-free` launcher, with a stand-in opencode binary that reports the
# environment it was started with. No network: whether opencode.ai really serves the free models is a live check (docs/OPENCODE-TERMUX.md).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; T="$(mktemp -d)"; PASS=0; FAIL=0
cleanup() { rm -rf "$T"; echo "opencode-zen: passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1; }; trap cleanup EXIT
ck() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then PASS=$((PASS + 1)); echo "ok   - $n"; else FAIL=$((FAIL + 1)); echo "FAIL - $n"; sed 's/^/       /' "$T/out" | tail -8; fi; }
export HOME="$T/home" GW_HOME="$T/gw" OPENCODE_CFG_DIR="$T/guarded-cfg"; mkdir -p "$HOME" "$GW_HOME/config" "$GW_HOME/opencode/bin"
SETUP="$ROOT/termux/opencode-setup.sh"; OC="$GW_HOME/opencode"; ZEN="$OC/zen"; ZCFG="$ZEN/config/opencode/opencode.json"; LZ="$GW_HOME/bin/opencode-zen-free"
cat > "$OC/bin/opencode" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "1.19.5" ;;
  --probe) shift; echo "ARGC=$#"; for a in "$@"; do echo "ARG=[$a]"; done; echo "CWD=$(pwd)"; env | grep -E '^(HOME|XDG_[A-Z]+_HOME|OPENCODE_[A-Z_]+|ANTHROPIC_[A-Z_]+|OPENAI_[A-Z_]+|GROQ_API_KEY|FREELLMAPI_GUARD_KEY|OMNIROUTE_GUARD_KEY)=' | sort ;;
esac
SH
chmod +x "$OC/bin/opencode"; echo native > "$OC/runner"
# the guarded profile exists too: the zen profile must not change it
K1="fg_$(date +%s%N | sha256sum | cut -c1-30)"; printf '%s\n' "$K1" > "$GW_HOME/config/guard-freellmapi.clientkey"; printf '%s\n' "$K1" > "$GW_HOME/config/guard-omniroute.clientkey"; chmod 600 "$GW_HOME"/config/*
bash "$SETUP" config >/dev/null 2>&1
h() { sha256sum "$OPENCODE_CFG_DIR/opencode.json" "$GW_HOME/bin/opencode-free" "$OC/inner.sh" | awk '{print $1}' | tr '\n' ' '; }
BEFORE="$(h)"

ck "zen-config writes the profile and its launcher"          bash "$SETUP" zen-config
ck "zen-check passes on the fresh profile"                   bash "$SETUP" zen-check
ck "config: only the opencode provider, nothing pinned, share off, mode 600" bash -c "node -e 'const c=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit(JSON.stringify(c.enabled_providers)===JSON.stringify([\"opencode\"])&&c.model===undefined&&c.share===\"disabled\"&&!c.provider?0:1)' '$ZCFG' && [ \"\$(stat -c %a '$ZCFG')\" = 600 ]"
AFTER="$(h)"
ck "the guarded profile is untouched (config, launcher, inner script)" test "$AFTER" = "$BEFORE"

out() { (cd "$T/work dir" && OPENCODE_API_KEY=oc-canary OPENCODE_CONFIG=/elsewhere.json ANTHROPIC_API_KEY=sk-ant-canary OPENAI_API_KEY=sk-canary GROQ_API_KEY=gsk-canary \
  FREELLMAPI_GUARD_KEY=fg-canary "$LZ" --probe "one arg" two); }
mkdir -p "$T/work dir"; out > "$T/probe" 2>&1
ck "launcher: arguments with spaces survive, cwd and HOME are kept" bash -c "grep -q '^ARGC=2$' '$T/probe' && grep -qF 'ARG=[one arg]' '$T/probe' && grep -q '^CWD=$T/work dir$' '$T/probe' && grep -q '^HOME=$HOME$' '$T/probe'"
ck "launcher: config, data, cache and state all live in the zen profile" bash -c "for d in CONFIG DATA CACHE STATE; do grep -q \"^XDG_\${d}_HOME=$ZEN/\" '$T/probe' || exit 1; done"
ck "launcher: no OpenCode key or config override reaches OpenCode (anonymous)" bash -c "! grep -qE '^OPENCODE_(API_KEY|CONFIG)=' '$T/probe' && grep -q '^OPENCODE_DISABLE_AUTOUPDATE=true$' '$T/probe'"
ck "launcher: none of the caller's provider keys or guard keys reach OpenCode" bash -c "! grep -q canary '$T/probe'"

ZEN_MODEL=opencode/some-free-model bash "$SETUP" zen-config >/dev/null 2>&1
ck "ZEN_MODEL pins model and small_model; the old config is backed up" bash -c "grep -q '\"model\": \"opencode/some-free-model\"' '$ZCFG' && grep -q '\"small_model\": \"opencode/some-free-model\"' '$ZCFG' && ls '$ZCFG'.bak-* >/dev/null"
ck "a ZEN_MODEL from another provider is refused"           bash -c "! ZEN_MODEL=anthropic/claude-sonnet-4-5 bash '$SETUP' zen-config"
bash "$SETUP" zen-config >/dev/null 2>&1

mkdir -p "$ZEN/data/opencode"; printf '{"opencode":{"type":"api","key":"zen-paid-key"}}' > "$ZEN/data/opencode/auth.json"
ck "zen-check FAILS when a Zen login is saved in the profile" bash -c "! bash '$SETUP' zen-check"
ck "and the launcher then refuses to start OpenCode"        bash -c "! '$LZ' --version"
rm -f "$ZEN/data/opencode/auth.json"
node -e 'const f=process.argv[1],fs=require("fs");const c=JSON.parse(fs.readFileSync(f,"utf8"));c.provider={opencode:{options:{apiKey:"x"}}};fs.writeFileSync(f,JSON.stringify(c))' "$ZCFG"
ck "zen-check FAILS when the config carries an apiKey"      bash -c "! bash '$SETUP' zen-check"
node -e 'const f=process.argv[1],fs=require("fs");const c=JSON.parse(fs.readFileSync(f,"utf8"));delete c.provider;c.enabled_providers=["opencode","anthropic"];fs.writeFileSync(f,JSON.stringify(c))' "$ZCFG"
ck "zen-check FAILS when another provider is enabled"       bash -c "! bash '$SETUP' zen-check"
bash "$SETUP" zen-config >/dev/null 2>&1
ck "re-running zen-config restores a passing profile"       bash -c "bash '$SETUP' zen-check && [ \"\$('$LZ' --version)\" = 1.19.5 ]"
ck "no key is in any file the setup wrote"                  bash -c "! grep -rqF -e '$K1' -e canary '$ZEN/config' '$LZ' '$OC/inner-zen.sh'"
