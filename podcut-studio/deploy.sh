#!/usr/bin/env bash
# PodCut Studio — isolated installer for an existing Ubuntu/Debian VPS.
#
# What it does (and nothing else):
#   - creates a dedicated unprivileged user `podcutsvc` (a UID no process uses)
#   - installs the app under /opt/podcut-studio in its own Python venv
#   - runs it as a systemd service bound to 127.0.0.1 only, with CPU/memory caps
#     and low priority so a render never starves your other services
#   - adds ONE reverse-proxy block for your subdomain to Caddy, after backing the
#     Caddyfile up and validating the result; it reloads Caddy (never restarts)
#
# What it never touches: your existing users, services, databases, Docker, or any
# existing Caddy site. Re-runnable. Undo with uninstall.sh.
set -euo pipefail

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Run as root:  sudo bash deploy.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/app.py" ] && [ -f "$HERE/podcut.py" ] || die "app.py and podcut.py must sit next to this script."

SVC_USER=podcutsvc
APP_DIR=/opt/podcut-studio
DATA_DIR=$APP_DIR/data
ENV_FILE=$APP_DIR/podcut.env
UNIT=/etc/systemd/system/podcut-studio.service
CADDYFILE=/etc/caddy/Caddyfile

# ---- inputs ----
say "PodCut Studio installer"
read -rp "Subdomain to serve it on (e.g. studio.suppar.tech): " APP_HOST
[ -n "${APP_HOST:-}" ] || die "A subdomain is required."
echo "$APP_HOST" | grep -qE '^[a-z0-9.-]+\.[a-z]{2,}$' || die "That does not look like a domain."
read -rsp "Choose a login password (won't echo): " PW1; echo
read -rsp "Repeat the password: " PW2; echo
[ -n "$PW1" ] && [ "$PW1" = "$PW2" ] || die "Passwords empty or do not match."
read -rp "Max upload size in GB [5]: " MAX_GB; MAX_GB=${MAX_GB:-5}

# ---- prerequisites (ffmpeg + python venv) ----
say "1/6 checking prerequisites"
command -v ffmpeg >/dev/null || { apt-get update -qq && apt-get install -y -qq ffmpeg; }
command -v ffmpeg >/dev/null || die "ffmpeg is required and could not be installed."
PY=$(command -v python3) || die "python3 is required."
if ! "$PY" -c 'import venv,ensurepip' 2>/dev/null; then
  echo "  installing python3-venv (the only system package this needs)"
  apt-get update -qq && apt-get install -y -qq python3-venv python3-pip
fi
echo "  ffmpeg: $(command -v ffmpeg) | python: $PY"

# ---- isolated user ----
say "2/6 isolated service user ($SVC_USER) with a UID no running process uses"
if ! id "$SVC_USER" >/dev/null 2>&1; then
  NEW=""; for u in $(seq 4810 4899); do
    getent passwd "$u" >/dev/null || getent group "$u" >/dev/null || ps -eo uid= | tr -d ' ' | grep -qx "$u" || { NEW=$u; break; }
  done
  [ -n "$NEW" ] || die "no free UID found"
  groupadd -g "$NEW" "$SVC_USER"
  useradd -u "$NEW" -g "$SVC_USER" --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
fi
echo "  $SVC_USER uid=$(id -u "$SVC_USER")"

# ---- pick a free loopback port ----
PORT=""; for p in $(seq 8820 8839); do ss -ltn 2>/dev/null | grep -qE "127.0.0.1:$p\b|:::$p\b|0.0.0.0:$p\b" || { PORT=$p; break; }; done
[ -n "$PORT" ] || die "no free port in 8820-8839"

# ---- files + venv ----
say "3/6 installing app to $APP_DIR (loopback port $PORT)"
systemctl stop podcut-studio 2>/dev/null || true
install -d -m 755 "$APP_DIR"
install -m 644 "$HERE/app.py" "$HERE/podcut.py" "$APP_DIR/"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 750 "$DATA_DIR"
if [ ! -x "$APP_DIR/.venv/bin/python" ]; then "$PY" -m venv "$APP_DIR/.venv"; fi
"$APP_DIR/.venv/bin/pip" install -q --disable-pip-version-check --upgrade pip >/dev/null
"$APP_DIR/.venv/bin/pip" install -q --disable-pip-version-check flask
echo "  flask $("$APP_DIR/.venv/bin/python" -c 'import importlib.metadata as m;print(m.version("flask"))')"

