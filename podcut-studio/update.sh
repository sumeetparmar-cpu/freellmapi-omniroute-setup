#!/usr/bin/env bash
# Updates an already-installed PodCut Studio to the latest app.py/podcut.py in this
# folder, then restarts the service. Keeps your config, password and subdomain.
# Run after pulling the repo:  sudo bash podcut-studio/update.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root:  sudo bash podcut-studio/update.sh"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR=/opt/podcut-studio
[ -d "$APP_DIR" ] || { echo "PodCut Studio is not installed yet. Run:  sudo bash podcut-studio/deploy.sh"; exit 1; }
[ -f "$HERE/app.py" ] && [ -f "$HERE/podcut.py" ] || { echo "app.py and podcut.py must sit next to this script."; exit 1; }

install -m 644 "$HERE/app.py" "$HERE/podcut.py" "$APP_DIR/"
systemctl restart podcut-studio
sleep 2
if systemctl is-active --quiet podcut-studio; then
  echo "Updated and restarted. PodCut Studio is running the new version."
else
  echo "Service did not come back up; recent log:"; journalctl -u podcut-studio -n 20 --no-pager
  exit 1
fi
