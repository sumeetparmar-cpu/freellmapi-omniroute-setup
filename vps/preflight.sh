#!/usr/bin/env bash
# READ-ONLY preflight for deploying FreeLLMAPI + OmniRoute next to existing services (SUPPAR, EARNIX, n8n, Caddy, Docker).
# Changes nothing, sends no credentials. Exit 0 = no blockers, 1 = blockers. Safe to run as a normal user; root adds process names.
#
#   vps/preflight.sh [--freellmapi-port N] [--omniroute-port N] [--root DIR] [--offline] [--out FILE]
#
# --out FILE stores the report (mode 600). deploy.sh refuses to apply the first step unless that file says RESULT: PASS*.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vps-common.sh
. "$HERE/lib/vps-common.sh"

OFFLINE=0; OUT=""; REQ_FL=""; REQ_OM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --freellmapi-port) REQ_FL="$2"; shift ;; --omniroute-port) REQ_OM="$2"; shift ;;
    --root) LLM_ROOT="$2"; shift ;; --offline) OFFLINE=1 ;; --out) OUT="$2"; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac; shift
done

NP=0; NW=0; NB=0; REPORT=""
emit() { local line="$1"; REPORT+="$line"$'\n'; printf '%s\n' "$line"; }
pass()  { NP=$((NP+1)); emit "[PASS ] $*"; }
warn_() { NW=$((NW+1)); emit "[WARN ] $*"; }
block() { NB=$((NB+1)); emit "[BLOCK] $*"; }
info_() { emit "[INFO ] $*"; }
head_() { emit ""; emit "== $* =="; }

emit "VPS preflight (read-only)  host=$(hostname 2>/dev/null)  time=$(date -u +%FT%TZ)  user=$(id -un)  root_dir=$LLM_ROOT"
valid_port "${REQ_FL:-$DEFAULT_PORT_FREELLMAPI}" || die "invalid --freellmapi-port"
valid_port "${REQ_OM:-$DEFAULT_PORT_OMNIROUTE}" || die "invalid --omniroute-port"
( assert_safe_root ) >/dev/null 2>&1 || block "LLM_ROOT '$LLM_ROOT' is not a safe dedicated directory"

head_ "Operating system"
OSID="$(os_field ID)"; OSVER="$(os_field VERSION_ID)"; OSNAME="$(os_field PRETTY_NAME)"
info_ "os-release: ${OSNAME:-unknown} (ID=${OSID:-?} VERSION_ID=${OSVER:-?})  kernel $(uname -r)"
if [ "$OSID" = "$TARGET_OS_ID" ] && [ "$OSVER" = "$TARGET_OS_VERSION" ]; then pass "Ubuntu $TARGET_OS_VERSION (target OS)"
else warn_ "not Ubuntu $TARGET_OS_VERSION (found ${OSID:-unknown} ${OSVER:-unknown}); this toolkit is CI-tested on Ubuntu 24.04 and 26.04 only. The decision rests on the functional checks below, not on the version string"; fi
if ARCH="$(node_arch)"; then pass "CPU architecture $(uname -m) -> official Node build '$ARCH' has a pinned checksum"; else block "unsupported architecture $(uname -m) (no pinned Node checksum)"; fi
GLIBC="$(ldd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+$')"
if [ -n "$GLIBC" ] && ver_ge "$GLIBC.0" "2.28.0"; then pass "glibc $GLIBC (Node 24 official binaries need >= 2.28)"; else block "glibc '${GLIBC:-unknown}' < 2.28 or undetectable"; fi

head_ "Service manager"
if [ -d "$SYSTEMD_RUN_DIR" ]; then
  SDV="$(systemctl --version 2>/dev/null | head -n1 | awk '{print $2}')"
  if [ -n "$SDV" ] && [ "$SDV" -ge 245 ] 2>/dev/null; then pass "systemd $SDV running (units use ProtectSystem=strict etc.)"; else block "systemd version '${SDV:-unknown}' < 245"; fi
  if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = cgroup2fs ]; then pass "cgroup v2 (MemoryMax/CPUQuota enforceable)"; else warn_ "cgroup v2 not detected: resource limits in the units may not be enforced"; fi
else block "systemd is not the running init (no $SYSTEMD_RUN_DIR): service templates cannot be used"; fi