# ---- secrets / env (mode 600, never in git) ----
say "4/6 writing config (secrets stay in $ENV_FILE, mode 600)"
SECRET=$("$PY" -c 'import secrets;print(secrets.token_hex(32))')
PWHASH=$(PW="$PW1" "$PY" - <<'PY'
import hashlib, os, secrets
s = secrets.token_bytes(16); it = 200000
dk = hashlib.pbkdf2_hmac("sha256", os.environ["PW"].encode(), s, it)
print(f"{it}${s.hex()}${dk.hex()}")
PY
)
umask 077
cat > "$ENV_FILE" <<EOF
PODCUT_SECRET=$SECRET
PODCUT_PWHASH=$PWHASH
PODCUT_DATA_DIR=$DATA_DIR
PODCUT_PORT=$PORT
PODCUT_MAX_GB=$MAX_GB
PODCUT_KEEP_HOURS=12
PODCUT_PRESET=veryfast
PODCUT_CRF=21
EOF
chown "$SVC_USER:$SVC_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"
unset PW1 PW2 PW SECRET PWHASH

# ---- systemd unit with resource limits + sandbox ----
say "5/6 systemd service (CPU/memory capped, low priority, sandboxed, loopback only)"
cat > "$UNIT" <<EOF
[Unit]
Description=PodCut Studio (isolated podcast editor)
After=network.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/app.py
Restart=on-failure
RestartSec=3
# never starve your other services
Nice=15
CPUWeight=20
CPUQuota=130%
MemoryMax=1500M
IOSchedulingClass=idle
# sandbox
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA_DIR
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now podcut-studio >/dev/null 2>&1 || systemctl enable podcut-studio
sleep 2
systemctl is-active --quiet podcut-studio && echo "  service active on 127.0.0.1:$PORT" || { journalctl -u podcut-studio -n 20 --no-pager; die "service did not start"; }

# ---- Caddy: additive, backed up, validated ----
say "6/6 wiring the subdomain through Caddy"
BEGIN="# >>> podcut-studio (added by deploy; safe to remove) >>>"
END="# <<< podcut-studio <<<"
BLOCK="$BEGIN
$APP_HOST {
	request_body {
		max_size ${MAX_GB}GB
	}
	reverse_proxy 127.0.0.1:$PORT
}
$END"
if command -v caddy >/dev/null && systemctl is-active --quiet caddy && [ -f "$CADDYFILE" ]; then
  if grep -qF "$APP_HOST {" "$CADDYFILE"; then
    echo "  a block for $APP_HOST already exists in $CADDYFILE — leaving it untouched."
  else
    BK="$CADDYFILE.podcut.bak-$(date +%Y%m%d%H%M%S)"; cp -a "$CADDYFILE" "$BK"; echo "  backed up Caddyfile -> $BK"
    printf '\n%s\n' "$BLOCK" >> "$CADDYFILE"
    if caddy validate --adapter caddyfile --config "$CADDYFILE" >/tmp/podcut-caddy-validate 2>&1; then
      systemctl reload caddy
      systemctl is-active --quiet caddy && echo "  Caddy reloaded; $APP_HOST is now served (HTTPS issues automatically once DNS points here)." \
        || { cp -a "$BK" "$CADDYFILE"; systemctl reload caddy || true; die "Caddy became inactive after reload; restored backup."; }
    else
      cp -a "$BK" "$CADDYFILE"
      echo "  Caddy validation FAILED; restored your original Caddyfile (nothing changed). Details:"; sed 's/^/    /' /tmp/podcut-caddy-validate
      echo "  Add this block manually to your Caddy config and reload:"; printf '%s\n' "$BLOCK" | sed 's/^/    /'
    fi
  fi
else
  echo "  Caddy not detected in the standard place (systemd caddy + $CADDYFILE)."
  echo "  Your setup may run Caddy differently; nothing was changed. Add this to your Caddy config and reload it:"
  printf '%s\n' "$BLOCK" | sed 's/^/    /'
fi

IP=$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
cat <<EOF

== DONE.
PodCut Studio runs as the isolated user '$SVC_USER' on 127.0.0.1:$PORT, capped so it can't
starve your other services. Your edited files auto-delete after 12 hours.

Last step — point the subdomain at this server (if you haven't):
  In Hostinger DNS for your domain, add an A record:
    Type: A   Name: ${APP_HOST%%.*}   Value: ${IP:-<this server public IP>}
  Caddy then issues HTTPS automatically within a minute or two.

Open:   https://$APP_HOST
Log in with the password you set, upload an episode, download the edit.

Manage:  systemctl status podcut-studio   |   journalctl -u podcut-studio -f
Undo:    sudo bash uninstall.sh
EOF
