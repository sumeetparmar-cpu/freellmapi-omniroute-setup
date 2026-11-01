#!/usr/bin/env bash
# opencode-install.sh and fetch-opencode.mjs: every branch, with stand-ins for pkg / grun / proot-distro and a mock npm registry.
# This proves the LOGIC. It cannot prove that glibc-runner or proot-distro run the real binary on Android: only the phone can.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; T="$(mktemp -d)"; PASS=0; FAIL=0; PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; echo "opencode-install: passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1; }; trap cleanup EXIT
ck() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then PASS=$((PASS + 1)); echo "ok   - $n"; else FAIL=$((FAIL + 1)); echo "FAIL - $n"; sed 's/^/       /' "$T/out" | tail -8; fi; }
free_port() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }

# ---------- part 1: the downloader against a mock registry ----------
mkdir -p "$T/reg/pkgdir/package/bin"
node -e 'const b=Buffer.alloc(4096);b.set([0x7f,0x45,0x4c,0x46],0);b.writeUInt16LE(0xb7,18);require("fs").writeFileSync(process.argv[1],b)' "$T/reg/pkgdir/package/bin/opencode"
node -e 'const b=Buffer.alloc(4096);b.set([0x7f,0x45,0x4c,0x46],0);b.writeUInt16LE(0x3e,18);require("fs").writeFileSync(process.argv[1],b)' "$T/reg/x86bin"   # x86-64 machine id
(cd "$T/reg/pkgdir" && tar czf ../good.tgz package)
mkdir -p "$T/reg/p2/package/bin"; cp "$T/reg/x86bin" "$T/reg/p2/package/bin/opencode"; (cd "$T/reg/p2" && tar czf ../x86.tgz package)
RP=$(free_port)
cat > "$T/reg/server.mjs" <<'JS'
import http from 'node:http'; import { readFileSync } from 'node:fs'; import { createHash } from 'node:crypto';
const [dir, port] = process.argv.slice(2); const sri = (f) => 'sha512-' + createHash('sha512').update(readFileSync(`${dir}/${f}`)).digest('base64');
const base = `http://127.0.0.1:${port}`;
const metas = {
  '/opencode-linux-arm64/1.0.0': { os: ['linux'], cpu: ['arm64'], dist: { tarball: `${base}/good.tgz`, integrity: sri('good.tgz'), unpackedSize: 4096 } },
  '/opencode-linux-arm64/2.0.0': { os: ['linux'], cpu: ['arm64'], dist: { tarball: `${base}/good.tgz`, integrity: 'sha512-' + Buffer.alloc(64, 1).toString('base64'), unpackedSize: 4096 } },   // WRONG integrity
  '/opencode-linux-arm64/3.0.0': { os: ['linux'], cpu: ['arm64'], dist: { tarball: `${base}/x86.tgz`, integrity: sri('x86.tgz'), unpackedSize: 4096 } },                                   // x86 ELF
  '/opencode-linux-arm64/4.0.0': { os: ['darwin'], cpu: ['arm64'], dist: { tarball: `${base}/good.tgz`, integrity: sri('good.tgz') } },                                                    // wrong os
  '/opencode-linux-arm64/5.0.0': { os: ['linux'], cpu: ['arm64'], dist: { tarball: `${base}/good.tgz` } },                                                                                 // no integrity
  '/opencode-linux-arm64/6.0.0': { os: ['linux'], cpu: ['arm64'], dist: { tarball: 'http://example.com/evil.tgz', integrity: sri('good.tgz') } },                                          // non-https remote tarball
};
http.createServer((q, s) => { if (metas[q.url]) { s.writeHead(200, { 'content-type': 'application/json' }); return s.end(JSON.stringify(metas[q.url])); }
  if (q.url === '/good.tgz' || q.url === '/x86.tgz') { s.writeHead(200); return s.end(readFileSync(`${dir}${q.url}`)); } s.writeHead(404); s.end('{}'); }).listen(+port, '127.0.0.1');
JS
node "$T/reg/server.mjs" "$T/reg" "$RP" & PIDS+=($!); sleep 1
F() { node "$ROOT/termux/lib/fetch-opencode.mjs" --registry "http://127.0.0.1:$RP" --out "$T/o$1" --version "$1" 2>&1; }
ck "fetch: good package is installed (integrity verified, aarch64 ELF)" bash -c "node '$ROOT/termux/lib/fetch-opencode.mjs' --registry http://127.0.0.1:$RP --out '$T/o1' --version 1.0.0 | grep -q 'integrity verified' && [ -x '$T/o1/bin/opencode' ] && [ \"\$(cat '$T/o1/VERSION')\" = 1.0.0 ]"
ck "fetch: second run downloads nothing"                  bash -c "node '$ROOT/termux/lib/fetch-opencode.mjs' --registry http://127.0.0.1:$RP --out '$T/o1' --version 1.0.0 | grep -q 'already present'"
neg() { local n="$1" v="$2" pat="$3"; ck "fetch REFUSES: $n" bash -c "out=\$(node '$ROOT/termux/lib/fetch-opencode.mjs' --registry http://127.0.0.1:$RP --out '$T/o$v' --version $v 2>&1); rc=\$?; echo \"\$out\" | grep -q '$pat' && [ \$rc -ne 0 ] && [ ! -e '$T/o$v/bin/opencode' ]"; }
neg "a tampered download (integrity mismatch)"          2.0.0 'INTEGRITY MISMATCH'
neg "an x86 binary"                                     3.0.0 'not an ELF aarch64'
neg "a package for another OS"                          4.0.0 'not a linux/arm64'
neg "metadata without integrity"                        5.0.0 'no sha512 integrity'
neg "a plain-http remote tarball"                       6.0.0 'not https'
ck "fetch REFUSES a plain-http remote registry"          bash -c "! node '$ROOT/termux/lib/fetch-opencode.mjs' --registry http://example.com --out '$T/o7' --version 1.0.0"

