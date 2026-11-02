#!/usr/bin/env bash
# Runs ON the VPS (started by remote-survey.sh). READ-ONLY: reads system state, writes only inside its own temp dir (arg 1), prints a report.
# Never prints file contents of other services, environment variables, or secrets: names, ports, sizes and versions only.
set -uo pipefail
D="${1:?temp dir}"; FLP="${2:-3001}"; OMP="${3:-20128}"; CNAME="${4:-}"; GFL=3101; GOM=20228; cd "$D/vps" || exit 1
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
echo "ports we want: $FLP $OMP $GFL $GOM -> $(for p in $FLP $OMP $GFL $GOM; do ss -ltn 2>/dev/null | grep -q ":$p " && echo "$p=TAKEN" || echo "$p=free"; done | tr '\n' ' ')"
echo "who listens on our candidate and default ports (address:port; loopback-only means 127.0.0.1):"; ss -ltn 2>/dev/null | awk -v re=":($FLP|$OMP|$GFL|$GOM|3001)$" 'NR>1&&$4 ~ re{print "  "$4}' 
sec "SERVICES (running systemd units, names only)"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | head -40
echo "failed units: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"
echo "existing llm-* units: $(systemctl list-unit-files 2>/dev/null | awk '/^llm-/{print $1}' | tr '\n' ' ')"
sec "DOCKER (names/images/ports only)"
if command -v docker >/dev/null 2>&1; then docker ps --format '{{.Names}} | {{.Image}} | {{.Ports}}' 2>&1 | head -30; echo "volumes=$(docker volume ls -q 2>/dev/null | wc -l) networks=$(docker network ls -q 2>/dev/null | wc -l)"; else echo "docker not installed"; fi
if [ -n "$CNAME" ] && command -v docker >/dev/null 2>&1; then
sec "EXISTING CONTAINER $CNAME (read-only: no env values, no file contents beyond masked compose structure)"
case "$CNAME" in *[!A-Za-z0-9_.-]*) echo "bad container name"; CNAME="";; esac
fi
if [ -n "$CNAME" ] && command -v docker >/dev/null 2>&1; then
  echo "  container id: $(docker inspect "$CNAME" --format '{{.Id}}' 2>/dev/null | cut -c1-12)"
  img=$(docker inspect "$CNAME" --format '{{.Config.Image}}' 2>/dev/null); echo "  image repo digests: $(docker image inspect "$img" --format '{{json .RepoDigests}}' 2>/dev/null)"
  docker inspect "$CNAME" --format 'image={{.Config.Image}}{{"\n"}}imageId={{.Image}}{{"\n"}}created={{.Created}}{{"\n"}}status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} started={{.State.StartedAt}}{{"\n"}}restartPolicy={{.HostConfig.RestartPolicy.Name}} memLimit={{.HostConfig.Memory}} nanoCpus={{.HostConfig.NanoCpus}}{{"\n"}}user={{.Config.User}} readonlyRootfs={{.HostConfig.ReadonlyRootfs}} privileged={{.HostConfig.Privileged}}{{"\n"}}networks={{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}{{"\n"}}ports={{json .NetworkSettings.Ports}}{{"\n"}}cmd={{json .Config.Cmd}} entrypoint={{json .Config.Entrypoint}}' 2>&1 | sed 's/^/  /'
  echo "  mounts (type source -> destination):"; docker inspect "$CNAME" --format '{{range .Mounts}}    {{.Type}} {{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}' 2>&1
  echo "  environment variable NAMES only (values are never printed):"; docker inspect "$CNAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | cut -d= -f1 | sort | sed 's/^/    /'
  echo "  labels (compose + image):"; docker inspect "$CNAME" --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null | grep -E '^(com\.docker\.compose\.(project|service|version)|org\.opencontainers\.image\.(version|title|source|revision))' | sed 's/^/    /'
  echo "  live health endpoints on the published port (GET only):"
  for ep in /api/ping /api/health /api/version; do printf '    %s -> ' "$ep"; curl -s -m5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3001$ep" 2>/dev/null; echo; done
  printf '    /api/ping body: '; curl -s -m5 "http://127.0.0.1:3001/api/ping" 2>/dev/null | head -c 200; echo
  echo "  resource use now (docker stats, one sample, ALL containers):"; docker stats --no-stream --format '    {{.Name}}  mem={{.MemUsage}}  cpu={{.CPUPerc}}' 2>&1 | head -20
  echo "  docker disk usage:"; docker system df 2>&1 | sed 's/^/    /'
  cf=$(docker inspect "$CNAME" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null | cut -d, -f1)
  if [ -n "$cf" ] && [ -r "$cf" ]; then
    echo "  compose file $cf: STRUCTURE ONLY (environment blocks and any line naming key/token/secret/password are hidden):"
    awk '/^[[:space:]]*(environment|env_file|secrets|configs):/{skip=match($0,/[^ ]/); next} skip&&match($0,/[^ ]/)>skip{next} {skip=0; print}' "$cf" | sed -E 's/((key|token|secret|pass(word)?)[A-Za-z_]*[:=][[:space:]]*).*/\1<hidden>/I' | sed 's/^/    /' | head -60
    echo "  env_file referenced: $(grep -cE '^[[:space:]]*env_file:' "$cf") (contents never read)"
  else echo "  compose file not readable here ($cf)"; fi
  echo "  host memory/disk headroom for the new stack: see RESOURCES above"
