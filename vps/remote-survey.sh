#!/usr/bin/env bash
# Run FROM your phone/computer. One read-only look at the VPS over your own SSH login: nothing is installed, no service is touched.
#   bash vps/remote-survey.sh user@host [--port N] [--key FILE] [--out FILE] [--freellmapi-port N] [--omniroute-port N]
# What happens on the VPS: a private temp dir is created under /tmp, this repo's vps/ folder is unpacked there, the read-only
# preflight + inventory + a short system summary run, and the temp dir is deleted again. Only your normal SSH login log entry remains.
# Credentials stay with ssh (key file or your password prompt): this script never sees or stores them.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"; [ -n "$TARGET" ] || { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }; shift
SSHARGS=(); FLP=3001; OMP=20128; OUT="$HOME/vps-survey-$(date -u +%Y%m%dT%H%M%SZ).txt"
while [ $# -gt 0 ]; do case "$1" in --port) SSHARGS+=(-p "$2"); shift;; --key) SSHARGS+=(-i "$2"); shift;; --out) OUT="$2"; shift;; --freellmapi-port) FLP="$2"; shift;; --omniroute-port) OMP="$2"; shift;; *) echo "unknown option $1" >&2; exit 2;; esac; shift; done
SSH="${SSH_BIN:-ssh}"
command -v "$SSH" >/dev/null || { echo "ssh not found (Termux: pkg install openssh)" >&2; exit 1; }
case "$FLP$OMP" in *[!0-9]*|"") echo "ports must be numbers" >&2; exit 2;; esac
case "$FLP$OMP" in *[!0-9]*|"") echo "ports must be numbers" >&2; exit 2;; esac
REMOTE='set -e; D=$(mktemp -d /tmp/llm-survey.XXXXXX); chmod 700 "$D"; trap "rm -rf \"$D\"" EXIT; tar -xz -C "$D"; bash "$D/vps/survey-remote.sh" "$D" '"$FLP $OMP"''
echo "connecting to $TARGET (read-only survey; report goes to $OUT)" >&2
tar -C "$HERE" -cz vps config termux/lib 2>/dev/null | "$SSH" -o BatchMode=no -o ConnectTimeout=20 -o StrictHostKeyChecking=ask "${SSHARGS[@]}" "$TARGET" "$REMOTE" 2>&1 | tee "$OUT"
rc=${PIPESTATUS[1]}; chmod 600 "$OUT" 2>/dev/null
echo; echo "ssh exit status: $rc   (report: $OUT)" >&2; exit "$rc"
