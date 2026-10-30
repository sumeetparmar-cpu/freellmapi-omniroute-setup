#!/usr/bin/env bash
# READ-ONLY diagnosis of FreeLLMAPI + OmniRoute on this phone (Termux) or any Linux box. Changes nothing, installs nothing, starts nothing.
# Prints NO secrets: only versions, paths, sizes, file modes, the NAMES of settings (never their values), ports and HTTP codes.
#   bash diagnose.sh            (GW_HOME=<dir> to inspect a non-default install location)
H="${GW_HOME:-$HOME/llm-gateways}"; CUR="$(node -v 2>/dev/null | sed 's/^v//')"
hdr() { printf '\n== %s ==\n' "$*"; }
ver() { local v; v="$("$@" 2>&1 | head -n1 | cut -c1-60)"; printf '%s' "${v:-?}"; }
tool() { local a=--version; [ "$1" = openssl ] && a=version; if command -v "$1" >/dev/null 2>&1; then printf '  %-9s %s\n' "$1" "$(ver "$1" "$a")"; else printf '  %-9s MISSING\n' "$1"; fi; }
mode() { stat -c %a "$1" 2>/dev/null || echo ?; }
size() { du -sh "$1" 2>/dev/null | cut -f1; }
up() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
http() { local c; c="$(curl -s -m 4 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)"; echo "${c:-000}"; }
names() { [ -f "$1" ] && grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | cut -d= -f1 | tr '\n' ' '; }
val() { [ -f "$1" ] && grep -E "^$2=" "$1" | head -n1 | cut -d= -f2-; }   # only used for NON-secret settings (ports, paths)
FL_STATE=none; OR_STATE=none; FL_DIR=""; OR_DIR=""; NOTES=()

hdr "PHONE"
echo "  termux=${TERMUX_VERSION:-no} arch=$(uname -m) android=$(getprop ro.build.version.release 2>/dev/null || echo -)"
echo "  ram total/available MB: $(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d/%d",t/1024,a/1024}' /proc/meminfo 2>/dev/null)   free storage in HOME: $(df -Pm "$HOME" 2>/dev/null | awk 'NR==2{print $4}') MB"
for t in node npm git curl openssl python make clang setsid; do tool "$t"; done
echo "  install location checked: $H"

hdr "THIS TOOLKIT (repo)"
for d in "$HOME/freellmapi-omniroute-setup" "$PWD"; do
  [ -f "$d/termux/bootstrap.sh" ] && { echo "  found: $d  branch=$(git -C "$d" branch --show-current 2>/dev/null) commit=$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"; REPO=1; break; }
done; [ -n "${REPO:-}" ] || echo "  not cloned yet"

hdr "FREELLMAPI"
CANDS=("$H/freellmapi" "$HOME/freellmapi" "$HOME/FreeLLMAPI")
while IFS= read -r f; do CANDS+=("$(dirname "$f")"); done < <(find "$HOME" -maxdepth 3 -name package.json -not -path '*/node_modules/*' -exec grep -l '"name": *"freellmapi' {} + 2>/dev/null)
for d in "${CANDS[@]}"; do
  [ -f "$d/package.json" ] || continue; [ "$d" = "$FL_DIR" ] && continue
  FL_DIR="$d"
  echo "  found: $d ($(size "$d"))  version=$(grep -m1 '"version"' "$d/package.json" | tr -dc '0-9.')  git=$(git -C "$d" describe --tags --always 2>/dev/null)"
  echo "    built (server/dist): $([ -d "$d/server/dist" ] && echo yes || echo NO)   dependencies (node_modules): $([ -d "$d/node_modules" ] && echo yes || echo NO)"
  [ -d "$d/server/dist" ] && [ -d "$d/node_modules" ] && FL_STATE=installed || FL_STATE=partial
  break
done
[ -n "$FL_DIR" ] || echo "  not found"
for e in "$H/config/freellmapi.env" "${FL_DIR:+$FL_DIR/.env}"; do [ -n "$e" ] && [ -f "$e" ] && echo "  settings file: $e mode=$(mode "$e") names: $(names "$e")"; done
for db in "$H/freellmapi-data/freeapi.db" "${FL_DIR:+$FL_DIR/freellmapi-data/freeapi.db}" "${FL_DIR:+$FL_DIR/server/freeapi.db}"; do [ -n "$db" ] && [ -f "$db" ] && echo "  data (your accounts/keys): $db  $(du -h "$db" | cut -f1)"; done
[ -f "$H/state/freellmapi.node_version" ] && echo "  built with node $(cat "$H/state/freellmapi.node_version") (running node $CUR)"

