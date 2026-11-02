#!/usr/bin/env bash
# Runs ON the VPS (started by remote-survey.sh). READ-ONLY: reads system state, writes only inside its own temp dir (arg 1), prints a report.
# Never prints file contents of other services, environment variables, or secrets: names, ports, sizes and versions only.
set -uo pipefail
D="${1:?temp dir}"; cd "$D/vps" || exit 1
sec() { printf '\n=== %s ===\n' "$1"; }
sec "HOST"
echo "user=$(id -un) host=$(hostname) time=$(date -u +%FT%TZ)"; . /etc/os-release 2>/dev/null && echo "os=$PRETTY_NAME"; echo "kernel=$(uname -r) arch=$(uname -m) virt=$(systemd-detect-virt 2>/dev/null || echo unknown)"
echo "uptime=$(uptime -p 2>/dev/null)"; echo "init=$(ps -p 1 -o comm= 2>/dev/null) systemd=$(systemctl --version 2>/dev/null | head -1)"
sec "RESOURCES"
free -m | awk 'NR==1||/^Mem|^Swap/'; echo "cpus=$(nproc)"; df -h / /srv /var/lib/docker /tmp 2>/dev/null | awk '!seen[$0]++'
echo "cgroup=$(stat -fc %T /sys/fs/cgroup 2>/dev/null) overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null) load=$(cut -d' ' -f1-3 /proc/loadavg)"
echo "top memory users (name rss_MB):"; ps -eo comm,rss --sort=-rss 2>/dev/null | awk 'NR>1&&NR<=8{printf "  %s %d\n",$1,$2/1024}'
sec "LISTENING PORTS (tcp)"
ss -ltnp 2>/dev/null | awk 'NR==1||1' | sed -E 's/users:\(\(("[^"]+"),pid=[0-9]+,fd=[0-9]+\)\)/\1/' | cut -c1-110
echo "ports we want: 3001 20128 3101 20228 -> $(for p in 3001 20128 3101 20228; do ss -ltn 2>/dev/null | grep -q ":$p " && echo "$p=TAKEN" || echo "$p=free"; done | tr '\n' ' ')"
sec "SERVICES (running systemd units, names only)"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | head -40
echo "failed units: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"
echo "existing llm-* units: $(systemctl list-unit-files 2>/dev/null | awk '/^llm-/{print $1}' | tr '\n' ' ')"
sec "DOCKER (names/images/ports only)"
if command -v docker >/dev/null 2>&1; then docker ps --format '{{.Names}} | {{.Image}} | {{.Ports}}' 2>&1 | head -30; echo "volumes=$(docker volume ls -q 2>/dev/null | wc -l) networks=$(docker network ls -q 2>/dev/null | wc -l)"; else echo "docker not installed"; fi
sec "EDGE / APPS (presence only)"
for p in /etc/caddy/Caddyfile /etc/nginx /etc/traefik; do [ -e "$p" ] && echo "present: $p"; done
command -v caddy >/dev/null && echo "caddy=$(caddy version 2>/dev/null | head -1)"; command -v node >/dev/null && echo "system node=$(node -v)"; command -v git >/dev/null && echo "git=$(git --version)"; command -v curl >/dev/null && echo "curl present"
echo "firewall: $(ufw status 2>/dev/null | head -1 || true) $(command -v nft >/dev/null && echo 'nft present')"
echo "ssh password auth: $(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
sec "TOOLKIT PREFLIGHT (read-only)"
./preflight.sh --out "$D/preflight.txt" 2>&1 | sed -n '1,200p'
echo "preflight exit=$?"
sec "TOOLKIT INVENTORY SNAPSHOT (identities only, stored in the temp dir)"
./inventory.sh snapshot --out "$D/baseline.snap" 2>&1 | tail -n 15
sec "END (temp dir will be removed)"
