#!/usr/bin/env bash
# Interrupted installs and partial failures, in an isolated temp tree. Nothing outside mktemp is touched.
#   Part 1  backups              (any user)   truncated / failed / killed backups must never be reported or chosen as "latest"
#   Part 4  FreeLLMAPI install   (any user)   killed clone, failing clone, failing build: recover or stay in a safe, re-runnable state (offline: tiny local git repo)
#   Part 2  Node runtime         (root only)  truncated / corrupt / stalled / SIGKILLed downloads, killed-before-chmod, stale temp dirs
#   Part 3  toolkit swap         (root only)  crash between the two renames
# Parts 2-3 use chown, so they need root + LLM_TEST_ALLOW_SYSTEM_CHANGES=1 (they still only write under mktemp); otherwise they are reported as SKIP.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; PIDS=(); trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0; SKIPPED=0
t() { local n="$1"; shift; if "$@" >"$T/last.out" 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; tail -n 4 "$T/last.out" | sed 's/^/       /'; fi; }
skip() { SKIPPED=$((SKIPPED+1)); echo "SKIP $*"; }
export T ROOT

########################################################################################################################
echo "# Part 1: backups"
mkdir -p "$T/fl/config" "$T/fl/freellmapi-data" "$T/shim"
printf 'ENCRYPTION_KEY=zz\n' > "$T/fl/config/freellmapi.env"; chmod 600 "$T/fl/config/freellmapi.env"; head -c 20000 /dev/urandom > "$T/fl/freellmapi-data/freeapi.db"
FL() { env GW_HOME="$T/fl" bash "$ROOT/termux/freellmapi.sh" "$@"; }
BK="$T/fl/backups/freellmapi"
GOOD="$(FL backup 2>&1 | grep -o "$BK/[^ ]*\.tar\.gz" | head -n1)"
t "baseline backup is created and verifies"      bash -c 'test -f "'"$GOOD"'" && gzip -t "'"$GOOD"'" && tar -tzf "'"$GOOD"'" >/dev/null'
sleep 1

# B1: tar writes part of the archive and exits non-zero (disk full, killed by OOM, ...)
cat > "$T/shim/tar" <<'SH'
#!/bin/sh
# shim: behave like tar except when TAR_MODE is set
real=/usr/bin/tar; [ -x "$real" ] || real=/bin/tar
case "${TAR_MODE:-}" in
  fail)     for a in "$@"; do case "$a" in *.partial|*.tar.gz) head -c 1500 /dev/urandom > "$a";; esac; done; exit 1 ;;
  truncate) "$real" "$@"; rc=$?; for a in "$@"; do case "$a" in *.partial|*.tar.gz) [ -f "$a" ] && head -c 100 "$a" > "$a.t" && mv "$a.t" "$a";; esac; done; exit $rc ;;
  hang)     for a in "$@"; do case "$a" in *.partial|*.tar.gz) head -c 1500 /dev/urandom > "$a";; esac; done; sleep 300 ;;
  *)        exec "$real" "$@" ;;
esac
SH
chmod +x "$T/shim/tar"
before="$(ls "$BK" | sort | md5sum)"
t "B1 tar fails mid-write => the command FAILS (exit status is no longer ignored)" bash -c '! env PATH="$T/shim:$PATH" TAR_MODE=fail GW_HOME="$T/fl" bash "$ROOT/termux/freellmapi.sh" backup'
t "B1 ...and leaves neither a .tar.gz nor a .partial behind" bash -c '[ "$(ls "'"$BK"'" | sort | md5sum)" = "'"$before"'" ]'
t "B1 ...so the previous good backup is still the latest" bash -c 'env GW_HOME="$T/fl" bash -c ". \"$ROOT/termux/lib/common.sh\"; GW_BACKUP_DIR=\"$T/fl/backups\"; [ \"\$(latest_backup freellmapi)\" = \"'"$GOOD"'\" ]"'
t "B2 tar \"succeeds\" but the archive is truncated => detected and deleted, command fails" bash -c '! env PATH="$T/shim:$PATH" TAR_MODE=truncate GW_HOME="$T/fl" bash "$ROOT/termux/freellmapi.sh" backup && [ "$(ls "'"$BK"'" | sort | md5sum)" = "'"$before"'" ]'

