#!/usr/bin/env bash
# READ-ONLY inventory of what already runs on the host, plus an integrity comparison against an earlier snapshot.
# Records identities and hashes only: never file contents, environment variables, or secrets.
#
#   inventory.sh snapshot [--out FILE] [--watch PATH]... [--hash FILE]... [--ignore REGEX]...
#   inventory.sh compare  BASELINE [--ignore REGEX]...      (re-takes a snapshot with the baseline's own options and diffs)
#   inventory.sh diff     A B
#
# Static sections (docker containers/volumes/networks, unit files, users, docker/sudo group membership, hashes of config files,
# identity of watched paths) must be identical: any change => exit 1.
# Dynamic sections (listening sockets) are reported as WARN only. Our own users, llm-* units, /srv/llm paths and our ports are ignored.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vps-common.sh
. "$HERE/lib/vps-common.sh"

DEFAULT_HASH="/etc/caddy/Caddyfile /etc/crontab /etc/ssh/sshd_config /etc/sudoers /etc/docker/daemon.json /root/.ssh/authorized_keys"
base_ignore() { printf '%s' "(^|[|:/ ])(${LLM_USER_FREELLMAPI}|${LLM_USER_OMNIROUTE})([|: ]|$)|llm-(freellmapi|omniroute|monitor|backup)|${LLM_ROOT}"; }

# ---- snapshot ---------------------------------------------------------------------------------------
snapshot_body() { # snapshot_body "WATCH..." "HASH..."
  local watch="$1" hashes="$2" f p
  echo "opt|root|$(is_root && echo 1 || echo 0)"
  for p in $watch; do echo "opt|watch|$p"; done
  for p in $hashes; do echo "opt|hash|$p"; done
  echo "host|os|$(os_field ID)-$(os_field VERSION_ID)"
  if have docker && docker ps -a >/dev/null 2>&1; then
    docker ps -a --format 'docker-container|{{.Names}}|id={{.ID}} image={{.Image}} created={{.CreatedAt}}' 2>/dev/null
    docker volume ls -q 2>/dev/null | while read -r v; do docker volume inspect --format 'docker-volume|{{.Name}}|mount={{.Mountpoint}} driver={{.Driver}} created={{.CreatedAt}}' "$v" 2>/dev/null; done
    docker network ls --format 'docker-network|{{.Name}}|id={{.ID}} driver={{.Driver}}' 2>/dev/null
  else echo "docker|status|unavailable-or-not-readable"; fi
  if have systemctl && [ -d "$SYSTEMD_RUN_DIR" ]; then
    systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null | awk 'NF>=2{print "unit-file|"$1"|"$2}'
    systemctl list-unit-files --type=timer --no-legend --plain 2>/dev/null | awk 'NF>=2{print "unit-file|"$1"|"$2}'
  else echo "systemd|status|not-running"; fi
  getent passwd | awk -F: '{print "user|"$1"|uid="$3" home="$6" shell="$7}'
  for g in docker sudo adm; do getent group "$g" 2>/dev/null | awk -F: '{print "group|"$1"|members="$4}'; done
  for f in $hashes; do
    if [ -r "$f" ]; then echo "hash|$f|$(sha256sum "$f" | cut -d' ' -f1)"; elif [ -e "$f" ]; then echo "hash|$f|unreadable"; else echo "hash|$f|absent"; fi
  done
  for f in /etc/caddy/*.caddy /etc/caddy/conf.d/* /etc/cron.d/* /etc/sudoers.d/*; do [ -f "$f" ] && echo "hash|$f|$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"; done
  have ufw && is_root && echo "hash|ufw-status|$(ufw status verbose 2>/dev/null | sha256sum | cut -d' ' -f1)"
  for p in $watch; do
    if [ -e "$p" ]; then echo "path|$p|$(stat -c 'type=%F owner=%U:%G mode=%a inode=%i' "$p")"; echo "info|$p|$(stat -c 'size=%s mtime=%Y' "$p")"
    else echo "path|$p|absent"; fi
  done
  listeners | sort -u | awk -F'\t' '{print "listen|"$1":"$2"|"$3}'
}
cmd_snapshot() {
  local out="" watch="" hashes="$DEFAULT_HASH"
  while [ $# -gt 0 ]; do case "$1" in
    --out) out="$2"; shift;; --watch) watch="$watch $2"; shift;; --hash) hashes="$hashes $2"; shift;;
    --ignore) shift;; *) die "unknown option $1";; esac; shift; done
  local body; body="$(snapshot_body "$watch" "$hashes")"
  if [ -n "$out" ]; then ( umask 077; printf 'snapshot|taken|%s host=%s\n%s\n' "$(date -u +%FT%TZ)" "$(hostname)" "$body" > "$out" ); info "snapshot saved to $out ($(printf '%s\n' "$body" | wc -l) lines; identities and hashes only)"
  else printf '%s\n' "$body"; fi
}

# ---- compare ----------------------------------------------------------------------------------------
normalize() { # normalize FILE IGNORE_REGEX -> sorted comparable lines (no header/info)
  grep -vE '^(snapshot|info)\|' "$1" | grep -vE "$2" | sort
}
cmd_diff() { # cmd_diff A B IGNORE
  local a="$1" b="$2" ign="$3" na nb fails=0 warns=0 line
  na="$(mktemp)"; nb="$(mktemp)"
  normalize "$a" "$ign" > "$na"; normalize "$b" "$ign" > "$nb"
  while IFS= read -r line; do
    case "$line" in
      "<"*) kind="${line#< }"; sign="REMOVED";; ">"*) kind="${line#> }"; sign="ADDED";; *) continue;;
    esac
    if [ "${kind%%|*}" = listen ]; then warns=$((warns+1)); warn "listener $sign: ${kind#listen|}"
    else fails=$((fails+1)); err "$sign: $kind"; fi
  done < <(diff "$na" "$nb" | grep -E '^[<>]')
  rm -f "$na" "$nb"
  if [ "$fails" -eq 0 ]; then ok "integrity: no static differences ($warns listener warning(s))"; return 0; fi
  err "integrity: $fails static difference(s) vs baseline"; return 1
}
cmd_compare() {
  local base="${1:-}"; shift || true; [ -f "$base" ] || die "baseline not found: $base"
  local extra="" watch hashes now
  while [ $# -gt 0 ]; do case "$1" in --ignore) extra="$extra|$2"; shift;; *) die "unknown option $1";; esac; shift; done
  watch="$(awk -F'|' '$1=="opt"&&$2=="watch"{printf "%s ",$3}' "$base")"; hashes="$(awk -F'|' '$1=="opt"&&$2=="hash"{printf "%s ",$3}' "$base")"
  [ "$(awk -F'|' '$1=="opt"&&$2=="root"{print $3}' "$base")" = "$(is_root && echo 1 || echo 0)" ] || die "baseline was taken with different privileges (root vs non-root): re-run as the same user"
  now="$(mktemp)"; ( umask 077; { echo "snapshot|taken|compare"; snapshot_body "$watch" "$hashes"; } > "$now" )
  cmd_diff "$base" "$now" "$(base_ignore)$extra"; local rc=$?; rm -f "$now"; return $rc
}

case "${1:-}" in
  snapshot) shift; cmd_snapshot "$@" ;;
  compare)  shift; cmd_compare "$@" ;;
  diff)     [ -f "${2:-}" ] && [ -f "${3:-}" ] || die "usage: inventory.sh diff A B"; cmd_diff "$2" "$3" "$(base_ignore)" ;;
  ''|-h|--help) sed -n '2,13p' "$0" ;;
  *) die "unknown command $1" ;;
esac
