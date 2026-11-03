#!/usr/bin/env bash
# OpenCode <-> the two guarded gateways (Termux or generic Linux). Does NOT install OpenCode and never touches the gateways.
#
#   ./opencode-setup.sh probe     READ-ONLY: what this phone offers for installing OpenCode (send me the output)
#   ./opencode-setup.sh config    write the OpenCode config + the `opencode-free` launcher (an existing config is backed up, never silently overwritten)
#   ./opencode-setup.sh check     validate: config parses, ONLY our two providers are enabled, the small/background model is ours, no key is inside the file
#   ./opencode-setup.sh zen-config | zen-check   a SECOND, separate profile `opencode-zen-free`: only OpenCode's own free models (anonymous)
# The config contains NO secret: the guard keys stay in their mode-600 files and are exported by the launcher at run time.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
CFG_DIR="${OPENCODE_CFG_DIR:-$HOME/.config/opencode}"; CFG="$CFG_DIR/opencode.json"
BIN_DIR="$GW_HOME/bin"; LAUNCH="$BIN_DIR/opencode-free"; OC="$GW_HOME/opencode"; INNER="$OC/inner.sh"
GUARD_PORT_FREELLMAPI="${GUARD_PORT_FREELLMAPI:-3101}"; GUARD_PORT_OMNIROUTE="${GUARD_PORT_OMNIROUTE:-20228}"
FL_MODEL="${FL_MODEL:-gpt-oss-20b}"; OR_MODEL="${OR_MODEL:-ovhanon/gpt-oss-120b}"
# The zen profile has its own XDG dirs (config, sessions, auth store): nothing from the guarded profile or from a personal OpenCode setup
# (a saved Zen login, a global config) can reach it.
ZEN="$OC/zen"; ZEN_CFG="$ZEN/config/opencode/opencode.json"; ZEN_INNER="$OC/inner-zen.sh"; ZEN_LAUNCH="$BIN_DIR/opencode-zen-free"

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
  mkdir -p "$OC"
  # Measured on the phone: the 20B model invents absolute paths and OpenCode rejects them (external_directory); with this rule the same task passed.
  cat > "$OC/rules.md" <<'RULES'
# File path rules (added by the free-only toolkit)
- Always use paths RELATIVE to the current working directory (for example `math.js` or `src/app.js`) for every read, edit, glob and shell command.
- Never type an absolute path. Never invent a directory name. If you are unsure where a file is, run glob or ls first and reuse the relative path it shows.
RULES
  chmod 600 "$OC/rules.md"
  RULES="$OC/rules.md" FLP="$GUARD_PORT_FREELLMAPI" ORP="$GUARD_PORT_OMNIROUTE" FLM="$FL_MODEL" ORM="$OR_MODEL" node -e '
    const e = process.env;
    const model = (id, name) => ({ [id]: { name, tool_call: true, reasoning: true, limit: { context: 131072, output: 16384 } } });
    const cfg = {
      $schema: "https://opencode.ai/config.json",
      // Only these two providers exist for OpenCode: no Anthropic, no OpenCode Zen, nothing that could bill or silently fall back.
      enabled_providers: ["freellmapi", "omniroute"],
      model: `omniroute/${e.ORM}`,   // the larger model: it fixed the acceptance bug, the 20B did not
      small_model: `freellmapi/${e.FLM}`,   // background chores (titles, summaries) must not use a default model of some other provider
      instructions: [e.RULES],   // a plain markdown file inside the toolkit home: no secret, relative-path rule only
      share: "disabled", autoupdate: false,
      permission: { edit: "ask", bash: "ask", webfetch: "ask" },
      provider: {
        freellmapi: { npm: "@ai-sdk/openai-compatible", name: "FreeLLMAPI (free-only guard)", env: ["FREELLMAPI_GUARD_KEY"],
          options: { baseURL: `http://127.0.0.1:${e.FLP}/v1`, apiKey: "{env:FREELLMAPI_GUARD_KEY}" }, models: model(e.FLM, `${e.FLM} (OVH anonymous)`) },
        omniroute: { npm: "@ai-sdk/openai-compatible", name: "OmniRoute (free-only guard)", env: ["OMNIROUTE_GUARD_KEY"],
          options: { baseURL: `http://127.0.0.1:${e.ORP}/v1`, apiKey: "{env:OMNIROUTE_GUARD_KEY}" }, models: model(e.ORM, `${e.ORM} (OVH anonymous)`) },
      },
    };
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

# OpenCode's own provider ("opencode", Zen) runs ANONYMOUSLY when it finds no key: no key in the environment, no saved login, no apiKey in
# the config. Then OpenCode itself deletes every model whose price is not 0 and sends the public key (1.19.5 source:
# `if(!s)for(...){if(n.cost.input===0)continue;delete t.models[r]}` ... `options:s?{}:{apiKey:"public"}`). This profile keeps it that way.
# Its requests go straight to opencode.ai, NOT through the free-only guards; OpenCode's own terms for its free models apply.
cmd_zen_config() {
  have node || die "node not found"
  mkdir -p "$ZEN/config/opencode" "$ZEN/data" "$ZEN/cache" "$ZEN/state" "$BIN_DIR" "$OC"; chmod 700 "$ZEN"
  [ -f "$OC/rules.md" ] || printf '%s\n' '# File path rules (added by the free-only toolkit)' '- Always use paths RELATIVE to the current working directory.' > "$OC/rules.md"
  local new="$ZEN_CFG.new"
  # No model is pinned unless ZEN_MODEL=opencode/<id> is given: the free list changes, and only OpenCode's catalog knows today's free models.
  RULES="$OC/rules.md" MODEL="${ZEN_MODEL:-}" node -e '
    const e = process.env;
    const cfg = { $schema: "https://opencode.ai/config.json", enabled_providers: ["opencode"],
      instructions: [e.RULES], share: "disabled", autoupdate: false, permission: { edit: "ask", bash: "ask", webfetch: "ask" } };
    if (e.MODEL) {
      if (!/^opencode\/[A-Za-z0-9._:-]+$/.test(e.MODEL)) { console.error("ZEN_MODEL must look like opencode/<model>"); process.exit(2); }
      cfg.model = e.MODEL; cfg.small_model = e.MODEL;
    }
    require("fs").writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });' "$new" || die "could not write the zen config"
  if [ -f "$ZEN_CFG" ] && ! cmp -s "$ZEN_CFG" "$new"; then cp -p "$ZEN_CFG" "$ZEN_CFG.bak-$(timestamp)"; info "existing zen config backed up"; fi
  mv "$new" "$ZEN_CFG"; chmod 600 "$ZEN_CFG"; ok "zen config written: $ZEN_CFG"
  cat > "$ZEN_INNER" <<EOF
