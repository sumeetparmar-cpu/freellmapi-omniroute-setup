#!/usr/bin/env bash
# Build a deterministic deployment archive of the toolkit from a git commit, checksum it, and (optionally) prove it works
# from a clean extraction. Reproducible: the same commit always yields the same bytes (and therefore the same SHA-256).
#
#   scripts/make-release.sh [--ref <git ref>] [--out DIR] [--verify]
#
# Writes   DIR/llm-toolkit-<short-commit>.tar.gz   and   DIR/llm-toolkit-<short-commit>.tar.gz.sha256   (sha256sum format)
# --verify: re-checks the checksum, extracts to a fresh temp dir and runs the offline test suites FROM THE EXTRACTION
#           (needs node >= 22 on PATH; uses nothing from the build tree).
set -euo pipefail
REF=HEAD; OUT=release; VERIFY=0
while [ $# -gt 0 ]; do case "$1" in --ref) REF="$2"; shift;; --out) OUT="$2"; shift;; --verify) VERIFY=1;; *) echo "unknown option $1" >&2; exit 2;; esac; shift; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
COMMIT="$(git rev-parse --verify "$REF^{commit}")"; SHORT="${COMMIT:0:12}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
ARC="$OUT/llm-toolkit-$SHORT.tar.gz"
# --prefix gives the llm-toolkit/ directory that docs/VPS-DEPLOYMENT.md Stage A/B expects; gzip -n drops the timestamp/name from the header.
git archive --format=tar --prefix=llm-toolkit/ "$COMMIT" | gzip -n -9 > "$ARC"
( cd "$OUT" && sha256sum "$(basename "$ARC")" > "$(basename "$ARC").sha256" )
echo "archive : $ARC"; echo "commit  : $COMMIT"; echo "sha256  : $(cut -d' ' -f1 "$ARC.sha256")"; echo "size    : $(du -k "$ARC" | cut -f1) KB, $(tar -tzf "$ARC" | grep -vc '/$') files"
if [ "$VERIFY" = 1 ]; then
  ( cd "$OUT" && sha256sum -c "$(basename "$ARC").sha256" )
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  tar -xzf "$ARC" -C "$T"; cd "$T/llm-toolkit"
  echo "== verifying from the extraction: $T/llm-toolkit (node $(node -v))"
  node --test tests/guard/*.test.mjs tests/quota/*.test.mjs
  bash tests/vps/free-install.test.sh
  bash tests/termux/run-tests.sh | tail -n 2
  bash tests/vps/run-tests.sh | tail -n 2
  bash scripts/check-secrets.sh
  echo "RELEASE VERIFIED: $(basename "$ARC")"
fi
