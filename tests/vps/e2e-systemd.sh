#!/usr/bin/env bash
# END-TO-END rehearsal of the GATEWAY units under REAL systemd, on a DISPOSABLE machine (GitHub-hosted runner). Same real deploy.sh, real pinned
# Node download and real installs as e2e-sandbox.sh, but the services are started by systemd (no LLM_NO_SYSTEMD), so this checks what the
# sandbox rehearsal cannot: effective unit properties, the kernel's cgroup limits, restart policy, StartLimit, KillMode, graceful stop and
# independence of the two services.
#
#   sudo LLM_TEST_ALLOW_SYSTEM_CHANGES=1 REQUIRE_SYSTEMD=1 bash tests/vps/e2e-systemd.sh
#
# Makes REAL changes: users llmsdgwf/llmsdgwo, /srv/llmsdgw-PID and /etc/systemd/system/llm-{freellmapi,omniroute}.service. Refuses to run unless
# root + flag + systemd is PID 1 + none of those unit files exist. Everything is removed on exit.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$(id -u)" = 0 ] && [ "${LLM_TEST_ALLOW_SYSTEM_CHANGES:-}" = 1 ] || { echo "refusing: needs root and LLM_TEST_ALLOW_SYSTEM_CHANGES=1"; exit 2; }
if [ ! -d /run/systemd/system ]; then
  [ "${REQUIRE_SYSTEMD:-}" = 1 ] && { echo "FAIL: systemd is not running but REQUIRE_SYSTEMD=1"; exit 1; }
  echo "SKIP: systemd is not running here"; exit 0
fi
SD=/etc/systemd/system
ls "$SD"/llm-freellmapi.service "$SD"/llm-omniroute.service >/dev/null 2>&1 && { echo "refusing: real llm-* gateway units already exist on this host"; exit 2; }
TMP="$(mktemp -d)"; E="/srv/llmsdgw-$$"; UF=llmsdgwf; UO=llmsdgwo; PF=${E2E_PORT_FL:-18711}; PO=${E2E_PORT_OM:-18712}
export LLM_ROOT="$E" LLM_USER_FREELLMAPI=$UF LLM_USER_OMNIROUTE=$UO
cd "$TMP" || exit 2
PASS=0; FAIL=0
ck() { local n="$1"; shift; if "$@" >"$TMP/o" 2>&1; then PASS=$((PASS+1)); echo "ok   - $n"; else FAIL=$((FAIL+1)); echo "FAIL - $n"; tail -8 "$TMP/o" | sed 's/^/       /'; fi; }
info() { echo "       $*"; }
cleanup() {
  echo "# cleanup"
  for g in freellmapi omniroute; do systemctl disable --now "llm-$g.service" >/dev/null 2>&1; rm -f "$SD/llm-$g.service"; done
  systemctl daemon-reload >/dev/null 2>&1; sleep 1; pkill -u $UF 2>/dev/null; pkill -u $UO 2>/dev/null; sleep 1
  for u in $UF $UO; do getent passwd $u >/dev/null && userdel $u 2>/dev/null; done
  case "$E" in /srv/llmsdgw-*) rm -rf -- "$E";; esac; rm -rf -- "$TMP"
  echo "e2e-systemd: passed=$PASS failed=$FAIL"
}
trap cleanup EXIT
D() { "$ROOT/vps/deploy.sh" --apply "$@"; }
G() { "$E/toolkit/vps/gwctl.sh" "$@"; }
prop() { systemctl show "llm-$1.service" -p "$2" --value; }
health() { # health GW  -> HTTP 200 on the liveness path
  local p path; case "$1" in freellmapi) p=$PF; path=/api/ping;; omniroute) p=$PO; path=/api/health/ping;; esac
  [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$p$path")" = 200 ]
}
wait_health() { for _ in $(seq 1 "${2:-90}"); do health "$1" && return 0; sleep 1; done; return 1; }
wait_new_pid() { # wait_new_pid GW OLDPID [secs] -> prints new MainPID once active and different
  local np; for _ in $(seq 1 "${3:-90}"); do np="$(prop "$1" MainPID)"; if [ "$np" != 0 ] && [ "$np" != "$2" ] && systemctl is-active --quiet "llm-$1.service"; then echo "$np"; return 0; fi; sleep 1; done; return 1
}
cg() { echo "/sys/fs/cgroup$(prop "$1" ControlGroup)"; }
echo "# host: $(. /etc/os-release; echo "$PRETTY_NAME"), systemd $(systemctl --version | head -n1 | cut -d' ' -f2), cgroup $(stat -fc %T /sys/fs/cgroup), kernel $(uname -r), $(nproc) CPU, $(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"