head_ "Resources"
NCPU="$(nproc 2>/dev/null || echo 1)"; MT=$(( $(mem_kb MemTotal) / 1024 )); MA=$(( $(mem_kb MemAvailable) / 1024 )); SW=$(( $(mem_kb SwapTotal) / 1024 ))
info_ "CPUs: $NCPU   RAM total: ${MT} MB   available: ${MA} MB   swap: ${SW} MB   load(1m): $(cut -d' ' -f1 /proc/loadavg)"
if [ "$MT" -ge "$WARN_RAM_MB" ]; then pass "RAM total ${MT} MB"; elif [ "$MT" -ge "$MIN_RAM_MB" ]; then warn_ "RAM total ${MT} MB < ${WARN_RAM_MB} MB: install/build and OmniRoute (~0.6 GB idle) will compete with existing services"; else block "RAM total ${MT} MB < ${MIN_RAM_MB} MB"; fi
if [ "$MA" -ge "$WARN_AVAIL_MB" ]; then pass "RAM available ${MA} MB"; elif [ "$MA" -ge "$MIN_AVAIL_MB" ]; then warn_ "RAM available ${MA} MB < ${WARN_AVAIL_MB} MB: install during a quiet period"; else block "RAM available only ${MA} MB < ${MIN_AVAIL_MB} MB"; fi
LOAD1="$(cut -d' ' -f1 /proc/loadavg)"; if awk -v l="$LOAD1" -v n="$NCPU" 'BEGIN{exit !(l > n*0.8)}'; then warn_ "load average $LOAD1 is high for $NCPU CPU(s): wait for a quieter moment"; else pass "load average $LOAD1 on $NCPU CPU(s)"; fi
# A container / systemd slice can cap memory far below what /proc/meminfo shows; honour the tighter number.
CGF="${CGROUP_MEM_FILE:-}"
if [ -z "$CGF" ]; then cgp="$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup 2>/dev/null | head -n1)"; [ -n "$cgp" ] && CGF="/sys/fs/cgroup${cgp}/memory.max"; fi
if [ -n "$CGF" ] && [ -r "$CGF" ]; then
  cgmax="$(cat "$CGF" 2>/dev/null)"
  if [ "$cgmax" != "max" ] && [ -n "$cgmax" ] && [ "$cgmax" -gt 0 ] 2>/dev/null && [ $((cgmax / 1048576)) -lt "$MT" ]; then
    warn_ "memory is capped by this process's cgroup at $((cgmax / 1048576)) MB (host shows ${MT} MB): the real budget is the smaller number"
  fi
fi
OC="$(cat "${OVERCOMMIT_FILE:-/proc/sys/vm/overcommit_memory}" 2>/dev/null)"
if [ "$OC" = 2 ]; then warn_ "vm.overcommit_memory=2 (strict): Node reserves large virtual ranges and may fail to start even with free RAM"; fi
# What is left for the EXISTING services once ours run (typical measured use: FreeLLMAPI ~155 MB + OmniRoute ~610 MB = ~770 MB; the unit MemoryMax values are ceilings, not expected use).
HEADROOM=$(( MA - 800 ))
if [ "$HEADROOM" -ge 1000 ]; then pass "about ${HEADROOM} MB would remain available to existing services with both gateways running (~800 MB typical)"; else warn_ "only ~${HEADROOM} MB would remain available to existing services with both gateways running (~800 MB typical use): expect memory pressure"; fi
D="$LLM_ROOT"; while [ ! -d "$D" ] && [ "$D" != "/" ]; do D="$(dirname "$D")"; done
FREE_KB="$(df -Pk "$D" 2>/dev/null | awk 'NR==2{print $4}')"; FREE_GB=$(( ${FREE_KB:-0} / 1024 / 1024 ))
if [ "$FREE_GB" -ge "$WARN_DISK_GB" ]; then pass "disk free ${FREE_GB} GB on the filesystem holding $D"; elif [ "$FREE_GB" -ge "$MIN_DISK_GB" ]; then warn_ "disk free ${FREE_GB} GB < ${WARN_DISK_GB} GB (measured need: ~0.6 GB FreeLLMAPI + up to ~2.7 GB OmniRoute + backups)"; else block "disk free ${FREE_GB} GB < ${MIN_DISK_GB} GB"; fi
FREE_INODES="$(df -Pi "$D" 2>/dev/null | awk 'NR==2{print $4}')"; if [ "${FREE_INODES:-0}" -ge 300000 ]; then pass "free inodes ${FREE_INODES} (node_modules is file-heavy)"; else warn_ "free inodes ${FREE_INODES:-unknown} < 300000"; fi

