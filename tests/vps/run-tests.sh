#!/usr/bin/env bash
# Tests for the VPS toolkit.
#
#   bash tests/vps/run-tests.sh                                   # part A only: no privileges, no system changes
#   sudo LLM_TEST_ALLOW_SYSTEM_CHANGES=1 bash tests/vps/run-tests.sh   # parts A + B
#
# Part B makes REAL system changes (creates two throw-away users "llmtfree"/"llmtomni" and /srv/llmtest-PID, then removes them).
# It is meant for CI runners and disposable sandboxes. It refuses to run unless LLM_TEST_ALLOW_SYSTEM_CHANGES=1 AND root,
# so it cannot be started by accident on a production VPS. It never runs Docker/Caddy/n8n commands.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; PIDS=()
BIN="$TMP/bin"; mkdir -p "$BIN"
PASS=0; FAIL=0
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  if [ -n "${B_ROOT:-}" ]; then
    getent passwd llmtfree >/dev/null && userdel llmtfree 2>/dev/null; getent passwd llmtomni >/dev/null && userdel llmtomni 2>/dev/null
    case "$B_ROOT" in /srv/llmtest-*) rm -rf -- "$B_ROOT";; esac
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT
t()  { local n="$1"; shift; if ( "$@" ) >"$TMP/out" 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; sed 's/^/       /' "$TMP/out" | tail -15; fi; }
tn() { local n="$1"; shift; if ( "$@" ) >"$TMP/out" 2>&1; then FAIL=$((FAIL+1)); echo "FAIL - $n (expected failure)"; sed 's/^/       /' "$TMP/out" | tail -8; else PASS=$((PASS+1)); echo "ok   - $n"; fi; }
has() { grep -qE -- "$1" "$TMP/out"; }              # has REGEX  (searches the last t/tn output)
out_has() { local re="$1"; shift; "$@" 2>&1 | grep -qE -- "$re"; }

# ---- shims for tools that must not be the real thing in tests --------------------------------------
cat > "$BIN/docker" <<'SH'
#!/bin/sh
case "$1 $2" in
  "ps -a") if [ "$3" = "--format" ]; then case "$4" in *Status*) cat "$DOCKER_PS_PF";; *) cat "$DOCKER_PS";; esac; fi; exit 0 ;;
  "volume ls") cat "$DOCKER_VOLS" ;;
  "volume inspect") echo "docker-volume|$5|mount=/var/lib/docker/volumes/$5/_data driver=local created=2026-01-01" ;;
  "network ls") cat "$DOCKER_NETS" ;;
esac
SH
cat > "$BIN/systemctl" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "systemd 255 (255.4-1ubuntu8)" ;;
  list-unit-files) cat "$UNITS_FILE" ;;
  list-units) : ;;
  is-active) echo active ;;
esac
exit 0
SH
chmod +x "$BIN/docker" "$BIN/systemctl"
printf 'docker-container|n8n|id=aaa image=n8nio/n8n created=2026-01-01\ndocker-container|suppar|id=bbb image=suppar:1 created=2026-01-02\n' > "$TMP/ps"
printf 'n8n|n8nio/n8n|Up 3 days|127.0.0.1:5678->5678/tcp\nsuppar|suppar:1|Up 2 days|127.0.0.1:4000->4000/tcp\n' > "$TMP/ps_pf"
printf 'n8n_data\nsuppar_db\n' > "$TMP/vols"; printf 'bridge\nn8n_default\n' > "$TMP/nets"
printf 'docker.service enabled\ncaddy.service enabled\nn8n.service enabled\n' > "$TMP/units"
printf '0.0.0.0\t80\tcaddy\n0.0.0.0\t443\tcaddy\n127.0.0.1\t5678\tnode\n127.0.0.1\t4000\tsuppar\n' > "$TMP/listen"
export DOCKER_PS="$TMP/ps" DOCKER_PS_PF="$TMP/ps_pf" DOCKER_VOLS="$TMP/vols" DOCKER_NETS="$TMP/nets" UNITS_FILE="$TMP/units"
printf 'ID=ubuntu\nVERSION_ID="26.04"\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' > "$TMP/os26"
printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$TMP/os24"
printf 'MemTotal: 8388608 kB\nMemAvailable: 6291456 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$TMP/mem_big"
printf 'MemTotal: 524288 kB\nMemAvailable: 100000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$TMP/mem_small"
mkdir -p "$TMP/fake-sd"          # stands in for /run/systemd/system
export ROOT TMP BIN
HN="$(hostname)"; export HN
# Helper functions: each runs a toolkit script with a controlled environment. Extra VAR=value args come LAST so they override.
pf()  { env PATH="$BIN:$PATH" OS_RELEASE="$TMP/os26" MEMINFO_FILE="$TMP/mem_big" SYSTEMD_RUN_DIR="$TMP/fake-sd" LISTENERS_FILE="$TMP/listen" LLM_ROOT="$TMP/nonexistent/llm" LLM_USER_FREELLMAPI=llmxfree LLM_USER_OMNIROUTE=llmxomni "$@"; }
inv() { env PATH="$BIN:$PATH" SYSTEMD_RUN_DIR="$TMP/fake-sd" LISTENERS_FILE="$TMP/listen" LLM_USER_FREELLMAPI=llmxfree LLM_USER_OMNIROUTE=llmxomni "$@"; }
dp()  { env PATH="$BIN:$PATH" LLM_ROOT="$TMP/llm-dry" LLM_USER_FREELLMAPI=llmxfree LLM_USER_OMNIROUTE=llmxomni SYSTEMD_RUN_DIR="$TMP/fake-sd" LISTENERS_FILE="$TMP/listen" "$@"; }
mon() { env PATH="$BIN:$PATH" LLM_ROOT="$TMP/llm-mon" SYSTEMD_RUN_DIR=/nonexistent/x "$@"; }
gc()  { env PATH="$BIN:$PATH" LLM_ROOT="$TMP/llm-gc" SYSTEMD_RUN_DIR=/nonexistent/x "$@"; }
export -f pf inv dp mon gc
# shellcheck source=../../vps/lib/vps-common.sh
. "$ROOT/vps/lib/vps-common.sh"; set +e