echo "# gates: REAL preflight (systemd is present, so it must not BLOCK) + inventory baseline"
"$ROOT/vps/preflight.sh" --freellmapi-port $PF --omniroute-port $PO --out "$TMP/pf.txt" >"$TMP/pf.log" 2>&1; grep -E "^\[(BLOCK|WARN)" "$TMP/pf.log" | sed 's/^/       /'
ck "preflight does not BLOCK on a real systemd host" bash -c "! grep -q '^RESULT: BLOCKED' '$TMP/pf.txt'"
"$ROOT/vps/inventory.sh" snapshot --out "$TMP/base.snap" >/dev/null 2>&1
ck "baseline snapshot exists" test -s "$TMP/base.snap"
GATE=(--preflight "$TMP/pf.txt" --baseline "$TMP/base.snap")

echo "# deploy: users dirs runtime toolkit config, then REAL installs"
ck "users"   D users "${GATE[@]}"
ck "dirs"    D dirs
ck "runtime (REAL Node download, SHA-256 pinned)" D runtime
ck "toolkit" D toolkit
ck "config"  D config --freellmapi-port $PF --omniroute-port $PO
ck "install freellmapi (as $UF)" D install freellmapi
ck "install omniroute (as $UO)"  D install omniroute
ck "units render+verify+install into /etc/systemd/system" D units
ck "systemd knows both units"   bash -c "systemctl cat llm-freellmapi.service llm-omniroute.service >/dev/null"

echo "# enable = systemctl enable --now, wait for health, run verify.sh (deploy.sh disables the unit again on failure)"
ck "enable freellmapi" D enable freellmapi --baseline "$TMP/base.snap"
ck "enable omniroute"  D enable omniroute --baseline "$TMP/base.snap"
ck "freellmapi healthy under systemd" wait_health freellmapi 90
ck "omniroute healthy under systemd"  wait_health omniroute 150
ck "both units enabled (start at boot) and active" bash -c "for g in freellmapi omniroute; do [ \"\$(systemctl is-enabled llm-\$g.service)\" = enabled ] && systemctl is-active --quiet llm-\$g.service || exit 1; done"

echo "# effective unit properties as systemd sees them"
for g in freellmapi omniroute; do
  u=$([ "$g" = freellmapi ] && echo $UF || echo $UO)
  ck "$g: runs as its own user, no new privileges, strict filesystem" bash -c "[ \"\$(systemctl show llm-$g.service -p User --value)\" = $u ] && [ \"\$(systemctl show llm-$g.service -p NoNewPrivileges --value)\" = yes ] && [ \"\$(systemctl show llm-$g.service -p ProtectSystem --value)\" = strict ]"
  ck "$g: Restart=on-failure, KillMode=control-group, StartLimitBurst=5" bash -c "[ \"\$(systemctl show llm-$g.service -p Restart --value)\" = on-failure ] && [ \"\$(systemctl show llm-$g.service -p KillMode --value)\" = control-group ] && [ \"\$(systemctl show llm-$g.service -p StartLimitBurst --value)\" = 5 ]"
  ck "$g: MainPID's uid is the service user and it lives in the unit's cgroup" bash -c "p=\$(systemctl show llm-$g.service -p MainPID --value); [ \"\$p\" != 0 ] && [ \"\$(ps -o uid= -p \$p | tr -d ' ')\" = \"\$(id -u $u)\" ] && grep -q \"llm-$g.service\" /proc/\$p/cgroup"
done