head_ "Filesystem and permissions"
MOUNTS="${MOUNTS_FILE:-/proc/mounts}"
mnt_opts() { # mnt_opts PATH -> options of the longest mount point that contains PATH
  awk -v p="$1" '{ m=$2; if (m=="/" || p==m || index(p, m "/")==1) { if (length(m) > best) { best=length(m); o=$4 } } } END{print o}' "$MOUNTS" 2>/dev/null
}
has_opt() { case ",$1," in *",$2,"*) return 0;; *) return 1;; esac; }
OPTS="$(mnt_opts "$D")"
if [ -n "$OPTS" ]; then
  if has_opt "$OPTS" ro; then block "the filesystem holding $D is mounted READ-ONLY ($OPTS)"; else pass "filesystem holding $D is writable"; fi
  if has_opt "$OPTS" noexec; then block "the filesystem holding $D is mounted noexec: the pinned Node binary could not run"; else pass "filesystem holding $D allows executables"; fi
else info_ "mount options for $D could not be read ($MOUNTS)"; fi
TD="${TMPDIR:-/tmp}"; TOPTS="$(mnt_opts "$TD")"
if [ -n "$TOPTS" ] && has_opt "$TOPTS" noexec; then warn_ "$TD is mounted noexec: npm/node-gyp build steps that run helpers from $TD may fail (set TMPDIR to an exec-capable directory)"; else pass "$TD allows executables"; fi
TFREE=$(( $(df -Pk "$TD" 2>/dev/null | awk 'NR==2{print $4}') / 1024 ))
if [ "${TFREE:-0}" -ge 1024 ]; then pass "$TD has ${TFREE} MB free for npm caches and builds"; else warn_ "$TD has only ${TFREE:-0} MB free (npm install/build may need ~1 GB)"; fi
if [ -L "$LLM_ROOT" ]; then block "$LLM_ROOT is a symlink: refusing to deploy through it"; fi
UM="$(umask)"
if [ $(( 8#$UM & 8#022 )) -ne $(( 8#022 )) ]; then warn_ "umask $UM is permissive: files created by manual steps would be group/world-writable (the toolkit sets its own modes, but use umask 022 or stricter for the manual steps)"; else pass "umask $UM"; fi
if is_root; then
  PD="$LLM_ROOT"; while [ ! -e "$PD" ] && [ "$PD" != "/" ]; do PD="$(dirname "$PD")"; done
  if [ -w "$PD" ]; then pass "can write under $PD (needed to create $LLM_ROOT)"; else block "cannot write under $PD"; fi
  if [ -d "$SYSTEMD_DIR" ] && [ -w "$SYSTEMD_DIR" ]; then pass "can write unit files to $SYSTEMD_DIR"; else warn_ "$SYSTEMD_DIR is missing or not writable: the units step would fail"; fi
else info_ "not root: write permission to $LLM_ROOT and $SYSTEMD_DIR cannot be tested (deploy steps need root)"; fi

head_ "Required tools"
for t in curl git tar sha256sum useradd userdel runuser install; do if have "$t"; then pass "$t present"; else block "$t missing (install via apt = a system change; needs separate approval)"; fi; done
for t in ss ionice nice flock; do have "$t" && pass "$t present" || warn_ "$t missing (optional; fallbacks exist)"; done
have gpg || have age && pass "gpg/age present (encrypted backup export possible)" || warn_ "neither gpg nor age present: encrypted backup export unavailable"
have openssl && pass "openssl present (secret generation)" || warn_ "openssl missing: secrets fall back to /dev/urandom (still fine)"
if have make && { have g++ || have gcc; } && have python3; then pass "native build toolchain present (make, a C++ compiler, python3)"; else warn_ "no native build toolchain (make + g++/gcc + python3): fine when npm finds prebuilt binaries for $(uname -m)/glibc $GLIBC, but a native module without one would fail to build"; fi
CAB="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
if [ -s "$CAB" ]; then pass "CA certificate bundle present ($CAB)"; else warn_ "no CA bundle at $CAB: HTTPS downloads (Node, npm, git) may fail verification (never disable verification; install ca-certificates)"; fi
if have timedatectl; then
  case "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" in
    yes) pass "system clock is NTP-synchronised" ;;
    no)  warn_ "system clock is not NTP-synchronised: TLS certificate validation can fail on a drifting clock" ;;
    *)   info_ "clock synchronisation state unknown (timedatectl gave no answer)" ;;
  esac