echo "# library"
t  "assert_safe_root accepts /srv/llm"           bash -c ". '$ROOT/vps/lib/vps-common.sh'; LLM_ROOT=/srv/llm assert_safe_root"
for bad in / /etc /srv /usr/local /var/lib/docker /root/x relative/path /x /home /opt /tmp; do
  tn "assert_safe_root rejects '$bad'"            bash -c ". '$ROOT/vps/lib/vps-common.sh'; LLM_ROOT='$bad' assert_safe_root"
done
t  "os_field reads quoted values"                env OS_RELEASE="$TMP/os26" bash -c ". '$ROOT/vps/lib/vps-common.sh'; [ \"\$(os_field VERSION_ID)\" = 26.04 ]"
t  "node_arch maps this machine"                 bash -c ". '$ROOT/vps/lib/vps-common.sh'; node_arch"
t  "port_listening reads canned listeners"       env LISTENERS_FILE="$TMP/listen" bash -c ". '$ROOT/vps/lib/vps-common.sh'; port_listening 5678 && ! port_listening 3001"
t  "pick_free_port skips busy and excluded"      env LISTENERS_FILE="$TMP/listen" EXCLUDE_PORTS="13101" bash -c ". '$ROOT/vps/lib/vps-common.sh'; [ \"\$(pick_free_port 4000 '13001 13101 23001')\" = 13001 ]"
node -e 'require("net").createServer().listen(0,"127.0.0.1",function(){console.log(this.address().port)})' > "$TMP/lp" & PIDS+=("$!")
for _ in $(seq 50); do [ -s "$TMP/lp" ] && break; sleep 0.1; done
t  "listeners() sees a real loopback socket (ss or /proc fallback)" bash -c ". '$ROOT/vps/lib/vps-common.sh'; listeners | awk -F'\t' -v p=\"\$(cat $TMP/lp)\" '\$2==p&&\$1==\"127.0.0.1\"{f=1} END{exit !f}'"
t  "act is a dry run unless APPLY=1"             bash -c ". '$ROOT/vps/lib/vps-common.sh'; APPLY=0 act why touch '$TMP/dry' 2>/dev/null; [ ! -e '$TMP/dry' ]"
t  "act executes with APPLY=1"                   bash -c ". '$ROOT/vps/lib/vps-common.sh'; APPLY=1 act why touch '$TMP/wet' 2>/dev/null; [ -e '$TMP/wet' ]"
tn "act ABORTS the whole run when a step fails"  bash -c ". '$ROOT/vps/lib/vps-common.sh'; APPLY=1; act first false 2>/dev/null; touch '$TMP/after-failure'"
t  "...so nothing runs after the failed step"    test ! -e "$TMP/after-failure"

echo "# preflight (read-only)"
t  "all-green host passes and reports Ubuntu 26.04 target" bash -c 'pf "$ROOT/vps/preflight.sh" --offline > "$TMP/pf1"; grep -q "RESULT: PASS" "$TMP/pf1" && grep -q "Ubuntu 26.04 (target OS)" "$TMP/pf1"'
t  "Ubuntu 24.04 gives a warning, not a block"   bash -c 'pf OS_RELEASE="$TMP/os24" "$ROOT/vps/preflight.sh" --offline | grep -E "WARN.*not Ubuntu 26.04" >/dev/null'
tn "preflight blocks when systemd is not running" pf SYSTEMD_RUN_DIR=/nonexistent/x "$ROOT/vps/preflight.sh" --offline
t  "...and says why"                              bash -c 'pf SYSTEMD_RUN_DIR=/nonexistent/x "$ROOT/vps/preflight.sh" --offline | grep -q "BLOCK.*systemd"'
tn "preflight blocks on tiny RAM"                 pf MEMINFO_FILE="$TMP/mem_small" "$ROOT/vps/preflight.sh" --offline
tn "preflight blocks on insufficient disk"        pf MIN_DISK_GB=99999999 WARN_DISK_GB=99999999 "$ROOT/vps/preflight.sh" --offline
printf '127.0.0.1\t3001\tsomething\n' > "$TMP/listen_busy"
tn "preflight blocks when the default port is taken" pf LISTENERS_FILE="$TMP/listen_busy" "$ROOT/vps/preflight.sh" --offline
t  "...and proposes a free alternative"           bash -c 'pf LISTENERS_FILE="$TMP/listen_busy" "$ROOT/vps/preflight.sh" --offline | grep -E "port 3001 for freellmapi.*proposal: use 13001" >/dev/null'
tn "preflight blocks identical ports"             pf "$ROOT/vps/preflight.sh" --offline --freellmapi-port 4500 --omniroute-port 4500
tn "preflight blocks an unsafe LLM_ROOT"          pf LLM_ROOT=/etc "$ROOT/vps/preflight.sh" --offline
t  "--out writes a 0600 report with a RESULT line" bash -c 'pf "$ROOT/vps/preflight.sh" --offline --out "$TMP/pf.out" >/dev/null; [ "$(stat -c %a "$TMP/pf.out")" = 600 ] && grep -q "^RESULT: PASS" "$TMP/pf.out"'
t  "detects n8n/suppar containers by name (read-only)" bash -c 'n=$(pf "$ROOT/vps/preflight.sh" --offline | grep -cE "container (n8n|suppar)"); [ "$n" = 2 ]'
t  "preflight makes no changes (no files appear)"  bash -c 'pf "$ROOT/vps/preflight.sh" --offline >/dev/null; [ ! -e "$TMP/nonexistent" ]'

