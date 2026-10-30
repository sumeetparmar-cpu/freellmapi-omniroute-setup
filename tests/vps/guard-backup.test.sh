#!/usr/bin/env bash
# Backups must carry the free-guard client-key hashes (so a restore cannot lock clients out) and must NOT carry the upstream key / audit credentials.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; fi; }
for gw in freellmapi omniroute; do
  H="$T/$gw"; mkdir -p "$H/config" "$H/${gw}-data"
  export GW_HOME="$H"
  printf 'ENCRYPTION_KEY=zz\n' > "$H/config/$gw.env"; chmod 600 "$H/config/$gw.env"
  printf 'db' > "$H/${gw}-data/x.db"
  printf '%064d client-a 2026-01-01\n' 1 > "$H/config/free-guard.clients"
  printf 'upstream-secret-value\n' > "$H/config/free-guard.upstream.key"
  printf 'OMNIROUTE_MGMT_TOKEN=audit-secret-value\n' > "$H/config/free-audit.env"
  ARC="$(bash "$ROOT/termux/$gw.sh" backup 2>&1 | grep -o "$H/backups/[^ ]*\.tar\.gz" | head -n1)"
  t "$gw: backup archive created"                          test -f "$ARC"
  t "$gw: backup contains the client-key hashes"           bash -c "tar -tzf '$ARC' | grep -q 'config/free-guard.clients'"
  t "$gw: backup does NOT contain the upstream key"        bash -c "! tar -tzf '$ARC' | grep -q 'upstream.key'"
  t "$gw: backup does NOT contain audit credentials"       bash -c "! tar -tzf '$ARC' | grep -q 'free-audit.env'"
  t "$gw: archive text has no upstream/audit secrets"      bash -c "! tar -xzOf '$ARC' | grep -aq -e upstream-secret-value -e audit-secret-value"
  rm -f "$H/config/free-guard.clients"
  t "$gw: restore brings the client-key hashes back"       bash -c "ASSUME_YES=1 bash '$ROOT/termux/$gw.sh' restore '$ARC' --yes >/dev/null 2>&1; [ -f '$H/config/free-guard.clients' ] && grep -q client-a '$H/config/free-guard.clients'"
  t "$gw: restore left the upstream key untouched"         bash -c "grep -q upstream-secret-value '$H/config/free-guard.upstream.key'"
  # an older archive (no guard file) must still restore
  OLD="$H/old.tar.gz"; ( cd / && tar -czf "$OLD" "${H#/}/config/$gw.env" "${H#/}/${gw}-data" )
  t "$gw: archives from before this feature still restore" bash -c "ASSUME_YES=1 bash '$ROOT/termux/$gw.sh' restore '$OLD' --yes >/dev/null 2>&1"
done
echo "guard-backup: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
