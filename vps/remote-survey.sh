#!/usr/bin/env bash
# Run FROM your phone/computer. One read-only look at the VPS over your own SSH login: nothing is installed, no service is touched.
#   bash vps/remote-survey.sh user@host [--port N] [--key FILE] [--out FILE] [--freellmapi-port N] [--omniroute-port N] [--inspect-container NAME] [--forensic] [--only omniroute|freellmapi] [--earnix]
# What happens on the VPS: a private temp dir is created under /tmp, this repo's vps/ folder is unpacked there, the read-only
# preflight + inventory + a short system summary run, and the temp dir is deleted again. Only your normal SSH login log entry remains.
# Credentials stay with ssh (key file or your password prompt): this script never sees or stores them.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"; [ -n "$TARGET" ] || { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }; shift
SSHARGS=(); FORENSIC=0; EARNIX=0; ONLY=""; FLP=3001; OMP=20128; CN=""; OUT="$HOME/vps-survey-$(date -u +%Y%m%dT%H%M%SZ).txt"
while [ $# -gt 0 ]; do case "$1" in --port) SSHARGS+=(-p "$2"); shift;; --key) SSHARGS+=(-i "$2"); shift;; --out) OUT="$2"; shift;; --freellmapi-port) FLP="$2"; shift;; --omniroute-port) OMP="$2"; shift;; --inspect-container) CN="$2"; shift;; --forensic) FORENSIC=1;; --earnix) EARNIX=1;; --only) ONLY="$2"; shift;; *) echo "unknown option $1" >&2; exit 2;; esac; shift; done
SSH="${SSH_BIN:-ssh}"
command -v "$SSH" >/dev/null || { echo "ssh not found (Termux: pkg install openssh)" >&2; exit 1; }
case "$ONLY" in ""|omniroute|freellmapi) ;; *) echo "--only takes omniroute or freellmapi" >&2; exit 2;; esac
case "$CN" in *[!A-Za-z0-9_.-]*) echo "bad container name" >&2; exit 2;; esac
case "$FLP$OMP" in *[!0-9]*|"") echo "ports must be numbers" >&2; exit 2;; esac
case "$CN" in *[!A-Za-z0-9_.-]*) echo "bad container name" >&2; exit 2;; esac
case "$FLP$OMP" in *[!0-9]*|"") echo "ports must be numbers" >&2; exit 2;; esac
[ "$FORENSIC" = 1 ] && [ -z "$CN" ] && CN=suppar-freellmapi
TS="$(date -u +%Y%m%dT%H%M%SZ)"
SAVE=""; [ "$FORENSIC" = 1 ] && SAVE="/root/llm-deploy/vps-forensic-$TS.txt"; [ "$EARNIX" = 1 ] && SAVE="/root/llm-deploy/earnix-discovery-$TS.txt"
IFS= read -r -d '' REMOTE <<'R' || true
set -e; D=$(mktemp -d /tmp/llm-survey.XXXXXX); chmod 700 "$D"; trap 'rm -rf "$D"' EXIT; tar -xz -C "$D"
SAVE='@SAVE@'
if [ -n "$SAVE" ]; then
  # Normally /root/llm-deploy (root login). A non-root login falls back to its own $HOME/llm-deploy; if neither is writable, no copy is kept (the survey still runs).
  sd=$(dirname "$SAVE"); ( umask 077; mkdir -p "$sd" ) 2>/dev/null || { sd="$HOME/llm-deploy"; SAVE="$sd/$(basename "$SAVE")"; ( umask 077; mkdir -p "$sd" ) 2>/dev/null; }
  if [ -d "$sd" ] && [ -w "$sd" ]; then chmod 700 "$sd" 2>/dev/null; ( umask 077; set -o pipefail; @RUN@ 2>&1 | tee "$SAVE" ); echo "report also saved on the VPS: $SAVE"
  else echo "note: no writable llm-deploy directory; this report is NOT saved on the VPS"; @RUN@; fi
else @RUN@; fi
R
if [ "$EARNIX" = 1 ]; then RUN='bash "$D/vps/earnix-discover.sh"'; else RUN='bash "$D/vps/survey-remote.sh" "$D" @ARGS@'; fi
REMOTE="${REMOTE//@RUN@/$RUN}"; REMOTE="${REMOTE//@SAVE@/$SAVE}"; REMOTE="${REMOTE//@ARGS@/$FLP $OMP ${CN:-none} ${ONLY:-both}}"
echo "connecting to $TARGET (read-only survey; report goes to $OUT)" >&2
tar -C "$HERE" -cz vps config termux/lib 2>/dev/null | "$SSH" -o BatchMode=no -o ConnectTimeout=20 -o StrictHostKeyChecking=ask "${SSHARGS[@]}" "$TARGET" "$REMOTE" 2>&1 | tee "$OUT"
rc=${PIPESTATUS[1]}; chmod 600 "$OUT" 2>/dev/null
echo; echo "ssh exit status: $rc   (report: $OUT)" >&2; exit "$rc"