echo "# inventory (read-only integrity)"
printf 'Caddyfile original\n' > "$TMP/Caddyfile"; mkdir -p "$TMP/n8ndata"
inv "$ROOT/vps/inventory.sh" snapshot --out "$TMP/base.snap" --hash "$TMP/Caddyfile" --watch "$TMP/n8ndata" >/dev/null 2>&1
t  "snapshot is 0600 and records containers/volumes/hash" bash -c '[ "$(stat -c %a "$TMP/base.snap")" = 600 ] && grep -q "docker-container|n8n" "$TMP/base.snap" && grep -q "docker-volume|n8n_data" "$TMP/base.snap" && grep -q "hash|$TMP/Caddyfile|" "$TMP/base.snap"'
t  "snapshot holds no secrets (canary env var absent)" bash -c '! inv CANARY_SECRET=ZZ-SECRET-ZZ "$ROOT/vps/inventory.sh" snapshot 2>/dev/null | grep -q ZZ-SECRET-ZZ'
t  "unchanged host compares clean"                inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap"
cp "$TMP/ps" "$TMP/ps.bak"; echo 'docker-container|intruder|id=ccc image=x created=2026-02-01' >> "$TMP/ps"
tn "a new/changed container is detected (exit 1)" inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap"
t  "...and named in the output"                   bash -c 'inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap" 2>&1 | grep -q "ADDED: docker-container|intruder"'
cp "$TMP/ps.bak" "$TMP/ps"
echo "Caddyfile TAMPERED" > "$TMP/Caddyfile"
tn "a changed Caddyfile hash is detected"         inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap"
echo "Caddyfile original" > "$TMP/Caddyfile"
t  "restoring the file makes it clean again"      inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap"
echo 'caddy-new.service enabled' >> "$TMP/units"
tn "a new systemd unit file is detected"          inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap"
sed -i '/caddy-new/d' "$TMP/units"
echo 'llm-freellmapi.service enabled' >> "$TMP/units"
t  "our own llm-* units are ignored"              inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap"
sed -i '/llm-freellmapi/d' "$TMP/units"
printf '0.0.0.0\t9999\tsurprise\n' >> "$TMP/listen"
t  "a new listener is a WARNING..."               bash -c 'inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap" 2>&1 | grep -q "listener ADDED"'
t  "...with exit status 0 (not a failure)"        inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap"
sed -i '/9999/d' "$TMP/listen"
rmdir "$TMP/n8ndata"
tn "a watched path that disappears is detected"   inv "$ROOT/vps/inventory.sh" compare "$TMP/base.snap"
mkdir -p "$TMP/n8ndata"