hdr "OMNIROUTE"
NB="$(command -v node 2>/dev/null)"; GROOT="${NB:+$(dirname "$(dirname "$NB")")/lib/node_modules}"   # no npm call: npm writes logs under ~/.npm
for d in "$H/omniroute/node_modules/omniroute" "$GROOT/omniroute" "$HOME/node_modules/omniroute"; do
  [ -f "$d/package.json" ] || continue
  OR_DIR="$d"; OR_STATE=installed
  echo "  found: $d ($(size "$d"))  version=$(grep -m1 '"version"' "$d/package.json" | tr -dc '0-9.')   entry: $([ -f "$d/bin/omniroute.mjs" ] && echo yes || echo NO)"
  [ -f "$d/bin/omniroute.mjs" ] || OR_STATE=partial; break
done
[ -n "$OR_DIR" ] || echo "  not found"
command -v omniroute >/dev/null 2>&1 && echo "  'omniroute' command on PATH: $(command -v omniroute)"
E="$H/config/omniroute.env"; [ -f "$E" ] && echo "  settings file: $E mode=$(mode "$E") names: $(names "$E")"
DD="$(val "$E" DATA_DIR)"; for d in "$DD" "$H/omniroute-data" "$HOME/.omniroute"; do [ -n "$d" ] && [ -d "$d" ] && { echo "  data (your providers/keys): $d ($(size "$d"))  database: $([ -f "$d/storage.sqlite" ] && echo present || echo none)"; break; }; done
[ -f "$H/state/omniroute.node_version" ] && { echo "  built with node $(cat "$H/state/omniroute.node_version") (running node $CUR)"; [ "$(cat "$H/state/omniroute.node_version")" != "$CUR" ] && NOTES+=("Node changed since OmniRoute was built: a REBUILD (not a reinstall) fixes it:  bash termux/omniroute.sh rebuild"); }

hdr "RUNNING NOW"
FP="$(val "$H/config/gateways.env" FREELLMAPI_PORT)"; FP="${FP:-3001}"; OP="$(val "$H/config/gateways.env" OMNIROUTE_PORT)"; OP="${OP:-20128}"
for x in "FreeLLMAPI:$FP:/api/ping" "OmniRoute:$OP:/api/health/ping" "FreeLLMAPI-guard:3101:/__guard/status" "OmniRoute-guard:20228:/__guard/status"; do
  IFS=: read -r n p path <<<"$x"; if up "$p"; then echo "  $n  port $p OPEN   health HTTP $(http "http://127.0.0.1:$p$path")"; else echo "  $n  port $p closed"; fi
done
echo "  processes (program + script only, never arguments):"; for c in /proc/[0-9]*/cmdline; do pid="$(basename "$(dirname "$c")")"; [ "$pid" = "$$" ] && continue; a="$(tr '\0' ' ' <"$c" 2>/dev/null)"; case "$a" in bash*|sh\ *|sed*|grep*|awk*|tr\ *|*/bash*|*/sh\ *) continue;; *freellmapi*|*omniroute*|*free-guard*|*server/dist*) printf '    %s %s\n' "$pid" "$(printf '%s' "$a" | awk '{print $1, $2}' | cut -c1-90)";; esac; done

hdr "CREDENTIAL FILES FROM THIS TOOLKIT (names and modes only)"
ls "$H/config" 2>/dev/null | while read -r f; do printf '    %-40s mode %s\n' "$f" "$(mode "$H/config/$f")"; done; [ -d "$H/config" ] || echo "    none"

hdr "WHAT TO DO NEXT (nothing below deletes or reinstalls anything that works)"
case "$FL_STATE" in installed) echo "  FreeLLMAPI: installed -> reuse it";; partial) echo "  FreeLLMAPI: PARTIAL -> repair only: bash termux/freellmapi.sh install   (keeps source and data, completes dependencies/build)";; *) echo "  FreeLLMAPI: not found -> needs a first install";; esac
case "$OR_STATE" in installed) echo "  OmniRoute: installed -> reuse it";; partial) echo "  OmniRoute: PARTIAL -> repair only: bash termux/omniroute.sh install   (keeps data)";; *) echo "  OmniRoute: not found -> needs a first install";; esac
if [ -n "$FL_DIR" ] && [ "$FL_DIR" != "$H/freellmapi" ]; then NOTES+=("FreeLLMAPI lives at $FL_DIR, not in $H: the toolkit's scripts expect $H/freellmapi. Send me this output; I will point the scripts at it (no move, no copy).") ; fi
if [ -n "$OR_DIR" ] && [ "$OR_DIR" != "$H/omniroute/node_modules/omniroute" ]; then NOTES+=("OmniRoute lives at $OR_DIR, not in $H/omniroute: send me this output; I will point the scripts at it (no move, no copy).") ; fi
{ up "$FP" || up "$OP"; } && NOTES+=("A gateway is already running: do NOT start a second copy; the scripts detect it and leave it as is.")
if [ -z "${REPO:-}" ]; then NOTES+=("The toolkit itself is not on the phone yet (needed only for the start/guard scripts): see docs/PHONE-TERMUX.md for the clone command."); fi
for n in "${NOTES[@]}"; do echo "  * $n"; done
echo; echo "Paste everything above back to me. No secret was printed."
