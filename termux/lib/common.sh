#!/usr/bin/env bash
# Shared helpers for the Termux (and generic Linux) gateway scripts.
# Source this file; do not execute it. It never prints or stores secrets in Git.
# shellcheck shell=bash

GW_HOME="${GW_HOME:-$HOME/llm-gateways}"
GW_CONFIG_DIR="$GW_HOME/config"
GW_RUN_DIR="$GW_HOME/run"
GW_LOG_DIR="$GW_HOME/logs"
GW_BACKUP_DIR="$GW_HOME/backups"
GW_STATE_DIR="$GW_HOME/state"

# Optional non-secret overrides (ports, pinned versions).
if [ -f "$GW_CONFIG_DIR/gateways.env" ]; then
  # shellcheck disable=SC1091
  while IFS='=' read -r _k _v; do
    case "$_k" in
      FREELLMAPI_PORT|OMNIROUTE_PORT|GATEWAY_BIND_HOST|FREELLMAPI_REF|OMNIROUTE_VERSION)
        # Environment variables set by the caller win over the file.
        [ -z "${!_k:-}" ] && export "$_k=$_v" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$GW_CONFIG_DIR/gateways.env" || true)
fi
FREELLMAPI_PORT="${FREELLMAPI_PORT:-3001}"
OMNIROUTE_PORT="${OMNIROUTE_PORT:-20128}"
GATEWAY_BIND_HOST="${GATEWAY_BIND_HOST:-127.0.0.1}"
FREELLMAPI_REF="${FREELLMAPI_REF:-main}"
OMNIROUTE_VERSION="${OMNIROUTE_VERSION:-latest}"

if [ -t 2 ]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_0=$'\e[0m'; else C_R=; C_G=; C_Y=; C_B=; C_0=; fi
info() { printf '%s[info]%s %s\n' "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[fail]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
is_termux() { [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux/files/usr ]; }

ensure_dirs() {
  umask 077
  mkdir -p "$GW_HOME" "$GW_CONFIG_DIR" "$GW_RUN_DIR" "$GW_LOG_DIR" "$GW_BACKUP_DIR" "$GW_STATE_DIR"
  chmod 700 "$GW_HOME" "$GW_CONFIG_DIR" "$GW_BACKUP_DIR" 2>/dev/null || true
}

# --- versions ---------------------------------------------------------------
node_version() { node -v 2>/dev/null | sed 's/^v//'; }
# ver_ge A B  -> true when A >= B (dotted numeric versions)
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }
ver_lt() { ! ver_ge "$1" "$2"; }

# Node ranges come from each upstream's package.json "engines" (checked 2026-10-29).
#   FreeLLMAPI: >=20.18.0 <25 ; Android additionally needs >=22.13 for node:sqlite.
#   OmniRoute : >=22.22.2 <23 || >=24.0.0 <27
node_ok_freellmapi() {
  local v="$1" min="20.18.0"
  is_termux && min="22.13.0"
  ver_ge "$v" "$min" && ver_lt "$v" "25.0.0"
}
node_ok_omniroute() {
  local v="$1"
  { ver_ge "$v" "22.22.2" && ver_lt "$v" "23.0.0"; } || { ver_ge "$v" "24.0.0" && ver_lt "$v" "27.0.0"; }
}
node_range_text() {
  case "$1" in
    freellmapi) if is_termux; then echo ">=22.13.0 <25 (Android needs node:sqlite)"; else echo ">=20.18.0 <25"; fi ;;
    omniroute)  echo ">=22.22.2 <23 || >=24.0.0 <27" ;;
  esac
}

# --- ports ------------------------------------------------------------------
# true when something accepts TCP connections on 127.0.0.1:PORT
port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
  return 1
}
assert_distinct_ports() {
  [ "$FREELLMAPI_PORT" != "$OMNIROUTE_PORT" ] || die "FREELLMAPI_PORT and OMNIROUTE_PORT are both $FREELLMAPI_PORT; they must differ."
  local p
  for p in "$FREELLMAPI_PORT" "$OMNIROUTE_PORT"; do
    case "$p" in ''|*[!0-9]*) die "Invalid port '$p'";; esac
    [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] || die "Port $p out of range 1024-65535"
  done
}

