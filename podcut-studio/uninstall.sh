#!/usr/bin/env bash
# Removes everything deploy.sh added, and nothing else.
set -uo pipefail
say() { printf '\n== %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo bash uninstall.sh"; exit 1; }
CADDYFILE=/etc/caddy/Caddyfile

say "stopping and removing the service"
systemctl disable --now podcut-studio 2>/dev/null || true
rm -f /etc/systemd/system/podcut-studio.service
systemctl daemon-reload 2>/dev/null || true

say "removing the Caddy block (your other sites are untouched)"
if [ -f "$CADDYFILE" ] && grep -qF ">>> podcut-studio" "$CADDYFILE"; then
  BK="$CADDYFILE.podcut.bak-$(date +%Y%m%d%H%M%S)"; cp -a "$CADDYFILE" "$BK"; echo "  backup -> $BK"
  sed -i '/# >>> podcut-studio/,/# <<< podcut-studio/d' "$CADDYFILE"
  if command -v caddy >/dev/null && caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    systemctl reload caddy 2>/dev/null || true; echo "  Caddy reloaded"
  else
    echo "  NOTE: Caddy validation failed after removal; your backup is $BK"
  fi
fi

say "removing files and the service user"
rm -rf /opt/podcut-studio
if id podcutsvc >/dev/null 2>&1; then userdel podcutsvc 2>/dev/null || true; groupdel podcutsvc 2>/dev/null || true; fi

say "DONE. PodCut Studio is fully removed. (ffmpeg / python were left in place.)"