echo "# static safety scan of the committed scripts (claims in docs/VPS-DEPLOYMENT.md)"
code_lines() { # code_lines FILES... : code text only (comments and user-facing message lines removed, "file:N:" prefix stripped)
  grep -nHE '.' "$@" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '(\b(die|warn|err|info|emit|block|pass|warn_|info_|printf|echo|ok)\b[ (]|^[^:]+:[0-9]+:[[:space:]]*(info_|warn_|block|pass|emit)|effect:|WOULD)' | sed -E 's/^[^:]+:[0-9]+://'
}
FORBID='sudo|apt|apt-get|dpkg|snap|ufw|iptables|ip6tables|nft|crontab|usermod|groupadd|visudo|caddy'
# shellcheck disable=SC2089,SC2090  # the regex deliberately contains literal quote characters
ANYCMD="(^|[;&|(]|&& )[[:space:]]*($FORBID)[[:space:]]|act[[:space:]]+(\"[^\"]*\"|[^[:space:]]+)[[:space:]]+($FORBID)[[:space:]]"
# shellcheck disable=SC2090
export FORBID ANYCMD
t  "vps scripts never invoke apt/dpkg/snap/sudo/ufw/iptables/nft/crontab/usermod/groupadd/visudo/caddy" bash -c "cd '$ROOT'; $(declare -f code_lines); ! code_lines vps/*.sh vps/lib/*.sh | grep -E \"\$ANYCMD\""
t  "the only docker subcommands used are read-only (ps, volume ls/inspect, network ls)" bash -c "cd '$ROOT'; $(declare -f code_lines); ! code_lines vps/*.sh vps/lib/*.sh | grep -E '(^|[;&|(]|&& )[[:space:]]*docker[[:space:]]+[a-z]' | grep -vE 'docker (ps|volume (ls|inspect)|network ls)'"
printf 'apt-get install x\ndocker rm -f n8n\nact "open ssh" ufw allow 22\nx && sudo reboot\n' > "$TMP/bad.sh"
t  "the scan itself works: it flags planted apt-get / sudo / act-wrapped ufw lines" bash -c "$(declare -f code_lines); [ \"\$(code_lines '$TMP/bad.sh' | grep -cE \"\$ANYCMD\")\" = 3 ] && [ \"\$(code_lines '$TMP/bad.sh' | grep -E '(^|[;&|(]|&& )[[:space:]]*docker[[:space:]]+[a-z]' | grep -vE 'docker (ps|volume (ls|inspect)|network ls)' | wc -l)\" = 1 ]"
t  "no vps script writes under /etc except the two unit files and timer templates" bash -c "cd '$ROOT'; ! { $(declare -f code_lines); code_lines vps/*.sh vps/lib/*.sh; } | grep -E '>[[:space:]]*/etc/|/etc/(ssh|sudoers|caddy|cron|docker)[^ ]*[[:space:]]*(&&|;|\\|)' | grep -vE 'hash|DEFAULT_HASH|for f in|\\[ -[ef]|sha256sum|\\.caddy|authorized_keys|sshd_config|daemon.json'"
t  "no recursive delete outside LLM_ROOT-scoped paths"   bash -c "cd '$ROOT'; ! { $(declare -f code_lines); code_lines vps/*.sh; } | grep -E 'rm -rf' | grep -vE 'LLM_ROOT|NODE_TMP|\\\$td|\\\$h\\\"|stage|\\\$tmp'"
t  "service users never get sudo/docker (deploy.sh passes no -G/--groups to useradd)" bash -c "cd '$ROOT'; ! grep -nE 'useradd[^#]*(-G|--groups|-g )' vps/deploy.sh"

echo "# unit templates"
for gw in freellmapi omniroute; do
  u="llmxfree"; [ $gw = omniroute ] && u="llmxomni"
  sed -e "s|@LLM_ROOT@|/srv/llm|g" -e "s|@USER@|$u|g" -e "s|@PORT@|3001|g" -e "s|@GW@|$gw|g" -e "s|@MEM_MAX@|1G|g" "$ROOT/vps/systemd/llm-$gw.service" > "$TMP/$gw.unit"
  t  "$gw unit: placeholders all replaced"        bash -c "! grep -q '@[A-Z_]*@' '$TMP/$gw.unit'"
  t  "$gw unit: unprivileged user, own dir only"  bash -c "grep -q '^User=$u\$' '$TMP/$gw.unit' && [ \"\$(grep -c '^ReadWritePaths=' '$TMP/$gw.unit')\" = 1 ] && grep -q '^ReadWritePaths=/srv/llm/$gw\$' '$TMP/$gw.unit'"
  t  "$gw unit: sandbox directives present"       bash -c "for d in NoNewPrivileges=yes ProtectSystem=strict ProtectHome=yes PrivateTmp=yes PrivateDevices=yes CapabilityBoundingSet= RestrictSUIDSGID=yes KillMode=control-group 'MemoryMax=1G' 'CPUQuota=80%'; do grep -q \"^\$d\" '$TMP/$gw.unit' || { echo missing \$d; exit 1; }; done"
  t  "$gw unit: no network exposure or secrets"   bash -c "! grep -qiE '0\.0\.0\.0|password|secret=|api_key|token=' '$TMP/$gw.unit'"
done
t  "units reference only their own gateway"       bash -c "! grep -q omniroute '$TMP/freellmapi.unit' && ! grep -q freellmapi '$TMP/omniroute.unit'"
for f in llm-backup@.service llm-backup@.timer llm-monitor.service llm-monitor.timer; do t "template $f exists, only @LLM_ROOT@ left to fill" bash -c "[ -f '$ROOT/vps/systemd/$f' ] && ! grep -o '@[A-Z_]*@' '$ROOT/vps/systemd/$f' | grep -v '@LLM_ROOT@'"; done