fi
sec "WHO OWNS PORT 3001 (docker, metadata only: no env vars, no file contents)"
if command -v docker >/dev/null 2>&1; then
  ids=$(docker ps -q --filter publish=3001 2>/dev/null); [ -n "$ids" ] || echo "no running container publishes 3001"
  for id in $ids; do
    docker inspect "$id" --format 'name={{.Name}}{{"\n"}}image={{.Config.Image}}{{"\n"}}status={{.State.Status}} started={{.State.StartedAt}} restartPolicy={{.HostConfig.RestartPolicy.Name}}{{"\n"}}ports={{json .NetworkSettings.Ports}}{{"\n"}}networkMode={{.HostConfig.NetworkMode}}{{"\n"}}compose.project={{index .Config.Labels "com.docker.compose.project"}}{{"\n"}}compose.service={{index .Config.Labels "com.docker.compose.service"}}{{"\n"}}compose.workdir={{index .Config.Labels "com.docker.compose.project.working_dir"}}{{"\n"}}compose.files={{index .Config.Labels "com.docker.compose.project.config_files"}}{{"\n"}}memLimit={{.HostConfig.Memory}}' 2>&1 | sed 's/^/  /'
  done
  echo "all containers (name | status):"; docker ps -a --format '  {{.Names}} | {{.Status}}' 2>/dev/null | head -30
else echo "docker not installed"; fi
sec "SERVICES OF INTEREST (names/status/images/ports only)"
if command -v docker >/dev/null 2>&1; then docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}' 2>/dev/null | grep -iE 'n8n|suppar|earnix|caddy|postgres|mysql|maria|mongo|redis|db' | sed 's/^/  /'; echo "  compose projects: $(docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u | grep . | tr '\n' ' ')"; fi
for u in caddy nginx postgresql mysql mariadb mongod redis-server docker; do systemctl is-active "$u" >/dev/null 2>&1 && echo "  host service active: $u"; done
sec "NETWORK EXPOSURE (non-loopback listeners; process names only)"
ss -ltnp 2>/dev/null | awk 'NR>1 && $4 !~ /^(127\.|\[::1\])/ {print "  "$4"  "$NF}' | sed -E 's/users:\(\(("[^"]+").*/\1/' | head -30
echo "  docker ports published on non-loopback addresses:"; docker ps --format '  {{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0|:::' | head -20
echo "  swap: $(swapon --show --noheadings 2>/dev/null | wc -l) device(s); vm.swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)"
sec "FIREWALL (read-only listing)"
echo "ufw: $(ufw status verbose 2>&1 | head -12 | tr '\n' ';')"
command -v nft >/dev/null && echo "nft rule count: $(nft list ruleset 2>/dev/null | grep -c . )"
command -v iptables >/dev/null && echo "iptables INPUT policy: $(iptables -S INPUT 2>/dev/null | head -1)"
echo "(this toolkit binds 127.0.0.1 only, so it needs no firewall change)"
sec "EDGE / APPS (presence only)"
for p in /etc/caddy/Caddyfile /etc/nginx /etc/traefik; do [ -e "$p" ] && echo "present: $p"; done
command -v caddy >/dev/null && echo "caddy=$(caddy version 2>/dev/null | head -1)"; command -v node >/dev/null && echo "system node=$(node -v)"; command -v git >/dev/null && echo "git=$(git --version)"; command -v curl >/dev/null && echo "curl present"
echo "firewall: $(ufw status 2>/dev/null | head -1 || true) $(command -v nft >/dev/null && echo 'nft present')"
echo "ssh password auth: $(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
sec "TOOLKIT PREFLIGHT (read-only)"
./preflight.sh --freellmapi-port "$FLP" --omniroute-port "$OMP" --out "$D/preflight.txt" 2>&1 | sed -n '1,200p'
echo "preflight exit=$?"
sec "TOOLKIT INVENTORY SNAPSHOT (identities only, stored in the temp dir)"
./inventory.sh snapshot --out "$D/baseline.snap" 2>&1 | tail -n 15
sec "PREFLIGHT WARNINGS / BLOCKS (exact lines)"
grep -E '^\[(WARN|BLOCK)' "$D/preflight.txt" 2>/dev/null | sed 's/^/  /'; grep -E '^(RESULT|pass=)' "$D/preflight.txt" 2>/dev/null | sed 's/^/  /'
sec "END (temp dir will be removed)"
