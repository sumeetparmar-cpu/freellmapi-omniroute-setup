#!/usr/bin/env bash
# termux/tv.sh against a fake adb: checks the exact adb calls, input validation and the protected-package refusal. No device, no network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; PASS=0; FAIL=0; cleanup() { rm -rf "$TMP"; echo "tv: passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1; }
trap cleanup EXIT
ck() { local n="$1"; shift; if "$@" >"$TMP/out" 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; sed 's/^/       /' "$TMP/out" | tail -6; fi; }
export HOME="$TMP/home"; unset XDG_CONFIG_HOME TV_CONFIG TV_LAUNCHER_STATE; mkdir -p "$HOME" "$TMP/bin"; export PATH="$TMP/bin:$PATH" LOG="$TMP/adb.log"
cat > "$TMP/bin/adb" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$LOG"
case "$*" in
  *"query-activities"*)  printf 'priority=0 ...\r\ncom.google.android.tvlauncher/.MainActivity\r\ncom.fake.launcher/.Home\r\n' ;;
  *"resolve-activity"*)  printf 'priority=0 ...\r\ncom.google.android.tvlauncher/.MainActivity\r\n' ;;
  *"settings get"*)      echo 1.0 ;;
  *"connect"*)           echo "connected to $2" ;;
  *"get-state"*)         echo device ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/adb"
TV="$ROOT/termux/tv.sh"; export TV_ADDR=10.0.0.5:5555
run() { : > "$LOG"; bash "$TV" "$@"; }
ck "connect saves the address (0600)"       bash -c "TV_ADDR= bash '$TV' connect 10.0.0.9 && test \"\$(cat '$HOME/.config/tv-addr')\" = 10.0.0.9:5555 && test \$(stat -c %a '$HOME/.config/tv-addr') = 600"
ck "connect rejects shell metacharacters"   bash -c "! bash '$TV' connect 'a;b'"
ck "animations fast sets 3 scales to 0.5"   bash -c "$(declare -f run); LOG='$LOG'; TV='$TV'; run animations fast && test \$(grep -c 'put global .*_scale 0.5\|duration_scale 0.5' '$LOG') = 3"
ck "animations bogus mode refused"          bash -c "! bash '$TV' animations warp"
ck "debloat disable uses pm disable-user"   bash -c ": > '$LOG'; bash '$TV' debloat disable com.example.bloat && grep -q 'pm disable-user --user 0 com.example.bloat' '$LOG'"
ck "debloat refuses core package"           bash -c ": > '$LOG'; bash '$TV' debloat disable com.android.systemui com.google.android.gms; ! grep -q disable-user '$LOG'"
ck "debloat refuses the active launcher"    bash -c ": > '$LOG'; bash '$TV' debloat disable com.google.android.tvlauncher; ! grep -q disable-user '$LOG'"
ck "debloat refuses bad package name"       bash -c ": > '$LOG'; bash '$TV' debloat disable 'x;reboot'; ! grep -q disable-user '$LOG'"
ck "debloat enable uses pm enable"          bash -c ": > '$LOG'; bash '$TV' debloat enable com.example.bloat && grep -q 'pm enable com.example.bloat' '$LOG'"
ck "launcher set saves original and sets"   bash -c ": > '$LOG'; bash '$TV' launcher set com.fake.launcher && grep -q 'set-home-activity --user 0 com.fake.launcher/.Home' '$LOG' && grep -q 'com.google.android.tvlauncher/.MainActivity' '$HOME/.config/tv-launcher-prev'"
ck "launcher restore reinstates original"   bash -c ": > '$LOG'; bash '$TV' launcher restore && grep -q 'set-home-activity --user 0 com.google.android.tvlauncher/.MainActivity' '$LOG'"
ck "launcher set unknown package refused"   bash -c "! bash '$TV' launcher set com.not.installed"