echo "# deploy.sh gates and dry-run"
printf 'VPS preflight (read-only)  host=%s  time=now\nRESULT: PASS\n' "$HN" > "$TMP/pf_ok"
printf 'VPS preflight (read-only)  host=%s  time=now\nRESULT: BLOCKED\n' "$HN" > "$TMP/pf_blocked"
printf 'VPS preflight (read-only)  host=otherhost  time=now\nRESULT: PASS\n' > "$TMP/pf_other"
printf 'VPS preflight (read-only)  host=%s  time=old\nRESULT: PASS\n' "$HN" > "$TMP/pf_old"; touch -d '3 days ago' "$TMP/pf_old"
{ echo "snapshot|taken|x host=$HN"; echo "opt|root|0"; } > "$TMP/baseline_ok"; echo "snapshot|taken|x host=other" > "$TMP/baseline_other"
tn "users refuses without gate files"             dp "$ROOT/vps/deploy.sh" users
tn "users refuses a BLOCKED preflight"            dp "$ROOT/vps/deploy.sh" users --preflight "$TMP/pf_blocked" --baseline "$TMP/baseline_ok"
tn "users refuses a preflight from another host"  dp "$ROOT/vps/deploy.sh" users --preflight "$TMP/pf_other" --baseline "$TMP/baseline_ok"
tn "users refuses a stale (>24h) preflight"       dp "$ROOT/vps/deploy.sh" users --preflight "$TMP/pf_old" --baseline "$TMP/baseline_ok"
tn "users refuses a baseline from another host"   dp "$ROOT/vps/deploy.sh" users --preflight "$TMP/pf_ok" --baseline "$TMP/baseline_other"
t  "users dry-run with valid gates prints useradd and changes nothing" bash -c 'dp "$ROOT/vps/deploy.sh" users --preflight "$TMP/pf_ok" --baseline "$TMP/baseline_ok" 2>&1 | grep -q "WOULD RUN useradd" && ! getent passwd llmxfree'
if [ "$(id -u)" != 0 ]; then tn "--apply needs root (non-root run refuses)" dp "$ROOT/vps/deploy.sh" --apply dirs; fi
t  "dirs dry-run creates nothing"                 bash -c 'dp "$ROOT/vps/deploy.sh" dirs 2>&1 | grep -q "WOULD RUN install -d" && [ ! -e "$TMP/llm-dry" ]'
t  "runtime dry-run names the pinned SHA check"   bash -c 'dp "$ROOT/vps/deploy.sh" runtime 2>&1 | grep -q "SHA-256 equals the value pinned"'
tn "enable refuses without a baseline"            dp "$ROOT/vps/deploy.sh" enable freellmapi
tn "enable refuses an unknown gateway"            dp "$ROOT/vps/deploy.sh" enable apache --baseline "$TMP/baseline_ok"
tn "remove --purge refuses without --yes-delete-data" dp "$ROOT/vps/deploy.sh" remove freellmapi --purge
tn "unsafe --root is rejected"                    dp "$ROOT/vps/deploy.sh" --root /etc status
tn "config refuses identical ports"               dp "$ROOT/vps/deploy.sh" config --freellmapi-port 4500 --omniroute-port 4500
printf '127.0.0.1\t4501\tx\n' > "$TMP/l2"
tn "config refuses a port that is already in use" dp LISTENERS_FILE="$TMP/l2" "$ROOT/vps/deploy.sh" config --freellmapi-port 4501 --omniroute-port 4502

echo "# backup-run pruning (no privileges)"
L="$TMP/llm-bk"; D="$L/freellmapi/backups/freellmapi"; mkdir -p "$D"
printf '#!/bin/sh\n# fake gwctl: pretend to create a scheduled backup\ntouch "%s/20991231T000000Z-scheduled.tar.gz"\n' "$D" > "$TMP/fake-gwctl"; chmod +x "$TMP/fake-gwctl"
for i in 1 2 3 4 5; do touch -d "$((i*10)) days ago" "$D/2026010${i}T000000Z-scheduled.tar.gz"; done
touch -d '90 days ago' "$D/20250101T000000Z-manual.tar.gz" "$D/20250101T000000Z-pre-update.tar.gz"
t  "backup-run prunes old scheduled backups only"  bash -c "LLM_ROOT='$L' GWCTL='$TMP/fake-gwctl' '$ROOT/vps/backup-run.sh' freellmapi --keep 2 --keep-days 15 >/dev/null 2>&1; [ -f '$D/20250101T000000Z-manual.tar.gz' ] && [ -f '$D/20250101T000000Z-pre-update.tar.gz' ] && [ -f '$D/20991231T000000Z-scheduled.tar.gz' ] && [ \"\$(ls '$D'/*-scheduled.tar.gz | wc -l)\" = 2 ]"
t  "...keeps the newest N and anything within D days" bash -c "[ -f '$D/20260101T000000Z-scheduled.tar.gz' ] && [ -f '$D/20991231T000000Z-scheduled.tar.gz' ]"
tn "backup-run rejects non-numeric retention"      env LLM_ROOT="$L" GWCTL="$TMP/fake-gwctl" "$ROOT/vps/backup-run.sh" freellmapi --keep abc
printf '#!/bin/sh\nexit 1\n' > "$TMP/bad-gwctl"; chmod +x "$TMP/bad-gwctl"; touch -d '99 days ago' "$D/20240101T000000Z-scheduled.tar.gz"
tn "backup-run fails when the backup fails"        env LLM_ROOT="$L" GWCTL="$TMP/bad-gwctl" "$ROOT/vps/backup-run.sh" freellmapi --keep 1 --keep-days 1
t  "...and prunes nothing in that case"            test -f "$D/20240101T000000Z-scheduled.tar.gz"

