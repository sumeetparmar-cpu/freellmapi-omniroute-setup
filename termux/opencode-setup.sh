#!/usr/bin/env bash
# OpenCode <-> the two guarded gateways (Termux or generic Linux). Does NOT install OpenCode and never touches the gateways.
#
#   ./opencode-setup.sh probe     READ-ONLY: what this phone offers for installing OpenCode (send me the output)
#   ./opencode-setup.sh config    write the OpenCode config + the `opencode-free` launcher (an existing config is backed up, never silently overwritten)
#   ./opencode-setup.sh check     validate: config parses, ONLY our two providers are enabled, the small/background model is ours, no key is inside the file
#
# The config contains NO secret: the guard keys stay in their mode-600 files and are exported by the launcher at run time.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
CFG_DIR="${OPENCODE_CFG_DIR:-$HOME/.config/opencode}"; CFG="$CFG_DIR/opencode.json"
BIN_DIR="$GW_HOME/bin"; LAUNCH="$BIN_DIR/opencode-free"; OC="$GW_HOME/opencode"; INNER="$OC/inner.sh"
GUARD_PORT_FREELLMAPI="${GUARD_PORT_FREELLMAPI:-3101}"; GUARD_PORT_OMNIROUTE="${GUARD_PORT_OMNIROUTE:-20228}"
FL_MODEL="${FL_MODEL:-gpt-oss-20b}"; OR_MODEL="${OR_MODEL:-ovhanon/gpt-oss-120b}"

cmd_probe() {
  echo "== OpenCode install probe (read-only) =="
  echo "node platform : $(node -p 'process.platform+" / node "+process.version' 2>/dev/null || echo 'node missing')   arch: $(uname -m)   termux: ${TERMUX_VERSION:-no}"
  echo "free storage  : $(df -k "$HOME" 2>/dev/null | awk 'END{printf "%d MB", $(NF-2)/1024}')"
  echo "opencode now  : $(command -v opencode || echo 'not installed')"
  if have pkg; then r="$(timeout 25 pkg search opencode 2>/dev/null | grep -iE '^opencode' | head -3 | tr '\n' ' ')"; echo "pkg search    : ${r:-no 'opencode' package in your Termux repositories}"; fi
  echo "proot-distro  : $(command -v proot-distro || echo 'not installed')"
  echo "glibc loader  : $(ls /lib/ld-linux-aarch64.so.1 /lib64/ld-linux-x86-64.so.2 2>/dev/null | head -1 || true)$([ -e /lib/ld-linux-aarch64.so.1 ] || echo 'none (Termux has no glibc: Linux binaries need proot-distro)')"
  echo "gateways      : FreeLLMAPI guard $(up_state "$GUARD_PORT_FREELLMAPI"), OmniRoute guard $(up_state "$GUARD_PORT_OMNIROUTE")"
  echo "guard keys    : $([ -s "$GW_CONFIG_DIR/guard-freellmapi.clientkey" ] && [ -s "$GW_CONFIG_DIR/guard-omniroute.clientkey" ] && echo 'present (mode 600, not shown)' || echo 'MISSING: run termux/bootstrap.sh')"
}
up_state() { port_in_use "$1" && echo up || echo DOWN; }

