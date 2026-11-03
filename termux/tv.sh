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
# Uses the saved address, or TV_ADDR=ip:port. Talks only to the TV on your LAN.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
TV_CONFIG="${TV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/tv-addr}"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
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
    *)          usage; die "unknown command: $c" ;;
  esac
}
main "$@"