fi
have node && info_ "system node: $(node -v 2>/dev/null) (NOT used: the toolkit installs its own pinned Node under $LLM_ROOT/runtime)" || info_ "no system node (fine: pinned Node is installed under $LLM_ROOT/runtime)"
if is_root; then pass "running as root (can see process names)"; elif have sudo && sudo -n true 2>/dev/null; then pass "passwordless sudo available"; else info_ "not root and no passwordless sudo: deploy steps need root"; fi

head_ "Network (reachability only)"
if [ "$OFFLINE" = 1 ]; then info_ "skipped (--offline)"; else
  netdiag() { # netdiag URL HTTPCODE -> says WHY it failed (DNS vs connect/TLS vs HTTP status)
    local h="${1#*://}"; h="${h%%/*}"
    if [ "$2" = 000 ]; then
      if have getent && ! getent hosts "$h" >/dev/null 2>&1; then echo "DNS failure: $h does not resolve (check /etc/resolv.conf / outbound DNS)"
      else echo "connection or TLS failure to $h (firewall, proxy, wrong clock or missing CA bundle?)"; fi
    else echo "HTTP $2 from $h"; fi
  }
  U="$NODE_DIST_URL/v$NODE_VERSION/SHASUMS256.txt"; c="$(HTTP_TIMEOUT=20 http_code "$U")"; [ "$c" = 200 ] && pass "nodejs.org dist reachable" || block "nodejs.org dist: $(netdiag "$U" "$c")"
  U=https://registry.npmjs.org/omniroute; c="$(HTTP_TIMEOUT=20 http_code "$U")"; [ "$c" = 200 ] && pass "npm registry reachable" || block "npm registry: $(netdiag "$U" "$c")"
  if timeout 40 git ls-remote --heads https://github.com/tashfeenahmed/freellmapi.git HEAD >/dev/null 2>&1; then pass "git can reach tashfeenahmed/freellmapi"; else block "git cannot reach tashfeenahmed/freellmapi ($(netdiag https://github.com 000 | sed 's/^connection or TLS failure to github.com/connection or TLS failure to github.com/'))"; fi
fi