cmd_config() {
  have node || die "node not found"
  [ -s "$GW_CONFIG_DIR/guard-freellmapi.clientkey" ] && [ -s "$GW_CONFIG_DIR/guard-omniroute.clientkey" ] || die "guard keys missing: run termux/bootstrap.sh first"
  mkdir -p "$CFG_DIR" "$BIN_DIR"
  local new="$CFG.new"
  local extra=""; [ -e "$GW_STATE_DIR/providers.groq" ] && extra="groq"; [ -e "$GW_STATE_DIR/providers.gemini" ] && extra="$extra gemini"   # keys added by add-provider.sh
  EXTRA="$extra" FLP="$GUARD_PORT_FREELLMAPI" ORP="$GUARD_PORT_OMNIROUTE" FLM="$FL_MODEL" ORM="$OR_MODEL" node -e '
    const e = process.env;
    const model = (id, name) => ({ [id]: { name, tool_call: true, reasoning: true, limit: { context: 131072, output: 16384 } } });
    const cfg = {
      $schema: "https://opencode.ai/config.json",
      // Only these two providers exist for OpenCode: no Anthropic, no OpenCode Zen, nothing that could bill or silently fall back.
      enabled_providers: ["freellmapi", "omniroute"],
      model: `omniroute/${e.ORM}`,   // the larger model: it fixed the acceptance bug, the 20B did not (Groq 120B takes over below when a Groq key was added)
      small_model: `freellmapi/${e.FLM}`,   // background chores (titles, summaries) must not use a default model of some other provider
      share: "disabled", autoupdate: false,
      permission: { edit: "ask", bash: "ask", webfetch: "ask" },
      provider: {
        freellmapi: { npm: "@ai-sdk/openai-compatible", name: "FreeLLMAPI (free-only guard)", env: ["FREELLMAPI_GUARD_KEY"],
          options: { baseURL: `http://127.0.0.1:${e.FLP}/v1`, apiKey: "{env:FREELLMAPI_GUARD_KEY}" }, models: model(e.FLM, `${e.FLM} (OVH anonymous)`) },
        omniroute: { npm: "@ai-sdk/openai-compatible", name: "OmniRoute (free-only guard)", env: ["OMNIROUTE_GUARD_KEY"],
          options: { baseURL: `http://127.0.0.1:${e.ORP}/v1`, apiKey: "{env:OMNIROUTE_GUARD_KEY}" }, models: model(e.ORM, `${e.ORM} (OVH anonymous)`) },
      },
    };
    const extra = (e.EXTRA || "").split(/\s+/).filter(Boolean);
    const om = cfg.provider.omniroute.models;
    if (extra.includes("groq")) { Object.assign(om, model("groq/openai/gpt-oss-120b", "gpt-oss-120b (Groq free tier)"), model("groq/openai/gpt-oss-20b", "gpt-oss-20b (Groq free tier)")); cfg.model = "omniroute/groq/openai/gpt-oss-120b"; }
    if (extra.includes("gemini")) Object.assign(om, model("gemini/gemini-2.5-flash", "gemini-2.5-flash (Gemini free tier; Google may train on prompts)"), model("gemini/gemini-2.5-flash-lite", "gemini-2.5-flash-lite (Gemini free tier)"));
    require("fs").writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });' "$new" || die "could not write the config"
  if [ -f "$CFG" ] && ! cmp -s "$CFG" "$new"; then cp -p "$CFG" "$CFG.bak-$(timestamp)"; info "existing config backed up to $CFG.bak-*"; fi
  mv "$new" "$CFG"; chmod 600 "$CFG"; ok "config written: $CFG (no secrets inside)"
  # Two small generated scripts. INNER runs inside whatever provides glibc (grun, or a proot Debian) and reads the keys from their files there:
  # the keys never appear on a command line, in the environment of the outer shell, or in any file this script writes.
  mkdir -p "$OC"
  cat > "$INNER" <<EOF
#!/bin/sh
# generated by termux/opencode-setup.sh. args: HOME WORKDIR [opencode args...]. Holds no secret.
HOME_DIR="\$1"; WORK="\$2"; shift 2
export HOME="\$HOME_DIR"
FREELLMAPI_GUARD_KEY="\$(head -n1 "$GW_HOME/config/guard-freellmapi.clientkey")"; OMNIROUTE_GUARD_KEY="\$(head -n1 "$GW_HOME/config/guard-omniroute.clientkey")"
export FREELLMAPI_GUARD_KEY OMNIROUTE_GUARD_KEY OPENCODE_CONFIG="$CFG" OPENCODE_DISABLE_AUTOUPDATE=true
cd "\$WORK" 2>/dev/null || cd "\$HOME_DIR" || exit 1
case "\$(cat "$OC/runner" 2>/dev/null)" in
  grun) exec grun "$OC/bin/opencode" "\$@" ;;
  *)    exec "$OC/bin/opencode" "\$@" ;;
