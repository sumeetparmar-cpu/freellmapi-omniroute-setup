#!/usr/bin/env bash
# Tests scripts/check-secrets.sh in a throwaway git repo using obviously fake, runtime-assembled values.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" && git init -q . && git config user.email t@example.test && git config user.name t
mkdir scripts && cp "$ROOT/scripts/check-secrets.sh" scripts/
PASS=0; FAIL=0
expect() { # expect "name" want_exit
  scripts/check-secrets.sh >"$TMP/out" 2>&1; local got=$?
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); echo "ok   - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1 (exit $got, wanted $2)"; cat "$TMP/out"; fi
}
HEX="$(printf 'a1b2c3d4%.0s' 1 2 3 4 5 6 7 8)"          # 64 hex chars, assembled at runtime
echo "# clean" > README.md; echo 'ENCRYPTION_KEY=<generated locally>' > ok.env.example
expect "clean repo passes" 0
echo "ENCRYPTION_KEY=$HEX" > cfg.txt;           expect "64-hex ENCRYPTION_KEY flagged" 1;   rm cfg.txt
echo "k = sk-$(printf 'Ab9%.0s' 1 2 3 4 5 6)" > a.md; expect "sk- style key flagged" 1;     rm a.md
echo "k = freellmapi-$(printf 'f0e1%.0s' 1 2 3 4 5)" > a.md; expect "freellmapi key flagged" 1; rm a.md
echo "k = AIza$(printf 'Zz1_%.0s' 1 2 3 4 5 6 7 8 9)" > a.md; expect "Google key flagged" 1;     rm a.md
touch .env;                                    expect ".env file flagged" 1;                rm .env
touch backup.tar.gz;                           expect "backup archive flagged" 1;           rm backup.tar.gz
echo "Authorization: Bearer <your key here>" > a.md;  expect "placeholder Bearer allowed" 0; rm a.md
echo 'export OMNIROUTE_KEY=$MY_KEY' > a.sh;    expect "variable reference allowed" 0;       rm a.sh
echo "-----BEGIN PRIVATE KEY-----" > a.md;     expect "private key block flagged" 1;        rm a.md
echo "ENCRYPTION_KEY=$HEX" > staged.txt; git add staged.txt
scripts/check-secrets.sh --staged >/dev/null 2>&1; [ $? = 1 ] && { PASS=$((PASS+1)); echo "ok   - --staged flags staged secret"; } || { FAIL=$((FAIL+1)); echo "FAIL - --staged"; }
echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