# B3: the whole backup is SIGKILLed while tar is still writing
env PATH="$T/shim:$PATH" TAR_MODE=hang GW_HOME="$T/fl" bash "$ROOT/termux/freellmapi.sh" backup >/dev/null 2>&1 & BPID=$!
for _ in $(seq 1 40); do ls "$BK"/*.partial >/dev/null 2>&1 && break; sleep 0.25; done
# A real crash takes the whole process tree at once. The backup runs tar inside a command substitution (a subshell chain), so kill every
# process of the script by its command line FIRST (so nothing can clean up after itself), then the orphaned tar.
pkill -9 -f "$ROOT/termux/freellmapi.sh backup" 2>/dev/null; wait "$BPID" 2>/dev/null; pkill -9 -f "$T/shim/tar" 2>/dev/null; sleep 0.3
t "B3 a SIGKILLed backup leaves only a .partial file"   bash -c 'ls "'"$BK"'"/*.partial >/dev/null 2>&1 && [ "$(ls "'"$BK"'"/*.tar.gz | wc -l)" = 1 ]'
t "B3 ...which is invisible to list-backups"            bash -c 'o=$(env GW_HOME="$T/fl" bash "$ROOT/termux/freellmapi.sh" list-backups 2>&1); ! echo "$o" | grep -q partial'
t "B3 ...and is not chosen as latest"                   bash -c 'env GW_HOME="$T/fl" bash -c ". \"$ROOT/termux/lib/common.sh\"; GW_BACKUP_DIR=\"$T/fl/backups\"; [ \"\$(latest_backup freellmapi)\" = \"'"$GOOD"'\" ]"'
touch -d '20 minutes ago' "$BK"/*.partial
FL backup >/dev/null 2>&1
t "B3 the next backup removes the stale .partial"       bash -c '! ls "'"$BK"'"/*.partial >/dev/null 2>&1 && [ "$(ls "'"$BK"'"/*.tar.gz | wc -l)" = 2 ]'

# B4: a corrupt archive with a NEWER mtime must not shadow the last good one
sleep 1; printf 'this is not a gzip archive' > "$BK/9999-corrupt.tar.gz"; chmod 600 "$BK/9999-corrupt.tar.gz"
NEWEST_GOOD=""; while IFS= read -r f; do case "$f" in *corrupt*) ;; *) NEWEST_GOOD="$f"; break;; esac; done < <(ls -1t "$BK"/*.tar.gz)
t "B4 latest_backup skips a newer corrupt archive"      bash -c 'env GW_HOME="$T/fl" bash -c ". \"$ROOT/termux/lib/common.sh\"; GW_BACKUP_DIR=\"$T/fl/backups\"; [ \"\$(latest_backup freellmapi)\" = \"'"$NEWEST_GOOD"'\" ]"'
t "B4 restoring the corrupt archive explicitly is refused" bash -c '! env GW_HOME="$T/fl" ASSUME_YES=1 bash "$ROOT/termux/freellmapi.sh" restore "'"$BK"'/9999-corrupt.tar.gz"'
rm -f "$BK/9999-corrupt.tar.gz"
rm -f "$T/fl/config/freellmapi.env"
t "B5 restore with no argument picks the newest VALID archive and brings the env file back" bash -c 'printf "x" > "'"$BK"'/9998-corrupt.tar.gz"; env GW_HOME="$T/fl" ASSUME_YES=1 bash "$ROOT/termux/freellmapi.sh" restore --yes >/dev/null 2>&1; grep -q ENCRYPTION_KEY "$T/fl/config/freellmapi.env"'
rm -f "$BK/9998-corrupt.tar.gz"

########################################################################################################################
echo "# Part 4: FreeLLMAPI install from a local (offline) git repo"
mkdir -p "$T/src" && ( cd "$T/src" && git init -q -b main . && git config user.email t@example.invalid && git config user.name t \
  && printf '{"name":"fake-freellmapi","version":"0.0.0","scripts":{"build":"mkdir -p server/dist && echo ok > server/dist/index.js"}}\n' > package.json \
  && git add -A && git commit -q -m init )
mkdir -p "$T/gw1"
INST() { env GW_HOME="$T/gw1" FREELLMAPI_REPO_URL="${REPO:-$T/src}" FREELLMAPI_REF=main FREELLMAPI_PORT=18999 OMNIROUTE_PORT=18998 bash "$ROOT/termux/freellmapi.sh" install --yes 2>&1; }
export -f INST
# a clone killed half-way: a .git directory with no commits and no working tree
mkdir -p "$T/gw1/freellmapi" && git -C "$T/gw1/freellmapi" init -q
t "P1 partial checkout (killed clone) is detected, replaced and the install COMPLETES" bash -c 'o=$(INST); echo "$o" | grep -q "incomplete checkout from an interrupted install" && git -C "$T/gw1/freellmapi" rev-parse --verify -q "HEAD^{commit}" && test -f "$T/gw1/freellmapi/server/dist/index.js" && test -s "$T/gw1/state/freellmapi.installed_commit"'
echo "keep-me" > "$T/gw1/freellmapi/marker.txt"
t "P2 negative control: a COMPLETE checkout is left alone on re-run" bash -c 'o=$(INST); echo "$o" | grep -q "source already at" && test -f "$T/gw1/freellmapi/marker.txt"'
# a checkout that has a HEAD but no working tree (killed after .git, before checkout)
rm -rf "$T/gw1" && mkdir -p "$T/gw1/freellmapi" && ( cd "$T/gw1/freellmapi" && git init -q && git fetch -q "$T/src" main && git update-ref refs/heads/main FETCH_HEAD && git symbolic-ref HEAD refs/heads/main )
t "P3 .git with a HEAD but no working tree (package.json missing) is also repaired" bash -c 'o=$(INST); echo "$o" | grep -q "incomplete checkout" && test -f "$T/gw1/freellmapi/package.json" && test -s "$T/gw1/state/freellmapi.installed_commit"'
rm -rf "$T/gw1"
t "P4 an unreachable repo fails cleanly: non-zero, no completion marker, nothing half-built" bash -c '! REPO="$T/does-not-exist" INST >/dev/null && ! test -e "$T/gw1/state/freellmapi.installed_commit"'
t "P5 ...and the same command succeeds once the repo is reachable (re-run recovers)" bash -c 'o=$(INST); echo "$o" | grep -q "installed at" && test -s "$T/gw1/state/freellmapi.installed_commit"'
( cd "$T/src" && git checkout -q -b broken && printf '{"name":"fake","version":"0.0.0","scripts":{"build":"exit 1"}}\n' > package.json && git commit -q -am broken )
rm -rf "$T/gw1"
t "P6 a failing build leaves NO completion marker and the service refuses to start (safe state)" bash -c '! env GW_HOME="$T/gw1" FREELLMAPI_REPO_URL="$T/src" FREELLMAPI_REF=broken FREELLMAPI_PORT=18999 OMNIROUTE_PORT=18998 bash "$ROOT/termux/freellmapi.sh" install --yes >/dev/null 2>&1 && ! test -e "$T/gw1/state/freellmapi.installed_commit" && ! env GW_HOME="$T/gw1" FREELLMAPI_PORT=18999 OMNIROUTE_PORT=18998 bash "$ROOT/termux/freellmapi.sh" start >/dev/null 2>&1'

########################################################################################################################
if [ "$(id -u)" = 0 ] && [ "${LLM_TEST_ALLOW_SYSTEM_CHANGES:-}" = 1 ]; then
echo "# Part 2: Node runtime download (deploy.sh --apply runtime) against a local server"
LR="$T/llm"; mkdir -p "$LR/runtime"
ARCH="$(bash -c ". '$ROOT/vps/lib/vps-common.sh'; node_arch")"; NV="$(bash -c ". '$ROOT/vps/lib/vps-common.sh'; echo \$NODE_VERSION")"
FAKE="$T/fakenode/node-v$NV-linux-$ARCH"; mkdir -p "$FAKE/bin"; printf '#!/bin/sh\necho v%s\n' "$NV" > "$FAKE/bin/node"; chmod 755 "$FAKE/bin/node"
# padding: the tarball must be much larger than the 1000 bytes the "stall" server sends, or the stall would be a complete download
mkdir -p "$FAKE/share"; head -c 300000 /dev/urandom > "$FAKE/share/blob"
( cd "$T/fakenode" && tar -czf "$T/node.tgz" "node-v$NV-linux-$ARCH" ); SHA="$(sha256sum "$T/node.tgz" | cut -d' ' -f1)"
echo good > "$T/mode"
cat > "$T/srv.js" <<'JS'
const http = require('http'), fs = require('fs'); const [port, modeFile, file] = process.argv.slice(2);
http.createServer((q, s) => { const m = fs.readFileSync(modeFile, 'utf8').trim(); const b = fs.readFileSync(file);
  if (m === 'good') { s.writeHead(200, { 'content-length': b.length }); s.end(b); }
  else if (m === 'truncated') { s.writeHead(200, { 'content-length': b.length }); s.write(b.subarray(0, Math.floor(b.length / 2))); setTimeout(() => s.destroy(), 50); }
  else if (m === 'corrupt') { const c = Buffer.from('this is definitely not the node tarball'); s.writeHead(200, { 'content-length': c.length }); s.end(c); }
  else if (m === 'stall') { s.writeHead(200, { 'content-length': b.length }); s.write(b.subarray(0, 1000)); }
}).listen(+port, '127.0.0.1');
JS
SP=$((40000 + $$ % 5000)); node "$T/srv.js" "$SP" "$T/mode" "$T/node.tgz" & PIDS+=("$!"); sleep 1
RT() { env LLM_ROOT="$LR" NODE_DIST_URL="http://127.0.0.1:$SP" NODE_SHA256_x64="$SHA" NODE_SHA256_arm64="$SHA" bash "$ROOT/vps/deploy.sh" --apply runtime; }
export -f RT; export LR SP SHA
echo truncated > "$T/mode"
t "R1 truncated download => the step fails" bash -c '! RT'
t "R1 ...nothing installed, no runtime/node link, no temp dir left (EXIT trap)" bash -c '! ls "$LR"/runtime/node-v* >/dev/null 2>&1 && ! test -e "$LR/runtime/node" && ! ls -d "$LR"/runtime/.dl.* >/dev/null 2>&1'
echo corrupt > "$T/mode"
t "R2 complete-but-wrong download => SHA-256 mismatch aborts" bash -c 'o=$(RT 2>&1); echo "$o" | grep -q "SHA-256 mismatch" && ! ls "$LR"/runtime/node-v* >/dev/null 2>&1 && ! test -e "$LR/runtime/node"'
echo good > "$T/mode"
t "R3 good download installs, links runtime/node and the binary runs" bash -c 'RT && "$LR/runtime/node/bin/node" -v | grep -q "^v"'
t "R3 ...root-owned and not group/world-writable" bash -c 'd="$LR/runtime/node-v'"$NV"'"; [ "$(stat -c %U "$d")" = root ] && [ -z "$(find "$d" -perm /022 | head -n1)" ]'
t "R4 re-running is idempotent" bash -c 'RT'
D="$LR/runtime/node-v$NV"; chmod -R go+w "$D"; chown -R nobody "$D" 2>/dev/null
t "R5 killed-before-chmod state (wrong owner, group/world-writable) is REPAIRED on re-run" bash -c 'RT && [ "$(stat -c %U "'"$D"'")" = root ] && [ -z "$(find "'"$D"'" -perm /022 | head -n1)" ]'
mkdir -p "$LR/runtime/.dl.OLDONE" "$LR/runtime/.dl.FRESH1"; echo x > "$LR/runtime/.dl.OLDONE/node.tgz"; touch -d '10 minutes ago' "$LR/runtime/.dl.OLDONE"
t "R6 a stale .dl.* dir (SIGKILLed earlier run) is removed, a fresh one (maybe a concurrent run) is kept" bash -c 'RT; ! test -e "$LR/runtime/.dl.OLDONE" && test -d "$LR/runtime/.dl.FRESH1"'
rmdir "$LR/runtime/.dl.FRESH1" 2>/dev/null; rm -rf "$LR/runtime/node-v$NV" "$LR/runtime/node"
echo stall > "$T/mode"
env LLM_ROOT="$LR" NODE_DIST_URL="http://127.0.0.1:$SP" NODE_SHA256_x64="$SHA" NODE_SHA256_arm64="$SHA" bash "$ROOT/vps/deploy.sh" --apply runtime >/dev/null 2>&1 & DPID=$!
for _ in $(seq 1 40); do ls -d "$LR"/runtime/.dl.* >/dev/null 2>&1 && [ -s "$(ls -d "$LR"/runtime/.dl.* | head -n1)/node.tgz" ] && break; sleep 0.25; done
pkill -9 -f "$ROOT/vps/deploy.sh --apply runtime" 2>/dev/null; wait "$DPID" 2>/dev/null; pkill -9 -f "127.0.0.1:$SP/" 2>/dev/null; sleep 0.3   # whole tree, script first
t "R7 SIGKILL during the download leaves only a temp dir, no half-installed runtime" bash -c 'ls -d "$LR"/runtime/.dl.* >/dev/null 2>&1 && ! ls "$LR"/runtime/node-v* >/dev/null 2>&1 && ! test -e "$LR/runtime/node"'
touch -d '10 minutes ago' "$LR"/runtime/.dl.*; echo good > "$T/mode"
t "R7 ...and the next run cleans it up and installs normally" bash -c 'RT && "$LR/runtime/node/bin/node" -v | grep -q "^v" && ! ls -d "$LR"/runtime/.dl.* >/dev/null 2>&1'
t "R8 dry-run (no --apply) changes nothing" bash -c 'rm -rf "$LR/runtime/node-v'"$NV"'" "$LR/runtime/node"; env LLM_ROOT="$LR" NODE_DIST_URL="http://127.0.0.1:$SP" bash "$ROOT/vps/deploy.sh" runtime >/dev/null 2>&1; ! ls "$LR"/runtime/node-v* >/dev/null 2>&1 && ! ls -d "$LR"/runtime/.dl.* >/dev/null 2>&1'

echo "# Part 3: toolkit swap"
TK() { env LLM_ROOT="$LR" bash "$ROOT/vps/deploy.sh" --apply toolkit; }
export -f TK
t "T1 first install creates toolkit/ with VERSION and the scripts" bash -c 'TK && test -s "$LR/toolkit/VERSION" && test -x "$LR/toolkit/termux/freellmapi.sh"'
t "T2 a second run keeps the previous copy as toolkit.prev" bash -c 'TK && test -d "$LR/toolkit.prev" && test -x "$LR/toolkit/termux/freellmapi.sh"'
# crash between the two renames: toolkit is gone, toolkit.prev and a half-copied toolkit.new remain
rm -rf "$LR/toolkit" "$LR/toolkit.new"; mkdir -p "$LR/toolkit.new/termux"; echo half > "$LR/toolkit.new/termux/partial-file"
t "T3 crash state (no toolkit/, half-copied toolkit.new) is recovered by simply re-running" bash -c 'TK && test -x "$LR/toolkit/termux/freellmapi.sh" && test -s "$LR/toolkit/VERSION" && ! test -e "$LR/toolkit.new" && ! test -e "$LR/toolkit/termux/partial-file"'
t "T3 ...the recovered toolkit is root-owned and not group/world-writable" bash -c '[ "$(stat -c %U "$LR/toolkit")" = root ] && [ -z "$(find "$LR/toolkit" -perm /022 | head -n1)" ]'
else
  skip "Part 2 (Node runtime) and Part 3 (toolkit swap) need root + LLM_TEST_ALLOW_SYSTEM_CHANGES=1 (they chown inside a temp tree)"
fi

echo "partial-failure: $PASS passed, $FAIL failed, $SKIPPED skipped"; [ "$FAIL" = 0 ]