esac
EOF
  cat > "$LAUNCH" <<EOF
#!/usr/bin/env bash
# generated by termux/opencode-setup.sh: OpenCode against the two free-only guards (and nothing else).
OC="$OC"; runner="\$(cat "\$OC/runner" 2>/dev/null)" || { echo "OpenCode is not installed yet: run  bash $HERE/opencode-install.sh" >&2; exit 1; }
for p in $GUARD_PORT_FREELLMAPI $GUARD_PORT_OMNIROUTE; do (exec 3<>"/dev/tcp/127.0.0.1/\$p") 2>/dev/null || { echo "opencode-free: starting the gateways first" >&2; bash "$HERE/gateways.sh" start || exit 1; break; }; done
case "\$runner" in
  proot) binds=(); case "$GW_HOME" in "\$HOME"/*) ;; *) binds=(--bind "$GW_HOME:$GW_HOME") ;; esac   # proot-distro already shares the Termux home at the same path; an extra bind only prints a warning
         exec proot-distro login debian --shared-tmp "\${binds[@]}" -- sh "$INNER" "\$HOME" "\$PWD" "\$@" ;;
  *)     exec sh "$INNER" "\$HOME" "\$PWD" "\$@" ;;
esac
EOF
  chmod 700 "$LAUNCH" "$INNER"; ok "launcher written: $LAUNCH   (run it instead of 'opencode')"
  [ -f "$OC/runner" ] || info "OpenCode itself is not installed yet: run  bash $HERE/opencode-install.sh"
}

cmd_check() {
  [ -f "$CFG" ] || die "no config at $CFG (run: $0 config)"
  CFGF="$CFG" FLP="$GUARD_PORT_FREELLMAPI" ORP="$GUARD_PORT_OMNIROUTE" node -e '
    const fs = require("fs"); const e = process.env; const fails = [];
    let c; try { c = JSON.parse(fs.readFileSync(e.CFGF, "utf8")); } catch (x) { console.log("FAIL config is not valid JSON"); process.exit(1); }
    const same = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());
    if (!same(c.enabled_providers ?? [], ["freellmapi", "omniroute"])) fails.push("enabled_providers must be exactly freellmapi + omniroute");
    for (const k of ["model", "small_model"]) if (!/^(freellmapi|omniroute)\//.test(c[k] ?? "")) fails.push(`${k} must belong to one of our two providers`);
    for (const [id, port] of [["freellmapi", e.FLP], ["omniroute", e.ORP]]) {
      const u = c.provider?.[id]?.options?.baseURL; if (u !== `http://127.0.0.1:${port}/v1`) fails.push(`${id} baseURL must be the loopback GUARD port ${port}, got ${u}`);
      const k = c.provider?.[id]?.options?.apiKey; if (!/^\{env:[A-Z_]+\}$/.test(k ?? "")) fails.push(`${id} apiKey must be an {env:...} reference, never a literal key`);
    }
    if (/fg_[A-Za-z0-9_-]{16,}/.test(fs.readFileSync(e.CFGF, "utf8"))) fails.push("a literal guard key is inside the config");
    if (c.share !== "disabled") fails.push("share must be disabled");
    console.log(fails.length ? fails.map((f) => "FAIL " + f).join("\n") : "PASS config: only our two guarded providers, background model ours, loopback guard ports, no literal key");
    process.exit(fails.length ? 1 : 0);'
}

case "${1:-}" in
  probe) cmd_probe ;; config) cmd_config ;; check) cmd_check ;;
  *) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