# ---------- part 2: installer logic with stand-ins ----------
export HOME="$T/home" GW_HOME="$T/gw"; mkdir -p "$HOME" "$GW_HOME/config" "$GW_HOME/opencode/bin"
KEY1="fg_$(date +%s%N | sha256sum | cut -c1-30)"; KEY2="fg_$(date +%N | sha256sum | cut -c1-30)"
printf '%s\n' "$KEY1" > "$GW_HOME/config/guard-freellmapi.clientkey"; printf '%s\n' "$KEY2" > "$GW_HOME/config/guard-omniroute.clientkey"; chmod 600 "$GW_HOME"/config/*
cat > "$GW_HOME/opencode/bin/opencode" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "1.19.5" ;;
  --probe) shift; echo "ARGC=$#"; for a in "$@"; do echo "ARG=[$a]"; done; echo "CWD=$(pwd)"; echo "HOME=$HOME"; echo "CFG=$OPENCODE_CONFIG"; echo "UPD=$OPENCODE_DISABLE_AUTOUPDATE"
     echo "FLK=$(printf %s "$FREELLMAPI_GUARD_KEY" | sha256sum | cut -c1-16)"; echo "ORK=$(printf %s "$OMNIROUTE_GUARD_KEY" | sha256sum | cut -c1-16)" ;;
esac
SH
chmod +x "$GW_HOME/opencode/bin/opencode"; echo 1.19.5 > "$GW_HOME/opencode/VERSION"
GP1=$(free_port); GP2=$(free_port); export GUARD_PORT_FREELLMAPI=$GP1 GUARD_PORT_OMNIROUTE=$GP2
node -e 'for (const p of process.argv.slice(1)) require("net").createServer().listen(+p,"127.0.0.1")' "$GP1" "$GP2" & PIDS+=($!); sleep 1   # stand-in guards: the launcher must not try to start gateways
SH_DIR="$T/shim"; AV="$T/avail"; mkdir -p "$SH_DIR" "$AV"
cat > "$AV/grun" <<'SH'
#!/bin/sh
[ -e "$SHIM_STATE/grun_broken" ] && { echo "grun: cannot execute" >&2; exit 126; }
exec "$@"
SH
cat > "$AV/proot-distro" <<'SH'
#!/bin/sh
# stand-in: login needs the Debian rootfs; the guest gets a SANITIZED environment (like the real one) so nothing may rely on env passthrough
case "$1" in
  install) touch "$SHIM_STATE/debian"; echo "installed debian" ;;
  login) [ -e "$SHIM_STATE/debian" ] || { echo "proot-distro: debian not installed" >&2; exit 1; }
         [ -e "$SHIM_STATE/proot_broken" ] && { echo "proot: ptrace failed" >&2; exit 1; }
         shift; while [ "$1" != "--" ]; do shift; done; shift; exec env -i PATH=/usr/bin:/bin "$@" ;;
esac
SH
cat > "$SH_DIR/pkg" <<'SH'
#!/bin/sh
echo "pkg $*" >> "$SHIM_STATE/pkg.log"
[ -e "$SHIM_STATE/pkg_down" ] && exit 1
for w in "$@"; do case "$w" in
  glibc-runner) [ -e "$SHIM_STATE/no_glibc_repo" ] && exit 1; cp "$SHIM_AVAIL/grun" "$SHIM_BIN/grun"; chmod +x "$SHIM_BIN/grun" ;;
  proot-distro) cp "$SHIM_AVAIL/proot-distro" "$SHIM_BIN/proot-distro"; chmod +x "$SHIM_BIN/proot-distro" ;;
esac; done; exit 0
SH
chmod +x "$AV"/* "$SH_DIR/pkg"
export SHIM_STATE="$T/state" SHIM_AVAIL="$AV" SHIM_BIN="$SH_DIR"; mkdir -p "$SHIM_STATE"
reset() { rm -rf "${SHIM_STATE:?}" "${GW_HOME:?}/opencode/runner" "${GW_HOME:?}/bin" "${HOME:?}/.config" "$SH_DIR/grun" "$SH_DIR/proot-distro"; mkdir -p "$SHIM_STATE"; }
INST="$ROOT/termux/opencode-install.sh"; export PATH="$SH_DIR:$PATH" OC_VERIFY_TIMEOUT=20
inst() { bash "$INST" "$@"; }

reset; ck "S1 glibc-runner works: chosen without ever touching proot-distro" bash -c "bash '$INST' --method auto >'$T/s1.log' 2>&1; [ \"\$(cat '$GW_HOME/opencode/runner')\" = grun ] && ! grep -q proot-distro '$SHIM_STATE/pkg.log' && grep -q 'method: grun' '$T/s1.log'"
LF="$GW_HOME/bin/opencode-free"
ck "S1 config written and passes its own free-only check" bash -c "bash '$ROOT/termux/opencode-setup.sh' check"
ck "S1 launcher: --version reaches the binary"            bash -c "[ \"\$($LF --version | head -n1)\" = 1.19.5 ]"
cd "$T" && mkdir -p "work dir" && cd "work dir" || exit 1
probe() { "$LF" --probe "one arg" two; }
ck "S1 launcher: arguments with spaces survive, cwd and HOME are kept" bash -c "o=\$(cd '$T/work dir' && '$LF' --probe 'one arg' two); echo \"\$o\" | grep -q 'ARGC=2' && echo \"\$o\" | grep -qF 'ARG=[one arg]' && echo \"\$o\" | grep -qF 'CWD=$T/work dir' && echo \"\$o\" | grep -q 'HOME=$HOME'"
ck "S1 launcher: the guard keys arrive in the process (hash matches) and autoupdate is off" bash -c "o=\$('$LF' --probe); [ \"\$(echo \"\$o\" | sed -n 's/^FLK=//p')\" = \"\$(printf %s '$KEY1' | sha256sum | cut -c1-16)\" ] && [ \"\$(echo \"\$o\" | sed -n 's/^ORK=//p')\" = \"\$(printf %s '$KEY2' | sha256sum | cut -c1-16)\" ] && echo \"\$o\" | grep -q 'UPD=true'"
ck "S1 no key is in the launcher, the inner script, the config or the install output" bash -c "! grep -rqF -e '$KEY1' -e '$KEY2' '$GW_HOME/bin' '$GW_HOME/opencode/inner.sh' '$HOME/.config' '$T/s1.log'"

reset; touch "$SHIM_STATE/no_glibc_repo"
ck "S2 no glibc-runner: falls back to Debian under proot and runs it" bash -c "bash '$INST' >'$T/s2.log' 2>&1; [ \"\$(cat '$GW_HOME/opencode/runner')\" = proot ] && grep -q 'method: proot' '$T/s2.log' && [ -e '$SHIM_STATE/debian' ]"
ck "S2 launcher under proot (sanitized environment): --version and keys work" bash -c "[ \"\$('$LF' --version | head -n1)\" = 1.19.5 ] && o=\$('$LF' --probe) && [ \"\$(echo \"\$o\" | sed -n 's/^FLK=//p')\" = \"\$(printf %s '$KEY1' | sha256sum | cut -c1-16)\" ]"

reset; touch "$SHIM_STATE/pkg_down"
ck "S3 neither method works: exit 1, nothing marked installed, gateways untouched" bash -c "! bash '$INST' >'$T/s3.log' 2>&1; [ ! -e '$GW_HOME/opencode/runner' ] && grep -q 'Nothing is marked as installed' '$T/s3.log' && [ -s '$GW_HOME/config/guard-freellmapi.clientkey' ]"

reset; touch "$SHIM_STATE/no_glibc_repo"; touch "$SHIM_STATE/debian" "$SHIM_STATE/proot_broken"; cp "$AV/proot-distro" "$SH_DIR/proot-distro"
ck "S4 proot present but broken and no grun: fails honestly (does not pretend)" bash -c "! bash '$INST' >'$T/s4.log' 2>&1; [ ! -e '$GW_HOME/opencode/runner' ]"

reset; bash "$INST" >/dev/null 2>&1; : > "$SHIM_STATE/pkg.log"
ck "S5 re-run keeps the working method and installs nothing" bash -c "bash '$INST' >'$T/s5.log' 2>&1; grep -q 'still works (kept)' '$T/s5.log' && ! grep -q 'install' '$SHIM_STATE/pkg.log'"
ck "S6 --method proot is honoured (and refuses an unknown method)" bash -c "reset=1; bash '$INST' --method proot >'$T/s6.log' 2>&1; [ \"\$(cat '$GW_HOME/opencode/runner')\" = proot ]; ! bash '$INST' --method bogus >/dev/null 2>&1"
ck "S7 refuses to run without the gateway guard keys" bash -c "mv '$GW_HOME/config/guard-omniroute.clientkey' '$T/k.bak'; ! bash '$INST' >'$T/s7.log' 2>&1; r=\$?; mv '$T/k.bak' '$GW_HOME/config/guard-omniroute.clientkey'; grep -q 'guard keys are missing' '$T/s7.log'"
