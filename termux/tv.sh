#!/usr/bin/env bash
# Android TV helper over ADB (Termux: pkg install android-tools). Phone and TV must be on the same Wi-Fi.
#
#   ./tv.sh connect <ip[:port]>     connect (default port 5555) and remember the address in $TV_CONFIG
#   ./tv.sh pair <ip:port> <code>   pair first (TVs with "Wireless debugging" pairing codes)
#   ./tv.sh status | disconnect
#   ./tv.sh home|back|up|down|left|right|ok|menu|play|pause|vol-up|vol-down|mute|power
#   ./tv.sh text "<string>"         type text into the focused field
#   ./tv.sh open <package>          launch an app (e.g. com.google.android.youtube.tv)
#   ./tv.sh apps                    list installed third-party packages
#   ./tv.sh install <file.apk>      sideload an app
#   ./tv.sh shell [cmd...]          raw adb shell on the TV
#
# Look & feel (all reversible):
#   ./tv.sh launcher list|current          home-screen apps / the one in use
#   ./tv.sh launcher install <file.apk>    sideload a launcher (FLauncher, Projectivy, Wolf Launcher...)
#   ./tv.sh launcher set <package>         make it the default home screen (remembers the previous one)
#   ./tv.sh launcher restore               go back to the remembered original launcher
#   ./tv.sh animations fast|off|default|show   window/transition/animator speed (fast = 0.5x, off = 0x)
#   ./tv.sh debloat list                   enabled system apps (candidates)
#   ./tv.sh debloat disabled               apps this tool or you disabled
#   ./tv.sh debloat disable <package>...   hide an app (pm disable-user; undo with enable). Core/launcher packages are refused
#   ./tv.sh debloat enable <package>...    bring it back
#
# Uses the saved address, or TV_ADDR=ip:port. Talks only to the TV on your LAN.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
TV_CONFIG="${TV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/tv-addr}"

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
need_adb() { have adb || die "adb not found (Termux: pkg install android-tools)"; }

# Accept only ip-or-hostname[:port]; nothing else reaches adb.
valid_addr() { [[ "$1" =~ ^[A-Za-z0-9._-]+(:[0-9]{1,5})?$ ]]; }

addr() {
  local a="${TV_ADDR:-}"
  [ -n "$a" ] || { [ -f "$TV_CONFIG" ] && a="$(head -n1 "$TV_CONFIG")"; }
  [ -n "$a" ] || die "no TV address: run './tv.sh connect <ip>' first (or set TV_ADDR)"
  valid_addr "$a" || die "bad TV address: $a"
  echo "$a"
}
adbtv() { adb -s "$(addr)" "$@"; }
key() { adbtv shell input keyevent "$1"; }

cmd_connect() {
  local a="${1:-}"; [ -n "$a" ] || die "usage: tv.sh connect <ip[:port]>"
  valid_addr "$a" || die "bad address: $a"
  case "$a" in *:*) ;; *) a="$a:5555" ;; esac
  adb connect "$a"
  adb -s "$a" get-state >/dev/null 2>&1 || die "not connected. Accept the 'Allow debugging?' prompt on the TV, check debugging is on, then retry"
  mkdir -p "$(dirname "$TV_CONFIG")"; printf '%s\n' "$a" > "$TV_CONFIG"; chmod 600 "$TV_CONFIG"
  info "connected to $a"
}

# ---- look & feel ----
valid_pkg() { [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$ ]]; }
LAUNCHER_STATE="${TV_LAUNCHER_STATE:-${XDG_CONFIG_HOME:-$HOME/.config}/tv-launcher-prev}"
# Packages that must never be disabled: the system itself, settings, Play services/store, setup, input and the active launcher.
protected_pkg() {
  case "$1" in
    android|com.android.systemui|com.android.settings|com.android.providers.*|com.android.inputmethod.*|com.android.vending|com.google.android.gms|com.google.android.gsf|com.google.android.tvlauncher|com.google.android.tvrecommendations|com.google.android.permissioncontroller|com.android.permissioncontroller|com.google.android.packageinstaller|com.android.packageinstaller|com.google.android.tv.remote.service|com.google.android.leanbacklauncher|com.google.android.setupwraith|com.google.android.apps.tv.launcherx) return 0 ;;
  esac
  [ "$1" = "$(current_launcher_pkg 2>/dev/null)" ]
}
home_components() { adbtv shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tr -d '\r' | grep -E '^[A-Za-z0-9_.]+/' || true; }
current_component() { adbtv shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tr -d '\r' | grep -E '^[A-Za-z0-9_.]+/' | tail -n1; }
current_launcher_pkg() { local c; c="$(current_component)"; echo "${c%%/*}"; }

