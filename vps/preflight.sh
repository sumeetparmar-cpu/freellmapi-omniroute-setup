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
else warn_ "not Ubuntu $TARGET_OS_VERSION (found ${OSID:-unknown} ${OSVER:-unknown}); this toolkit was exercised only on Ubuntu 24.04. Decision rests on the functional checks below, not on the version string"; fi
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
D="$LLM_ROOT"; while [ ! -d "$D" ] && [ "$D" != "/" ]; do D="$(dirname "$D")"; done
FREE_KB="$(df -Pk "$D" 2>/dev/null | awk 'NR==2{print $4}')"; FREE_GB=$(( ${FREE_KB:-0} / 1024 / 1024 ))
if [ "$FREE_GB" -ge "$WARN_DISK_GB" ]; then pass "disk free ${FREE_GB} GB on the filesystem holding $D"; elif [ "$FREE_GB" -ge "$MIN_DISK_GB" ]; then warn_ "disk free ${FREE_GB} GB < ${WARN_DISK_GB} GB (measured need: ~0.6 GB FreeLLMAPI + up to ~2.7 GB OmniRoute + backups)"; else block "disk free ${FREE_GB} GB < ${MIN_DISK_GB} GB"; fi
FREE_INODES="$(df -Pi "$D" 2>/dev/null | awk 'NR==2{print $4}')"; if [ "${FREE_INODES:-0}" -ge 300000 ]; then pass "free inodes ${FREE_INODES} (node_modules is file-heavy)"; else warn_ "free inodes ${FREE_INODES:-unknown} < 300000"; fi

head_ "Required tools"
for t in curl git tar sha256sum useradd userdel runuser install; do if have "$t"; then pass "$t present"; else block "$t missing (install via apt = a system change; needs separate approval)"; fi; done
for t in ss ionice nice flock; do have "$t" && pass "$t present" || warn_ "$t missing (optional; fallbacks exist)"; done
have gpg || have age && pass "gpg/age present (encrypted backup export possible)" || warn_ "neither gpg nor age present: encrypted backup export unavailable"
have node && info_ "system node: $(node -v 2>/dev/null) (NOT used: the toolkit installs its own pinned Node under $LLM_ROOT/runtime)" || info_ "no system node (fine: pinned Node is installed under $LLM_ROOT/runtime)"
if is_root; then pass "running as root (can see process names)"; elif have sudo && sudo -n true 2>/dev/null; then pass "passwordless sudo available"; else info_ "not root and no passwordless sudo: deploy steps need root"; fi

head_ "Network (reachability only)"
if [ "$OFFLINE" = 1 ]; then info_ "skipped (--offline)"; else
  c="$(HTTP_TIMEOUT=20 http_code "$NODE_DIST_URL/v$NODE_VERSION/SHASUMS256.txt")"; [ "$c" = 200 ] && pass "nodejs.org dist reachable" || block "nodejs.org dist -> HTTP $c"
  c="$(HTTP_TIMEOUT=20 http_code https://registry.npmjs.org/omniroute)"; [ "$c" = 200 ] && pass "npm registry reachable" || block "npm registry -> HTTP $c"
  if timeout 40 git ls-remote --heads https://github.com/tashfeenahmed/freellmapi.git HEAD >/dev/null 2>&1; then pass "git can reach tashfeenahmed/freellmapi"; else block "git cannot reach tashfeenahmed/freellmapi"; fi
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

head_ "Summary"
RESULT="PASS"; [ "$NW" -gt 0 ] && RESULT="PASS-WITH-WARNINGS"; [ "$NB" -gt 0 ] && RESULT="BLOCKED"
emit "pass=$NP warn=$NW block=$NB"
emit "RESULT: $RESULT"
if [ -n "$OUT" ]; then ( umask 077; printf '%s' "$REPORT" > "$OUT" ); info "report saved to $OUT"; fi
[ "$NB" -eq 0 ]