echo "# kernel cgroup limits (the files the kernel enforces, not just the unit text)"
ck "cgroup v2 is in use" bash -c "[ \"\$(stat -fc %T /sys/fs/cgroup)\" = cgroup2fs ]"
ck "freellmapi: memory.max = 1 GiB"  bash -c "[ \"\$(cat $(cg freellmapi)/memory.max)\" = 1073741824 ]"
ck "omniroute:  memory.max = 2 GiB"  bash -c "[ \"\$(cat $(cg omniroute)/memory.max)\" = 2147483648 ]"
for g in freellmapi omniroute; do
  c="$(cg $g)"
  ck "$g: memory.high is set below memory.max (reclaim pressure before the hard limit)" bash -c "h=\$(cat '$c/memory.high'); m=\$(cat '$c/memory.max'); [ \"\$h\" != max ] && [ \"\$h\" -lt \"\$m\" ]"
  ck "$g: cpu.max = 80% of one CPU" bash -c "[ \"\$(cat '$c/cpu.max')\" = '80000 100000' ]"
  ck "$g: pids.max = 512" bash -c "[ \"\$(cat '$c/pids.max')\" = 512 ]"
done
for g in freellmapi omniroute; do info "$g memory.current=$(( $(cat "$(cg $g)/memory.current") / 1048576 )) MiB (limit $(( $(cat "$(cg $g)/memory.max") / 1048576 )) MiB), pids.current=$(cat "$(cg $g)/pids.current")"; done
ck "gateways listen on 127.0.0.1 only" python3 - "$PF" "$PO" <<'PY'
import sys
want={int(a) for a in sys.argv[1:]}
rows=[l.split() for l in open('/proc/net/tcp').read().splitlines()[1:] if l.split()[3]=='0A']
bad=[r[1] for r in rows if int(r[1].split(':')[1],16) in want and not r[1].startswith('0100007F:')]
sys.exit(1 if bad or not [1 for r in rows if int(r[1].split(':')[1],16) in want] else 0)
PY

echo "# crash recovery: kill -9 each gateway; the other must not notice"
for g in freellmapi omniroute; do
  o=$([ "$g" = freellmapi ] && echo omniroute || echo freellmapi)
  oldpid="$(prop $g MainPID)"; opid="$(prop $o MainPID)"; restarts0="$(prop $g NRestarts)"
  kill -9 "$oldpid"
  newpid="$(wait_new_pid $g "$oldpid" 90)"
  ck "$g: kill -9 => systemd restarts it with a new PID (Restart=on-failure)" test -n "$newpid"
  wt=90; [ "$g" = omniroute ] && wt=150
  ck "$g: healthy again" wait_health "$g" "$wt"
  ck "$g: NRestarts incremented" bash -c "[ \"\$(systemctl show llm-$g.service -p NRestarts --value)\" -gt '$restarts0' ]"
  ck "$o: untouched (same PID) while $g crashed" bash -c "[ \"\$(systemctl show llm-$o.service -p MainPID --value)\" = '$opid' ]"
  ck "$o: still healthy" health $o
done

echo "# graceful stop: KillMode=control-group leaves nothing behind; independent start/stop"
t0=$(date +%s); systemctl stop llm-freellmapi.service; t1=$(date +%s)
ck "freellmapi: stop completed within TimeoutStopSec ($((t1-t0)) s)" bash -c "[ $((t1-t0)) -le 35 ]"
ck "freellmapi: unit inactive (not failed) and NO process of $UF is left" bash -c "[ \"\$(systemctl is-active llm-freellmapi.service)\" = inactive ] && ! pgrep -u $UF >/dev/null"
ck "freellmapi: its port is released"  bash -c "! (exec 3<>/dev/tcp/127.0.0.1/$PF) 2>/dev/null"
ck "omniroute keeps serving while freellmapi is stopped" health omniroute
t0=$(date +%s); systemctl stop llm-omniroute.service; t1=$(date +%s)
ck "omniroute: stop completed within TimeoutStopSec ($((t1-t0)) s)" bash -c "[ $((t1-t0)) -le 35 ]"
ck "omniroute: inactive and NO process of $UO is left" bash -c "[ \"\$(systemctl is-active llm-omniroute.service)\" = inactive ] && ! pgrep -u $UO >/dev/null"
ck "start freellmapi alone"  systemctl start llm-freellmapi.service
ck "freellmapi healthy after a clean restart" wait_health freellmapi 90
ck "omniroute stayed down while freellmapi started (no cross-start)" bash -c "[ \"\$(systemctl is-active llm-omniroute.service)\" = inactive ]"
ck "start omniroute"  systemctl start llm-omniroute.service
ck "omniroute healthy after a clean restart" wait_health omniroute 150