echo "# monitor (read-only; against mock status endpoints)"
start_mock() { node "$ROOT/tests/quota/mock-gateways.mjs" "$1" ok "$2" >/dev/null 2>&1 & PIDS+=("$!"); for _ in $(seq 40); do [ "$(http_code "http://127.0.0.1:$2/$3")" = 200 ] && return 0; sleep 0.2; done; return 1; }
MROOT="$TMP/llm-mon"; mkdir -p "$MROOT"; printf 'PORT_FREELLMAPI=18411\nPORT_OMNIROUTE=18412\n' > "$MROOT/deploy.conf"
start_mock freellmapi 18411 api/ping; start_mock omniroute 18412 api/health/ping
t  "monitor: healthy gateways -> OVERALL OK, exit 0" bash -c 'mon "$ROOT/vps/monitor.sh" check | grep -q "OVERALL: OK"'
t  "monitor: reports each gateway's health"         bash -c 'o=$(mon "$ROOT/vps/monitor.sh" check); echo "$o" | grep -qE "freellmapi.health +HTTP 200" && echo "$o" | grep -qE "omniroute.health +HTTP 200"'
t  "monitor --json is valid JSON with a status"      bash -c 'mon "$ROOT/vps/monitor.sh" check --json | node -e "const d=JSON.parse(require(\"fs\").readFileSync(0));process.exit(d.status===\"OK\"&&d.checks.length>4?0:1)"'
t  "monitor --log appends a line (0600)"             bash -c 'mon "$ROOT/vps/monitor.sh" check --log "$TMP/mon.log" >/dev/null; [ -s "$TMP/mon.log" ] && [ "$(stat -c %a "$TMP/mon.log")" = 600 ]'
t  "monitor: low-disk threshold -> WARN, exit 1"     bash -c 'mon MON_DISK_WARN_GB=99999999 MON_DISK_CRIT_GB=1 "$ROOT/vps/monitor.sh" check >/dev/null; [ $? = 1 ]'
t  "monitor: low-memory threshold -> CRIT, exit 2"   bash -c 'mon MON_AVAIL_CRIT_MB=99999999 "$ROOT/vps/monitor.sh" check >/dev/null; [ $? = 2 ]'
printf 'PORT_FREELLMAPI=18411\nPORT_OMNIROUTE=18499\n' > "$MROOT/deploy.conf"
t  "monitor: a dead gateway -> CRIT, exit 2"         bash -c 'mon "$ROOT/vps/monitor.sh" check | grep -qE "CRIT +omniroute.health"; mon "$ROOT/vps/monitor.sh" check >/dev/null; [ $? = 2 ]'
tn "monitor rejects unknown subcommands"             mon "$ROOT/vps/monitor.sh" explode

echo "# gwctl safety (no privileges needed)"
mkdir -p "$TMP/llm-gc/freellmapi/backups/freellmapi"; : > "$TMP/llm-gc/freellmapi/backups/freellmapi/a.tar.gz"
tn "gwctl rejects unknown gateways"                  gc "$ROOT/vps/gwctl.sh" apache status
tn "gwctl export-backup refuses unencrypted export"  gc "$ROOT/vps/gwctl.sh" freellmapi export-backup "$TMP/llm-gc/freellmapi/backups/freellmapi/a.tar.gz" "$TMP/out.bin"
t  "...and says why"                                 bash -c 'gc "$ROOT/vps/gwctl.sh" freellmapi export-backup "$TMP/llm-gc/freellmapi/backups/freellmapi/a.tar.gz" "$TMP/out.bin" 2>&1 | grep -q "refusing to export unencrypted"'
: > "$TMP/x.tar.gz"
tn "gwctl export-backup refuses archives outside backups/" gc "$ROOT/vps/gwctl.sh" freellmapi export-backup "$TMP/x.tar.gz" "$TMP/o2" --gpg-recipient a

# =====================================================================================================
if [ "$(id -u)" = 0 ] && [ "${LLM_TEST_ALLOW_SYSTEM_CHANGES:-}" = 1 ]; then
echo "# PART B: real system changes (disposable machine only)"
B_ROOT="/srv/llmtest-$$"
UF=llmtfree; UO=llmtomni
DIST="$TMP/dist"; ARCH="$(node_arch)"; mkdir -p "$DIST/v9.9.9/stage/node-v9.9.9-linux-$ARCH/bin"
printf '#!/bin/sh\necho v9.9.9\n' > "$DIST/v9.9.9/stage/node-v9.9.9-linux-$ARCH/bin/node"; chmod +x "$DIST/v9.9.9/stage/node-v9.9.9-linux-$ARCH/bin/node"
tar -C "$DIST/v9.9.9/stage" -czf "$DIST/v9.9.9/node-v9.9.9-linux-$ARCH.tar.gz" "node-v9.9.9-linux-$ARCH"
FSHA="$(sha256sum "$DIST/v9.9.9/node-v9.9.9-linux-$ARCH.tar.gz" | cut -d' ' -f1)"
BENV=(env PATH="$BIN:$PATH" LLM_ROOT="$B_ROOT" LLM_USER_FREELLMAPI="$UF" LLM_USER_OMNIROUTE="$UO" SYSTEMD_DIR="$TMP/unitdir" SYSTEMD_RUN_DIR=/nonexistent/x
      NODE_VERSION=9.9.9 NODE_DIST_URL="file://$DIST" NODE_SHA256_x64="$FSHA" NODE_SHA256_arm64="$FSHA")
mkdir -p "$TMP/unitdir"
"${BENV[@]}" "$ROOT/vps/inventory.sh" snapshot --out "$TMP/b.base" >/dev/null 2>&1
printf 'VPS preflight (read-only)  host=%s  time=now\nRESULT: PASS\n' "$HN" > "$TMP/b.pf"
DEPLOY=("${BENV[@]}" "$ROOT/vps/deploy.sh" --apply)
t  "apply users"                                   "${DEPLOY[@]}" users --preflight "$TMP/b.pf" --baseline "$TMP/b.base"
t  "service users are system accounts without login" bash -c "for u in $UF $UO; do getent passwd \$u | grep -q ':/usr/sbin/nologin\$' || exit 1; [ \$(id -u \$u) -lt 1000 ] || exit 1; done"
t  "service users are in no group but their own"   bash -c "[ \"\$(id -nG $UF)\" = $UF ] && [ \"\$(id -nG $UO)\" = $UO ]"
t  "apply users again is idempotent"               "${DEPLOY[@]}" users --preflight "$TMP/b.pf" --baseline "$TMP/b.base"
t  "apply dirs"                                    "${DEPLOY[@]}" dirs
t  "gateway homes are 0700 and owned by their user" bash -c "[ \"\$(stat -c '%a %U' $B_ROOT/freellmapi)\" = '700 $UF' ] && [ \"\$(stat -c '%a %U' $B_ROOT/omniroute)\" = '700 $UO' ]"
t  "apply runtime (checksum-verified fake Node)"    "${DEPLOY[@]}" runtime
t  "runtime is root-owned, symlinked, runnable"     bash -c "[ \"\$($B_ROOT/runtime/node/bin/node)\" = v9.9.9 ] && [ \"\$(stat -c %U $B_ROOT/runtime/node-v9.9.9)\" = root ]"
tn "runtime aborts on a checksum mismatch"          "${BENV[@]}" NODE_SHA256_x64=deadbeef NODE_SHA256_arm64=deadbeef "$ROOT/vps/deploy.sh" --apply runtime
t  "...and leaves no temp download behind"          bash -c "[ -z \"\$(ls -A $B_ROOT/runtime | grep '^\\.dl\\.')\" ]"
t  "apply toolkit"                                  "${DEPLOY[@]}" toolkit
t  "toolkit copy is root-owned and read-only to the service users" bash -c "[ \"\$(stat -c %U $B_ROOT/toolkit/termux/freellmapi.sh)\" = root ] && ! runuser -u $UF -- test -w $B_ROOT/toolkit/termux/freellmapi.sh && ! runuser -u $UF -- sh -c ': >> $B_ROOT/toolkit/termux/freellmapi.sh' 2>/dev/null"
t  "apply config (ports 18601/18602)"               "${DEPLOY[@]}" config --freellmapi-port 18601 --omniroute-port 18602
t  "gateways.env is 0600 and owned by its user"     bash -c "[ \"\$(stat -c '%a %U' $B_ROOT/freellmapi/config/gateways.env)\" = '600 $UF' ] && grep -q '^FREELLMAPI_PORT=18601' $B_ROOT/freellmapi/config/gateways.env && grep -q '^GATEWAY_BIND_HOST=127.0.0.1' $B_ROOT/omniroute/config/gateways.env"
t  "apply units (verified with systemd-analyze when available)" "${DEPLOY[@]}" units
t  "unit files rendered for the right users/ports"  bash -c "grep -q '^User=$UF\$' $TMP/unitdir/llm-freellmapi.service && grep -q '^User=$UO\$' $TMP/unitdir/llm-omniroute.service && grep -q '127.0.0.1:18601' $TMP/unitdir/llm-freellmapi.service && ! grep -q '@[A-Z_]*@' $TMP/unitdir/*.service"
t  "isolation: freellmapi's user cannot read omniroute's directory" bash -c "! runuser -u $UF -- ls $B_ROOT/omniroute/config 2>/dev/null"
t  "isolation: omniroute's user cannot read freellmapi's directory" bash -c "! runuser -u $UO -- ls $B_ROOT/freellmapi/config 2>/dev/null"
t  "isolation: a service user cannot write outside its dir" bash -c "! runuser -u $UF -- sh -c ': > /srv/llmtest-escape-$$' 2>/dev/null && [ ! -e /srv/llmtest-escape-$$ ]"
t  "status step runs"                               "${BENV[@]}" "$ROOT/vps/deploy.sh" status
echo "# PART B: verify.sh"
t  "verify passes on a clean deployment"            "${BENV[@]}" "$ROOT/vps/verify.sh" --baseline "$TMP/b.base"
mkdir -p /opt/llmtest-stray-$$ && chown $UF /opt/llmtest-stray-$$
tn "verify fails if a service user owns a file outside its root" "${BENV[@]}" "$ROOT/vps/verify.sh" --baseline "$TMP/b.base"
rmdir /opt/llmtest-stray-$$
usermod -aG adm $UF 2>/dev/null
tn "verify fails if a service user joins a privileged group" "${BENV[@]}" "$ROOT/vps/verify.sh" --baseline "$TMP/b.base"
gpasswd -d $UF adm >/dev/null 2>&1
t  "verify passes again after cleanup"              "${BENV[@]}" "$ROOT/vps/verify.sh" --baseline "$TMP/b.base"
runuser -u $UF -- node -e 'require("net").createServer().listen(18601,"0.0.0.0")' >/dev/null 2>&1 & PIDS+=("$!"); sleep 1
tn "verify fails when a service socket is not loopback-only" "${BENV[@]}" "$ROOT/vps/verify.sh" --baseline "$TMP/b.base"
kill "${PIDS[-1]}" 2>/dev/null; sleep 0.5
runuser -u $UF -- node -e 'require("net").createServer().listen(18601,"127.0.0.1")' >/dev/null 2>&1 & PIDS+=("$!"); sleep 1
t  "verify accepts a loopback listener on the configured port" "${BENV[@]}" "$ROOT/vps/verify.sh" --baseline "$TMP/b.base"
kill "${PIDS[-1]}" 2>/dev/null; sleep 0.5
runuser -u $UF -- node -e 'require("net").createServer().listen(18777,"127.0.0.1")' >/dev/null 2>&1 & PIDS+=("$!"); sleep 1
tn "verify fails on a loopback listener on an UNEXPECTED port" "${BENV[@]}" "$ROOT/vps/verify.sh" --baseline "$TMP/b.base"
kill "${PIDS[-1]}" 2>/dev/null; sleep 0.5
echo "# PART B: gwctl update with automatic rollback (fake toolkit scripts)"
for g in freellmapi omniroute; do
  cat > "$B_ROOT/toolkit/termux/$g.sh" <<'FAKE'
#!/bin/sh
# fake gateway manager: records calls, "update" can be made to break health via the marker file
echo "$@" >> "$GW_HOME/calls.log"
case "$1" in
  update) [ -f "$GW_HOME/fail-update" ] && exit 1; touch "$GW_HOME/updated"; exit 0 ;;
  rollback) rm -f "$GW_HOME/updated"; touch "$GW_HOME/rolled-back"; rm -f "$GW_HOME/break-health"; exit 0 ;;
  status) [ -f "$GW_HOME/up" ] && echo "[ ok ] running pid 1" || echo "not running"; exit 0 ;;
  start) touch "$GW_HOME/up"; exit 0 ;;
  stop) rm -f "$GW_HOME/up"; exit 0 ;;
  backup) touch "$GW_HOME/backed-up"; exit 0 ;;
