#!/usr/bin/env bash
# READ-ONLY post-deploy verification: proves the existing server is unchanged and the new services are contained.
#
#   verify.sh --baseline SNAPSHOT [--root DIR]
#
# 1. inventory compare against the pre-deploy baseline (containers, volumes, networks, unit files, users, hashes of Caddy/sshd/sudoers/cron ...)
# 2. our service users own nothing outside $LLM_ROOT (apart from /tmp, /run, /var/tmp)
# 3. our service users belong to no privileged group (docker, sudo, adm, ...)
# 4. every socket owned by our users is a loopback listener on one of the two configured ports
# 5. unit state (when systemd is running)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vps-common.sh
. "$HERE/lib/vps-common.sh"
BASE=""
while [ $# -gt 0 ]; do case "$1" in --baseline) BASE="$2"; shift;; --root) LLM_ROOT="$2"; shift;; *) die "unknown option $1";; esac; shift; done
[ -f "$BASE" ] || die "usage: verify.sh --baseline SNAPSHOT"
LOWPRIO=(); have nice && LOWPRIO+=(nice -n 19); have ionice && LOWPRIO+=(ionice -c3)
FAILS=0; fail() { err "$*"; FAILS=$((FAILS+1)); }

info "1/5 integrity of the existing server vs baseline"
"$HERE/inventory.sh" compare "$BASE" || FAILS=$((FAILS+1))

info "2/5 files owned by the service users outside $LLM_ROOT"
for gw in freellmapi omniroute; do
  u="$(gw_user "$gw")"; getent passwd "$u" >/dev/null || continue
  # Lowest CPU/IO priority and no walking of container storage: this must not disturb the live services.
  stray="$("${LOWPRIO[@]}" find / -xdev \( -path /proc -o -path /sys -o -path /run -o -path /tmp -o -path /var/tmp -o -path "$LLM_ROOT" -o -path /var/lib/docker -o -path /var/lib/containerd -o -path /snap \) -prune -o -user "$u" -print 2>/dev/null | head -n 5)"
  [ -z "$stray" ] && ok "$u owns nothing outside $LLM_ROOT" || fail "$u owns files outside $LLM_ROOT: $(echo "$stray" | tr '\n' ' ')"
done

info "3/5 group membership"
for gw in freellmapi omniroute; do
  u="$(gw_user "$gw")"; getent passwd "$u" >/dev/null || continue
  g="$(id -nG "$u" 2>/dev/null)"
  [ "$g" = "$u" ] && ok "$u is only in its own group" || fail "$u is in unexpected groups: $g"
done

info "4/5 sockets owned by the service users"
PF="$(grep -E '^PORT_FREELLMAPI=' "$LLM_ROOT/deploy.conf" 2>/dev/null | cut -d= -f2)"; PO="$(grep -E '^PORT_OMNIROUTE=' "$LLM_ROOT/deploy.conf" 2>/dev/null | cut -d= -f2)"
UIDS=""; for gw in freellmapi omniroute; do u="$(gw_user "$gw")"; getent passwd "$u" >/dev/null && UIDS="$UIDS $(id -u "$u")"; done
if [ -n "$UIDS" ]; then
  socks="$(for f in /proc/net/tcp /proc/net/tcp6; do [ -r "$f" ] && awk -v uids="$UIDS" -v v6="$([ "$f" = /proc/net/tcp6 ] && echo 1 || echo 0)" '
    function hex(s,  i,c,n){n=0;for(i=1;i<=length(s);i++){c=index("0123456789ABCDEF",toupper(substr(s,i,1)))-1;n=n*16+c}return n}
    BEGIN{n=split(uids,u," ");for(i=1;i<=n;i++)ok[u[i]]=1}
    NR>1 && $4=="0A" && ($8 in ok){split($2,p,":"); a=p[1]; loop=(v6? (a=="00000000000000000000000001000000") : (a=="0100007F")); print hex(p[2]), (loop?"loopback":"EXPOSED:" a), "uid=" $8}' "$f"; done)"
  if [ -z "$socks" ]; then info "no listening sockets owned by the service users yet (services not started)"; fi
  while read -r port kind rest; do
    [ -n "$port" ] || continue
    if [ "$kind" != loopback ]; then fail "socket on port $port is not loopback-only ($kind $rest)"
    elif [ "$port" != "$PF" ] && [ "$port" != "$PO" ]; then fail "unexpected listener on 127.0.0.1:$port ($rest): not one of the configured ports"
    else ok "127.0.0.1:$port ($rest) loopback-only, expected"; fi
  done <<< "$socks"
fi

info "5/5 unit state"
if [ -d "$SYSTEMD_RUN_DIR" ] && [ -z "${LLM_NO_SYSTEMD:-}" ]; then
  for gw in freellmapi omniroute; do
    [ -f "$SYSTEMD_DIR/$(gw_unit "$gw")" ] || { info "$(gw_unit "$gw") not installed"; continue; }
    st="$(systemctl is-active "$(gw_unit "$gw")" 2>/dev/null)"; info "$(gw_unit "$gw"): $st"
  done
else info "systemd not in use here (skipped)"; fi

if [ "$FAILS" -eq 0 ]; then ok "VERIFY: PASS"; exit 0; fi
err "VERIFY: FAIL ($FAILS problem(s))"; exit 1