echo "# gwctl and monitor under real systemd"
ck "gwctl backup cycles the service through systemctl and it comes back healthy" bash -c "$E/toolkit/vps/gwctl.sh freellmapi backup && $E/toolkit/vps/gwctl.sh freellmapi health"
MON_DISK_WARN_GB=1 MON_DISK_CRIT_GB=1 "$E/toolkit/vps/monitor.sh" check > "$TMP/mon.txt" 2>&1
ck "monitor.sh reads real unit state: no CRIT line" bash -c "! grep -q '^CRIT' '$TMP/mon.txt'"
ck "monitor.sh sees both units active" bash -c "grep -q 'OK    freellmapi.unit' '$TMP/mon.txt' && grep -q 'OK    omniroute.unit' '$TMP/mon.txt'"
ck "verify.sh passes (server unchanged, services contained) with systemd-managed services" "$ROOT/vps/verify.sh" --baseline "$TMP/base.snap"

echo "# crash LOOP: StartLimitBurst=5 stops a flapping service instead of respawning it forever; the documented recovery works"
systemctl reset-failed llm-freellmapi.service 2>/dev/null
n=0
for _ in 1 2 3 4 5 6 7 8; do
  [ "$(prop freellmapi ActiveState)" = failed ] && break
  p="$(wait_new_pid freellmapi 0 40)" || break   # any live MainPID
  kill -9 "$p" 2>/dev/null; n=$((n+1))
  for _ in $(seq 1 20); do [ "$(prop freellmapi MainPID)" != "$p" ] && break; sleep 0.5; done
done
for _ in $(seq 1 30); do [ "$(prop freellmapi ActiveState)" = failed ] && break; sleep 1; done
info "freellmapi after the loop: ActiveState=$(prop freellmapi ActiveState) Result=$(prop freellmapi Result) NRestarts=$(prop freellmapi NRestarts)"
ck "freellmapi: after repeated crashes the unit is FAILED ($n kills)" bash -c "[ \"\$(systemctl show llm-freellmapi.service -p ActiveState --value)\" = failed ]"
ck "freellmapi: systemd logged the start-limit refusal (StartLimitBurst reached)" bash -c "journalctl -u llm-freellmapi.service --no-pager | grep -q 'Start request repeated too quickly'"
r0="$(prop freellmapi NRestarts)"; sleep 12
ck "freellmapi: NOT respawned any more (no new process, NRestarts unchanged over 12 s)" bash -c "[ \"\$(systemctl show llm-freellmapi.service -p MainPID --value)\" = 0 ] && [ \"\$(systemctl show llm-freellmapi.service -p NRestarts --value)\" = '$r0' ]"
ck "omniroute unaffected by freellmapi's crash loop" health omniroute
ck "documented recovery (reset-failed + start) works" bash -c "systemctl reset-failed llm-freellmapi.service && systemctl start llm-freellmapi.service"
ck "freellmapi healthy after the documented recovery" wait_health freellmapi 90

echo "# journal and removal"
ck "journal has the unit's lifecycle messages" bash -c "journalctl -u llm-freellmapi.service --no-pager | grep -qE 'Started|Stopped|Main process exited'"
ck "deploy remove deletes only that gateway's unit" bash -c "$ROOT/vps/deploy.sh --apply remove omniroute && [ ! -e $SD/llm-omniroute.service ] && [ -e $SD/llm-freellmapi.service ] && systemctl is-active --quiet llm-freellmapi.service"
[ "$FAIL" -eq 0 ]