# --- env files (secrets live ONLY here, mode 600, never in Git) ---------------
gen_hex() { # gen_hex BYTES
  if have openssl; then openssl rand -hex "$1"
  elif have node; then node -e 'process.stdout.write(require("crypto").randomBytes(+process.argv[1]).toString("hex"))' "$1"
  else head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}
env_get() { # env_get FILE KEY
  [ -f "$1" ] || return 1
  grep -E "^$2=" "$1" | head -n1 | cut -d= -f2-
}
env_set() { # env_set FILE KEY VALUE  (atomic, 0600)
  local f="$1" k="$2" v="$3" tmp
  ( umask 077
    tmp="$(mktemp "$f.XXXXXX")"
    { [ -f "$f" ] && grep -vE "^$k=" "$f" || true; printf '%s=%s\n' "$k" "$v"; } > "$tmp"
    mv "$tmp" "$f" )
  chmod 600 "$f"
}
# Export every KEY=VALUE line of FILE into the environment without eval.
load_env_file() {
  local line k v
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in *[!A-Za-z0-9_]*|'') continue;; esac
    export "$k=$v"
  done < "$1"
}

# --- HTTP -------------------------------------------------------------------
http_code() { # http_code URL  -> prints status code (000 on failure; curl -w already prints 000 itself)
  local c; c="$(curl -sS -o /dev/null -m "${HTTP_TIMEOUT:-10}" -w '%{http_code}' "$1" 2>/dev/null)" || true
  printf '%s' "${c:-000}"
}
# json_get 'js expression over d' < json   (uses Node, which both gateways require)
json_get() { node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{const d=JSON.parse(s);const r=(function(){return eval(process.argv[1])})();process.stdout.write(r==null?"":String(r))}catch(e){process.exit(3)}})' "$1"; }