esac
exit 0
FAKE
  chmod 755 "$B_ROOT/toolkit/termux/$g.sh"
done
GCB=(env PATH="$BIN:$PATH" LLM_ROOT="$B_ROOT" LLM_USER_FREELLMAPI="$UF" LLM_USER_OMNIROUTE="$UO" SYSTEMD_RUN_DIR=/nonexistent/x LLM_NO_SYSTEMD=1 GWCTL_HEALTH_WAIT=3 "$ROOT/vps/gwctl.sh")
node "$ROOT/tests/quota/mock-gateways.mjs" freellmapi ok 18601 >/dev/null 2>&1 & PIDS+=("$!"); sleep 1
t  "gwctl backup stops/starts around the toolkit call"  bash -c "runuser -u $UF -- touch $B_ROOT/freellmapi/up; ${GCB[*]} freellmapi backup && [ -f $B_ROOT/freellmapi/backed-up ] && [ -f $B_ROOT/freellmapi/up ] && grep -q '^stop\$' $B_ROOT/freellmapi/calls.log && grep -q '^start\$' $B_ROOT/freellmapi/calls.log"
t  "gwctl update with healthy result keeps the update"  bash -c "${GCB[*]} freellmapi update && [ -f $B_ROOT/freellmapi/updated ] && [ ! -f $B_ROOT/freellmapi/rolled-back ]"
rm -f "$B_ROOT"/freellmapi/updated
runuser -u $UF -- touch "$B_ROOT/freellmapi/fail-update"
tn "gwctl update that fails triggers rollback and exits 1" bash -c "${GCB[*]} freellmapi update"
t  "...rollback --with-data --yes was called"           bash -c "grep -q 'rollback --with-data --yes' $B_ROOT/freellmapi/calls.log && [ -f $B_ROOT/freellmapi/rolled-back ]"
runuser -u $UF -- rm -f "$B_ROOT/freellmapi/fail-update" "$B_ROOT/freellmapi/rolled-back"
kill "${PIDS[-1]}" 2>/dev/null; sleep 0.5          # mock gone => health check will fail after the update
runuser -u $UF -- touch "$B_ROOT/freellmapi/up"
tn "gwctl update that is unhealthy afterwards auto-rolls back" bash -c "${GCB[*]} freellmapi update"
t  "...and the rollback restored the previous version"  bash -c "[ -f $B_ROOT/freellmapi/rolled-back ] && [ ! -f $B_ROOT/freellmapi/updated ]"
echo "# PART B: remove"
tn "remove --purge without --yes-delete-data refuses"   "${BENV[@]}" "$ROOT/vps/deploy.sh" --apply remove omniroute --purge
t  "remove --purge --yes-delete-data deletes only that gateway" bash -c "${BENV[*]} '$ROOT/vps/deploy.sh' --apply remove omniroute --purge --yes-delete-data >/dev/null 2>&1; [ ! -e $B_ROOT/omniroute ] && ! getent passwd $UO && [ -d $B_ROOT/freellmapi ] && getent passwd $UF >/dev/null && [ -d $B_ROOT/toolkit ]"
else
  echo "# PART B skipped (needs root and LLM_TEST_ALLOW_SYSTEM_CHANGES=1: it creates real users/directories)"
fi

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