head_ "Ports (this toolkit binds loopback only)"
info_ "listening sockets now:"
while IFS= read -r l; do emit "$l"; done < <(listeners | sort -t$'\t' -k2n | awk -F'\t' '{printf "         %s:%s %s\n",$1,$2,($3==""?"":"("$3")")}')
if ! is_root && ! have ss; then info_ "process names unavailable (no ss and not root)"; fi
PF="$REQ_FL"; [ -n "$PF" ] || PF="$DEFAULT_PORT_FREELLMAPI"; PO="$REQ_OM"; [ -n "$PO" ] || PO="$DEFAULT_PORT_OMNIROUTE"
[ "$PF" != "$PO" ] || block "both gateways were given port $PF"
for spec in "freellmapi:$PF:$ALT_PORTS_FREELLMAPI" "omniroute:$PO:$ALT_PORTS_OMNIROUTE"; do
  g="${spec%%:*}"; rest="${spec#*:}"; p="${rest%%:*}"; alts="${rest#*:}"
  if port_listening "$p"; then
    ALT="$(EXCLUDE_PORTS="$PF $PO" pick_free_port "${alts%% *}" "${alts#* }")" || ALT=""
    block "port $p for $g is already in use by something else; proposal: use ${ALT:-<none free>} (re-run with --$g-port)"
  else pass "port $p free for $g (will bind 127.0.0.1 only)"; fi
done
# The optional free-only guards (vps/free-install.sh) bind two more loopback ports; report conflicts now instead of at install time.
GPF="${GUARD_PORT_FREELLMAPI:-3101}"; GPO="${GUARD_PORT_OMNIROUTE:-20228}"
for spec in "freellmapi guard:$GPF" "omniroute guard:$GPO"; do
  nm="${spec%%:*}"; p="${spec##*:}"
  if port_listening "$p"; then warn_ "port $p for the optional $nm is already in use (free-install.sh would refuse; set GUARD_PORT_* to another free port)"; else pass "port $p free for the optional $nm"; fi
done
# A fixed port inside the kernel's ephemeral range can be taken by an outgoing connection at the moment a service starts.
read -r EPLO EPHI < "${PORT_RANGE_FILE:-/proc/sys/net/ipv4/ip_local_port_range}" 2>/dev/null
RESV="$(cat "${RESERVED_PORTS_FILE:-/proc/sys/net/ipv4/ip_local_reserved_ports}" 2>/dev/null)"
in_reserved() { local p="$1" r lo hi; for r in $(printf '%s' "$RESV" | tr ',' ' '); do lo="${r%-*}"; hi="${r#*-}"; [ "$p" -ge "$lo" ] 2>/dev/null && [ "$p" -le "$hi" ] 2>/dev/null && return 0; done; return 1; }
if [ -n "${EPLO:-}" ] && [ -n "${EPHI:-}" ]; then
  for p in "$PF" "$PO" "$GPF" "$GPO"; do
    if [ "$p" -ge "$EPLO" ] && [ "$p" -le "$EPHI" ] && ! in_reserved "$p"; then warn_ "port $p lies inside the ephemeral range ${EPLO}-${EPHI}: an outgoing connection could occupy it when a service starts (pick a port below $EPLO or reserve it via net.ipv4.ip_local_reserved_ports)"; fi
  done
fi
emit "PROPOSED_PORT_FREELLMAPI=$PF"; emit "PROPOSED_PORT_OMNIROUTE=$PO"

head_ "Existing services (read-only detection; nothing is touched)"
PAT='suppar|earnix|n8n|caddy'
if have docker; then
  if DPS="$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null)"; then
    n="$(printf '%s' "$DPS" | grep -c . )"; info_ "docker: $n container(s) visible; $(docker volume ls -q 2>/dev/null | grep -c .) volume(s)"
    while IFS='|' read -r nm img st pt; do emit "[INFO ]   container $nm  image=$img  status=$st  ports=${pt:-none}"; done < <(printf '%s\n' "$DPS" | grep -iE "$PAT")
    pass "docker readable; our install does not use Docker at all"
  else warn_ "docker present but not readable by this user (run preflight as root/docker-group for container detail)"; fi
else info_ "docker CLI not found"; fi
if have systemctl && [ -d "$SYSTEMD_RUN_DIR" ]; then
  while read -r u a s; do emit "[INFO ]   unit $u active=$a/$s"; done < <(systemctl list-units --type=service --all --no-legend --plain 2>/dev/null | awk '{print $1, $3, $4}' | grep -iE "$PAT|docker")
fi
while read -r c; do emit "[INFO ]   process name: $c"; done < <(ps -eo comm= 2>/dev/null | sort -u | grep -iE "$PAT")
for f in /etc/caddy/Caddyfile /etc/caddy; do [ -e "$f" ] && emit "[INFO ]   caddy config present: $f (never modified by this toolkit)"; done
emit "[INFO ] SUPPAR/EARNIX/n8n are matched by name only; absence above does not prove absence. Their ports are taken from the listener list."

head_ "Existing footprint of this toolkit (idempotency)"
for g in freellmapi omniroute; do
  u="$(gw_user "$g")"
  if getent passwd "$u" >/dev/null; then
    h="$(getent passwd "$u" | cut -d: -f6)"
    [ "$h" = "$LLM_ROOT/$g" ] && warn_ "user $u already exists with the expected home (re-run is idempotent)" || block "user $u exists with a DIFFERENT home ($h): refusing to reuse"
  else pass "user $u does not exist (will be created)"; fi
done
[ -e "$LLM_ROOT" ] && warn_ "$LLM_ROOT already exists" || pass "$LLM_ROOT does not exist"
# Unit files that already carry one of OUR names: ours (rendered by this toolkit) is an idempotent re-run; anything else would be overwritten.
for f in "$SYSTEMD_DIR"/llm-freellmapi.service "$SYSTEMD_DIR"/llm-omniroute.service "$SYSTEMD_DIR"/llm-guard-*.service "$SYSTEMD_DIR"/llm-free-audit-*.service "$SYSTEMD_DIR"/llm-free-audit-*.timer "$SYSTEMD_DIR"/llm-backup@.* "$SYSTEMD_DIR"/llm-monitor.*; do
  [ -e "$f" ] || continue
  if grep -qE "Rendered by vps/|$LLM_ROOT/toolkit" "$f" 2>/dev/null; then warn_ "$(basename "$f") already installed by this toolkit (re-run is idempotent)"
  else block "$(basename "$f") exists in $SYSTEMD_DIR but was NOT created by this toolkit: refusing to overwrite it"; fi
done

head_ "Summary"
RESULT="PASS"; [ "$NW" -gt 0 ] && RESULT="PASS-WITH-WARNINGS"; [ "$NB" -gt 0 ] && RESULT="BLOCKED"
emit "pass=$NP warn=$NW block=$NB"
emit "RESULT: $RESULT"
if [ -n "$OUT" ]; then ( umask 077; printf '%s' "$REPORT" > "$OUT" ); info "report saved to $OUT"; fi
[ "$NB" -eq 0 ]