# --- processes --------------------------------------------------------------
pid_file() { echo "$GW_RUN_DIR/$1.pid"; }
gw_pid() { local f; f="$(pid_file "$1")"; [ -f "$f" ] && cat "$f" || true; }
# A killed process whose parent never reaped it stays a zombie, and kill -0 still succeeds on a zombie: treat state Z as "not running".
pid_alive() { # pid_alive PID
  kill -0 "$1" 2>/dev/null || return 1
  local st; st="$(sed -n 's/^[^)]*) \(.\).*/\1/p' "/proc/$1/stat" 2>/dev/null)"
  [ "$st" != Z ]
}
# daemon_start uses setsid, so everything a gateway spawns shares its process group (= the PID in the pid file). If only the supervisor
# is killed (Android's low-memory killer does that) the server child lives on as an orphan: it still serves the port and must still be stoppable.
group_alive() { # group_alive PGID : any non-zombie member?
  local f st pg
  for f in /proc/[0-9]*/stat; do
    read -r st _ pg _ < <(sed 's/^[0-9]* (.*) //' "$f" 2>/dev/null) || continue
    [ "${pg:-}" = "$1" ] && [ "${st:-}" != Z ] && return 0
  done
  return 1
}
gw_alive() { pid_alive "$1" || group_alive "$1"; }
gw_running() { local p; p="$(gw_pid "$1")"; [ -n "$p" ] && gw_alive "$p"; }
# daemon_start NAME LOGFILE cmd args...   (environment is inherited)
daemon_start() {
  local name="$1" log="$2"; shift 2
  ( umask 077
    if have setsid; then nohup setsid "$@" >>"$log" 2>&1 < /dev/null & else nohup "$@" >>"$log" 2>&1 < /dev/null & fi
    echo $! > "$(pid_file "$name")" )
}
gw_stop() { # gw_stop NAME [PORT]
  local name="$1" port="${2:-}" p i
  p="$(gw_pid "$name")"
  if [ -z "$p" ] || ! gw_alive "$p"; then rm -f "$(pid_file "$name")"; info "$name is not running"; return 0; fi
  # OmniRoute's CLI is a supervisor with a separate server child (older builds ignore SIGTERM once orphaned).
  # daemon_start uses setsid, so the whole process group (-PID) can be signalled; fall back to the single PID.
  kill -TERM -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do gw_alive "$p" || break; sleep 1; done
  if gw_alive "$p"; then warn "$name did not exit on SIGTERM; sending SIGKILL"; kill -KILL -- "-$p" 2>/dev/null || kill -9 "$p" 2>/dev/null || true; sleep 1; fi
  rm -f "$(pid_file "$name")"
  if [ -n "$port" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10; do port_in_use "$port" || break; sleep 1; done
    if port_in_use "$port"; then warn "port $port is still in use after stopping $name (an unrelated process may own it)"; fi
  fi
  ok "$name stopped"
}
# retry_cmd TRIES cmd args...  : mobile data and proxies drop long downloads (ECONNRESET); retry with a growing pause before giving up.
retry_cmd() {
  local tries="$1" n=1 rc; shift
  while :; do
    "$@"; rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$n" -ge "$tries" ] && return "$rc"
    warn "attempt $n/$tries failed (exit $rc); retrying in $((n * 10))s"; sleep $((n * 10)); n=$((n + 1))
  done
}
wait_for_http() { # wait_for_http URL SECONDS  -> 0 when HTTP 200
  local url="$1" n="${2:-60}" i
  for ((i = 0; i < n; i++)); do [ "$(http_code "$url")" = "200" ] && return 0; sleep 1; done
  return 1
}

# --- backups / state --------------------------------------------------------
timestamp() { date -u +%Y%m%dT%H%M%SZ; }
# backup_paths NAME LABEL PATH...  -> prints archive path. Archive may contain
# secrets (encryption keys, encrypted provider keys): it is created 0600 under $GW_BACKUP_DIR.
backup_paths() {
  local name="$1" label="$2"; shift 2
  local dir="$GW_BACKUP_DIR/$name" out tmp p rel=()
  mkdir -p "$dir"; chmod 700 "$dir"
  # Leftovers of a backup that was killed mid-write. They never end in .tar.gz, so they are never listed, restored or chosen as "latest".
  find "$dir" -maxdepth 1 -name '*.partial' -mmin +5 -delete 2>/dev/null || true
  out="$dir/$(timestamp)-$label.tar.gz"; tmp="$out.partial"
  for p in "$@"; do [ -e "$p" ] && rel+=("${p#/}"); done
  [ "${#rel[@]}" -gt 0 ] || { warn "nothing to back up for $name yet"; return 1; }
  # Write beside the final name, check tar's own exit status, verify the archive reads back, and only then rename (atomic on one filesystem).
  # A failed or truncated archive (disk full, OOM, power loss) is deleted instead of being reported as a successful backup.
  if ! ( umask 077; tar -C / -czf "$tmp" "${rel[@]}" ) || ! gzip -t "$tmp" 2>/dev/null || ! tar -tzf "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"; err "backup failed or produced an unreadable archive (disk full?); nothing was kept"; return 1
  fi
  chmod 600 "$tmp" && mv -- "$tmp" "$out"
  printf '%s\n' "$out"
}
# Newest backup that actually reads back: a truncated archive with a newer mtime must not shadow the last good one (that is what rollback needs).
latest_backup() {
  local f
  while IFS= read -r f; do if gzip -t "$f" 2>/dev/null; then printf '%s\n' "$f"; return 0; fi; done < <(ls -1t "$GW_BACKUP_DIR/$1"/*.tar.gz 2>/dev/null)
  return 0
}
list_backups() { ls -1t "$GW_BACKUP_DIR/$1"/*.tar.gz 2>/dev/null || info "no backups for $1"; }
# restore_archive ARCHIVE ALLOWED_PATH...  (caller must stop the gateway first)
# Archives record absolute paths (minus the leading "/"). Every entry must be one of the ALLOWED_PATHs
# or live beneath one, so a crafted archive cannot overwrite anything else (e.g. ~/.bashrc).
restore_archive() {
  local a="$1" entry ok p; shift
  [ -f "$a" ] || die "backup not found: $a"
  [ "$#" -gt 0 ] || die "restore_archive: no allowed paths given"
  tar -tzf "$a" >/dev/null || die "archive is corrupt: $a"
  while IFS= read -r entry; do
    case "$entry" in */../*|../*|*/..|..) die "archive contains '..' path '$entry'; refusing";; /*) die "archive contains absolute path '$entry'; refusing";; esac
    ok=0
    for p in "$@"; do
      p="${p#/}"; p="${p%/}"
      case "${entry%/}" in "$p"|"$p"/*) ok=1; break;; esac
    done
    [ "$ok" = 1 ] || die "archive contains unexpected entry '$entry' (outside the gateway's own config/data); refusing"
  done < <(tar -tzf "$a")
  # Replace allowed DIRECTORIES wholesale: a stale SQLite -wal/-shm from the newer version must not be
  # replayed against the restored older database. Guard against ever deleting something shallow.
  for p in "$@"; do
    if [ -d "$p" ] && [ "$(printf '%s' "$p" | tr -cd '/' | wc -c)" -ge 3 ]; then rm -rf -- "$p"; fi
  done
  tar -C / -xzf "$a"
}
confirm() { # confirm "question"  (auto-yes when ASSUME_YES=1)
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || die "non-interactive: pass --yes to confirm: $1"
  local a; read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]
}

# --- API key prompt (never echoed, never put on a command line) ---------------
read_api_key() { # read_api_key ENVVAR_NAME KEYFILE -> prints key on stdout
  local var="$1" file="${2:-}" k
  k="${!var:-}"
  if [ -z "$k" ] && [ -n "$file" ]; then [ -f "$file" ] || die "key file not found: $file"; k="$(head -n1 "$file")"; fi
  if [ -z "$k" ]; then
    [ -t 0 ] || die "No API key. Set \$$var, pass --key-file, or run interactively."
    read -r -s -p "Paste API key (input hidden): " k; printf '\n' >&2
  fi
  [ -n "$k" ] || die "empty API key"
  printf '%s' "$k"
}
# authed_curl KEY curl-args...   key goes via stdin config, so it never shows in `ps`.
authed_curl() {
  local key="$1"; shift
  printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -K - "$@"
}

# --- model-request test shared by both gateways -----------------------------
# model_test BASE_URL KEY MODEL
model_test() {
  local base="$1" key="$2" model="$3" out body code
  out="$(mktemp)"
  info "GET $base/v1/models (free; does not consume model quota)"
  code="$(authed_curl "$key" -sS -m 20 -o "$out" -w '%{http_code}' "$base/v1/models" 2>/dev/null)" || true
  code="${code:-000}"
  if [ "$code" != "200" ]; then err "/v1/models returned HTTP $code: $(head -c 300 "$out")"; rm -f "$out"; return 1; fi
  ok "/v1/models OK: $(json_get 'Array.isArray(d.data)?d.data.length+" models listed":"unexpected shape"' < "$out")"
  info "POST $base/v1/chat/completions model=$model max_tokens=16 (spends a tiny amount of upstream free-tier quota)"
  body="$(node -e 'process.stdout.write(JSON.stringify({model:process.argv[1],max_tokens:16,stream:false,messages:[{role:"user",content:"Reply with the single word OK."}]}))' "$model")"
  # stdin carries the key config (-K -), so the body must come from a file, not stdin.
  printf '%s' "$body" > "$out.req"
  code="$(authed_curl "$key" -sS -m "${MODEL_TEST_TIMEOUT:-90}" -o "$out" -w '%{http_code}' \
        -H 'Content-Type: application/json' --data-binary @"$out.req" "$base/v1/chat/completions" 2>/dev/null)" || true
  code="${code:-000}"
  rm -f "$out.req"
  if [ "$code" != "200" ]; then
    err "chat completion returned HTTP $code: $(head -c 400 "$out")"
    warn "Common causes: no provider key added yet, free-tier quota exhausted (HTTP 429), model unavailable."
    rm -f "$out"; return 2
  fi
  local text; text="$(json_get 'd.choices[0].message.content' < "$out")" || text=""
  [ -n "$text" ] || { err "HTTP 200 but no choices[0].message.content: $(head -c 300 "$out")"; rm -f "$out"; return 3; }
  rm -f "$out"
  ok "model replied: $(printf '%s' "$text" | head -c 120)"
}