#!/bin/sh
# generated by termux/opencode-setup.sh zen-config. args: HOME WORKDIR [opencode args...]. Holds no secret.
HOME_DIR="\$1"; WORK="\$2"; shift 2
export HOME="\$HOME_DIR"
# anonymous on purpose: an OpenCode key or a config override would switch OpenCode's own free-only filter off
unset OPENCODE_API_KEY OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT
export XDG_CONFIG_HOME="$ZEN/config" XDG_DATA_HOME="$ZEN/data" XDG_CACHE_HOME="$ZEN/cache" XDG_STATE_HOME="$ZEN/state" OPENCODE_DISABLE_AUTOUPDATE=true
cd "\$WORK" 2>/dev/null || cd "\$HOME_DIR" || exit 1
case "\$(cat "$OC/runner" 2>/dev/null)" in
  grun) exec grun "$OC/bin/opencode" "\$@" ;;
  *)    exec "$OC/bin/opencode" "\$@" ;;
esac
EOF
  cat > "$ZEN_LAUNCH" <<EOF
#!/usr/bin/env bash
# generated by termux/opencode-setup.sh zen-config: OpenCode with ONLY OpenCode's own free models (anonymous; separate from opencode-free).
OC="$OC"; runner="\$(cat "\$OC/runner" 2>/dev/null)" || { echo "OpenCode is not installed yet: run  bash $HERE/opencode-install.sh" >&2; exit 1; }
GW_HOME="$GW_HOME" bash "$HERE/opencode-setup.sh" zen-check >/dev/null || { echo "opencode-zen-free: the free-only check failed; run  GW_HOME=$GW_HOME bash $HERE/opencode-setup.sh zen-check" >&2; exit 1; }
# none of your provider or guard keys may reach this process (a project config could otherwise enable another provider with one)
for v in \$(compgen -e); do case "\$v" in OPENCODE_*|ANTHROPIC_*|OPENAI_*|*_API_KEY|*_GUARD_KEY|AWS_BEARER_TOKEN_BEDROCK|AZURE_OPENAI_*) unset "\$v" ;; esac; done
case "\$runner" in
  proot) binds=(); case "$GW_HOME" in "\$HOME"/*) ;; *) binds=(--bind "$GW_HOME:$GW_HOME") ;; esac
         exec proot-distro login debian --shared-tmp "\${binds[@]}" -- sh "$ZEN_INNER" "\$HOME" "\$PWD" "\$@" ;;
  *)     exec sh "$ZEN_INNER" "\$HOME" "\$PWD" "\$@" ;;
esac
EOF
  chmod 700 "$ZEN_LAUNCH" "$ZEN_INNER"; ok "launcher written: $ZEN_LAUNCH   (OpenCode's own free models only; it does not use the guards)"
  [ -f "$OC/runner" ] || info "OpenCode itself is not installed yet: run  bash $HERE/opencode-install.sh"
}

cmd_zen_check() {
  [ -f "$ZEN_CFG" ] || die "no zen config at $ZEN_CFG (run: $0 zen-config)"
  CFGF="$ZEN_CFG" AUTHF="$ZEN/data/opencode/auth.json" node -e '
    const fs = require("fs"); const e = process.env; const fails = [];
    let c; try { c = JSON.parse(fs.readFileSync(e.CFGF, "utf8")); } catch { console.log("FAIL zen config is not valid JSON"); process.exit(1); }
    if (JSON.stringify(c.enabled_providers ?? []) !== JSON.stringify(["opencode"])) fails.push("enabled_providers must be exactly [opencode]");
    if (c.provider?.opencode?.options?.apiKey !== undefined) fails.push("an apiKey for opencode would switch off the free-only filter");
    for (const k of ["model", "small_model"]) if (c[k] !== undefined && !/^opencode\//.test(c[k])) fails.push(`${k} must be an opencode/... model`);
    if (c.share !== "disabled") fails.push("share must be disabled");
    let a = null; try { a = JSON.parse(fs.readFileSync(e.AUTHF, "utf8")); } catch { /* no saved login in this profile: good */ }
    if (a && a.opencode) fails.push("a saved OpenCode login exists in this profile (paid models would reappear): remove " + e.AUTHF);
    console.log(fails.length ? fails.map((f) => "FAIL " + f).join("\n") : "PASS zen: only the opencode provider, anonymous (no key, no saved login), share disabled");
    process.exit(fails.length ? 1 : 0);'
}

case "${1:-}" in
  probe) cmd_probe ;; config) cmd_config ;; check) cmd_check ;; zen-config) cmd_zen_config ;; zen-check) cmd_zen_check ;;
  *) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