cmd_launcher() {
  local sub="${1:-}"; [ $# -gt 0 ] && shift
  case "$sub" in
    list)    home_components ;;
    current) current_component ;;
    install) [ $# -eq 1 ] && [ -f "$1" ] || die "usage: tv.sh launcher install <file.apk>"; adbtv install -r "$1" ;;
    set)
      [ $# -eq 1 ] && valid_pkg "$1" || die "usage: tv.sh launcher set <package>  (see 'launcher list')"
      local comp; comp="$(home_components | grep -F "$1/" | head -n1)"
      [ -n "$comp" ] || die "$1 has no home activity. Install it first and check 'launcher list'"
      local cur; cur="$(current_component)"
      if [ -n "$cur" ] && [ "${cur%%/*}" != "$1" ]; then
        mkdir -p "$(dirname "$LAUNCHER_STATE")"; printf '%s\n' "$cur" > "$LAUNCHER_STATE"; chmod 600 "$LAUNCHER_STATE"
      fi
      adbtv shell cmd package set-home-activity --user 0 "$comp" >/dev/null
      adbtv shell input keyevent 3
      info "default launcher: $comp (original saved; './tv.sh launcher restore' undoes it)" ;;
    restore)
      [ -f "$LAUNCHER_STATE" ] || die "no original launcher saved yet"
      local prev; prev="$(head -n1 "$LAUNCHER_STATE")"; [[ "$prev" =~ ^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$ ]] || die "saved launcher entry looks wrong: $prev"
      adbtv shell cmd package set-home-activity --user 0 "$prev" >/dev/null; adbtv shell input keyevent 3
      info "restored launcher: $prev" ;;
    *) die "usage: tv.sh launcher list|current|install <apk>|set <package>|restore" ;;
  esac
}

cmd_animations() {
  local v
  case "${1:-}" in
    fast) v=0.5 ;; off) v=0 ;; default) v=1 ;;
    show) local k; for k in window_animation_scale transition_animation_scale animator_duration_scale; do printf '%s=%s\n' "$k" "$(adbtv shell settings get global "$k" | tr -d '\r')"; done; return 0 ;;
    *) die "usage: tv.sh animations fast|off|default|show" ;;
  esac
  local k; for k in window_animation_scale transition_animation_scale animator_duration_scale; do adbtv shell settings put global "$k" "$v"; done
  info "animation scale set to ${v}x"
}

cmd_debloat() {
  local sub="${1:-}"; [ $# -gt 0 ] && shift
  case "$sub" in
    list)     adbtv shell pm list packages -s -e | tr -d '\r' | sed 's/^package://' | sort ;;
    disabled) adbtv shell pm list packages -d | tr -d '\r' | sed 's/^package://' | sort ;;
    disable)
      [ $# -ge 1 ] || die "usage: tv.sh debloat disable <package>..."
      local p; for p in "$@"; do
        valid_pkg "$p" || { warn "skipped (bad package name): $p"; continue; }
        protected_pkg "$p" && { warn "skipped (protected core/launcher package): $p"; continue; }
        adbtv shell pm disable-user --user 0 "$p" && info "disabled $p (undo: debloat enable $p)"
      done ;;
    enable)
      [ $# -ge 1 ] || die "usage: tv.sh debloat enable <package>..."
      local p; for p in "$@"; do valid_pkg "$p" || { warn "skipped (bad package name): $p"; continue; }; adbtv shell pm enable "$p"; done ;;
    *) die "usage: tv.sh debloat list|disabled|disable <package>...|enable <package>..." ;;
  esac
}

main() {
  local c="${1:-}"; [ $# -gt 0 ] && shift
  case "$c" in ""|-h|--help|help) usage; return 0 ;; esac
  need_adb
  case "$c" in
    connect)    cmd_connect "$@" ;;
    pair)       [ $# -eq 2 ] || die "usage: tv.sh pair <ip:port> <code>"; valid_addr "$1" || die "bad address: $1"; adb pair "$1" "$2" ;;
    status)     adb devices; adbtv shell getprop ro.product.model ;;
    disconnect) adb disconnect "$(addr)" ;;
    home) key 3 ;; back) key 4 ;; up) key 19 ;; down) key 20 ;; left) key 21 ;; right) key 22 ;;
    ok) key 23 ;; menu) key 82 ;; play) key 126 ;; pause) key 127 ;;
    vol-up) key 24 ;; vol-down) key 25 ;; mute) key 164 ;; power) key 26 ;;
    text)       [ $# -ge 1 ] || die "usage: tv.sh text <string>"; local t="$*"; t="${t// /%s}"; adbtv shell input text "$t" ;;
    open)       [ $# -eq 1 ] || die "usage: tv.sh open <package>"; [[ "$1" =~ ^[A-Za-z0-9._]+$ ]] || die "bad package name"
                adbtv shell monkey -p "$1" -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null ;;
    apps)       adbtv shell pm list packages -3 | sed 's/^package://' ;;
    install)    [ $# -eq 1 ] && [ -f "$1" ] || die "usage: tv.sh install <file.apk>"; adbtv install -r "$1" ;;
    shell)      adbtv shell "$@" ;;
    launcher)   cmd_launcher "$@" ;;
    animations) cmd_animations "$@" ;;
    debloat)    cmd_debloat "$@" ;;
    *)          usage; die "unknown command: $c" ;;
  esac
}
main "$@"
