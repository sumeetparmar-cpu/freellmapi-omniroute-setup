#!/usr/bin/env bash
# Tests for the preflight checks added for: ports (guard ports, ephemeral range), RAM (cgroup cap, overcommit, headroom), disk/mounts
# (read-only, noexec, /tmp), permissions (umask, symlinked root), conflicts (foreign llm-* units), dependencies (CA bundle, clock) and
# network diagnostics. Every check has a negative control. The preflight stays READ-ONLY: a test below proves it by diffing the tree.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; fi; }
BIN="$T/bin"; mkdir -p "$BIN" "$T/fake-sd" "$T/units"
printf 'ID=ubuntu\nVERSION_ID="26.04"\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' > "$T/os26"
printf 'MemTotal: 8388608 kB\nMemAvailable: 6291456 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$T/mem_big"
printf 'MemTotal: 8388608 kB\nMemAvailable: 1024000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$T/mem_tight"
printf '0.0.0.0\t80\tcaddy\n' > "$T/listen"
printf '/dev/vda1 / ext4 rw,relatime 0 0\n' > "$T/mounts_ok"
# a clean baseline invocation. Convention (same as run-tests.sh): VAR=value overrides go BEFORE the script path; later assignments win.
pf() { env PATH="$BIN:$PATH" OS_RELEASE="$T/os26" MEMINFO_FILE="$T/mem_big" SYSTEMD_RUN_DIR="$T/fake-sd" SYSTEMD_DIR="$T/units" LISTENERS_FILE="$T/listen" \
  MOUNTS_FILE="$T/mounts_ok" CGROUP_MEM_FILE="$T/cg_max" OVERCOMMIT_FILE="$T/oc0" PORT_RANGE_FILE="$T/range" RESERVED_PORTS_FILE="$T/resv" \
  LLM_ROOT="$T/nonexistent/llm" LLM_USER_FREELLMAPI=llmxfree LLM_USER_OMNIROUTE=llmxomni "$@"; }
printf 'max\n' > "$T/cg_max"; printf '0\n' > "$T/oc0"; printf '32768\t60999\n' > "$T/range"; printf '\n' > "$T/resv"
# shellcheck disable=SC2120  # callers pass VAR=value overrides, then extra script args after the fixed ones
run() { pf "$@" "$ROOT/vps/preflight.sh" --offline 2>&1; }
export T ROOT BIN; export -f pf run

echo "# baseline"
OUT="$(run)"
t "baseline has no BLOCK from the new checks"   bash -c '! echo "$0" | grep -E "^\[BLOCK\] (the filesystem|.*symlink|llm-)"' "$OUT"
t "baseline reports the new PASS lines"         bash -c 'echo "$0" | grep -q "filesystem holding" && echo "$0" | grep -q "would remain available" && echo "$0" | grep -q "optional freellmapi guard"' "$OUT"

echo "# RAM"
printf '536870912\n' > "$T/cg_512"; printf '2\n' > "$T/oc2"
t "cgroup memory cap below host RAM => WARN naming both numbers" bash -c 'run CGROUP_MEM_FILE="$T/cg_512" | grep -q "capped by this process.s cgroup at 512 MB (host shows 8192 MB)"'
t "negative control: cgroup 'max' => no cap warning" bash -c '! echo "$0" | grep -q "capped by"' "$OUT"
t "vm.overcommit_memory=2 => WARN"             bash -c 'run OVERCOMMIT_FILE="$T/oc2" | grep -q "overcommit_memory=2"'
t "negative control: overcommit 0 => no warning" bash -c '! echo "$0" | grep -q overcommit' "$OUT"
t "1000 MB available => only ~200 MB left for neighbours => WARN with the number" bash -c 'run MEMINFO_FILE="$T/mem_tight" | grep -q "only ~200 MB would remain"'
t "negative control: plenty available => PASS with the number" bash -c 'echo "$0" | grep -q "about 5344 MB would remain"' "$OUT"

echo "# disk / mounts (the fixture gives \$T its own rw mount so only the line under test changes)"
mk_mounts() { printf '/dev/vda1 / ext4 rw,relatime 0 0\n%s\n' "$1" > "$T/m_$2"; }
mk_mounts "tmpfs $T tmpfs rw,noexec,nosuid 0 0" noexec
mk_mounts "tmpfs $T tmpfs ro,relatime 0 0" ro
mk_mounts "$(printf 'tmpfs /tmp tmpfs rw,noexec 0 0\ntmpfs %s tmpfs rw 0 0' "$T")" tmpnoexec
mk_mounts "$(printf '/dev/b %s/nonexist ext4 rw,noexec 0 0' "$T")" sib
t "noexec mount under LLM_ROOT => BLOCK"       bash -c 'run MOUNTS_FILE="$T/m_noexec" | grep -q "^\[BLOCK\] the filesystem holding .* noexec"'
t "read-only mount under LLM_ROOT => BLOCK"    bash -c 'run MOUNTS_FILE="$T/m_ro" | grep -q "^\[BLOCK\] the filesystem holding .* READ-ONLY"'
t "noexec /tmp => WARN (and not a BLOCK, LLM_ROOT is elsewhere)" bash -c 'o=$(run MOUNTS_FILE="$T/m_tmpnoexec" TMPDIR=/tmp); echo "$o" | grep -q "^\[WARN \] /tmp is mounted noexec" && ! echo "$o" | grep -q "^\[BLOCK\] the filesystem"'
t "negative control: rw /tmp => PASS"          bash -c 'echo "$0" | grep -q "PASS .*/tmp allows executables"' "$OUT"
t "a sibling mount point is not confused with a parent (longest-prefix match is path-aware)" bash -c '! run MOUNTS_FILE="$T/m_sib" | grep -q "^\[BLOCK\] the filesystem"'

echo "# permissions"
mkdir -p "$T/real"; ln -s "$T/real" "$T/linkroot"
t "LLM_ROOT that is a symlink => BLOCK"        bash -c 'run LLM_ROOT="$T/linkroot" | grep -q "^\[BLOCK\] .* is a symlink"'
t "umask 000 => WARN"                          bash -c 'umask 000; run | grep -q "^\[WARN \] umask 0000 is permissive"'
t "umask 002 (group-writable) => WARN"         bash -c 'umask 002; run | grep -q "^\[WARN \] umask 0002 is permissive"'
t "negative control: umask 022 => PASS"        bash -c 'umask 022; run | grep -q "^\[PASS \] umask 0022"'
t "umask 077 is accepted too"                  bash -c 'umask 077; run | grep -q "^\[PASS \] umask 0077"'

echo "# ports"
printf '127.0.0.1\t3101\tnode\n' > "$T/listen_g"; printf '40000-40010\n' > "$T/resv2"
t "guard port already in use => WARN (not BLOCK)" bash -c 'o=$(run LISTENERS_FILE="$T/listen_g"); echo "$o" | grep -q "^\[WARN \] port 3101 for the optional freellmapi guard is already in use" && ! echo "$o" | grep -q "^\[BLOCK\] port 3101"'
t "GUARD_PORT_* override is honoured"          bash -c 'run LISTENERS_FILE="$T/listen_g" GUARD_PORT_FREELLMAPI=3555 | grep -q "port 3555 free for the optional freellmapi guard"'
t "negative control: free guard ports => PASS" bash -c 'echo "$0" | grep -q "PASS .*port 3101 free for the optional freellmapi guard" && echo "$0" | grep -q "PASS .*port 20228 free for the optional omniroute guard"' "$OUT"
t "port inside the ephemeral range => WARN"    bash -c 'run | true; pf "$ROOT/vps/preflight.sh" --offline --freellmapi-port 40000 2>&1 | grep -q "port 40000 lies inside the ephemeral range 32768-60999"'
t "...unless the port is in ip_local_reserved_ports" bash -c '! pf RESERVED_PORTS_FILE="$T/resv2" "$ROOT/vps/preflight.sh" --offline --freellmapi-port 40005 2>&1 | grep -q ephemeral'
t "default ports (3001 / 20128 / 3101 / 20228) are below the range => no ephemeral warning" bash -c '! echo "$0" | grep -q ephemeral' "$OUT"

echo "# existing units"
printf '[Unit]\nDescription=someone else\n[Service]\nExecStart=/usr/bin/other\n' > "$T/units/llm-freellmapi.service"
t "a FOREIGN unit with our name => BLOCK"      bash -c 'run | grep -q "^\[BLOCK\] llm-freellmapi.service exists .* NOT created by this toolkit"'
printf '# FreeLLMAPI gateway ... Rendered by vps/deploy.sh (@...@ are placeholders).\n[Service]\nExecStart=x\n' > "$T/units/llm-freellmapi.service"
t "our own rendered unit => WARN only (idempotent re-run)" bash -c 'o=$(run); echo "$o" | grep -q "^\[WARN \] llm-freellmapi.service already installed by this toolkit" && ! echo "$o" | grep -q "^\[BLOCK\] llm-"'
rm -f "$T/units/llm-freellmapi.service"
printf '[Service]\nExecStart=/opt/other\n' > "$T/units/llm-guard-omniroute.service"
t "a foreign guard unit name is caught too"    bash -c 'run | grep -q "^\[BLOCK\] llm-guard-omniroute.service exists"'
rm -f "$T/units/llm-guard-omniroute.service"
t "negative control: no llm-* units => no unit findings" bash -c '! echo "$0" | grep -q "llm-.*\.service"' "$OUT"

echo "# dependencies"
printf 'x\n' > "$T/ca.crt"
t "missing CA bundle => WARN"                  bash -c 'run CA_BUNDLE="$T/none.crt" | grep -q "^\[WARN \] no CA bundle"'
t "negative control: CA bundle present => PASS" bash -c 'run CA_BUNDLE="$T/ca.crt" | grep -q "^\[PASS \] CA certificate bundle present"'
printf '#!/bin/sh\necho no\n' > "$BIN/timedatectl"; chmod +x "$BIN/timedatectl"
t "unsynchronised clock => WARN"               bash -c 'run | grep -q "^\[WARN \] system clock is not NTP-synchronised"'
printf '#!/bin/sh\necho yes\n' > "$BIN/timedatectl"
t "synchronised clock => PASS"                 bash -c 'run | grep -q "^\[PASS \] system clock is NTP-synchronised"'
rm -f "$BIN/timedatectl"

echo "# network diagnostics (curl/git/getent shimmed; no real traffic)"
runnet() { pf NODE_DIST_URL=https://nodejs.example.invalid "$ROOT/vps/preflight.sh" 2>&1; }
export -f runnet
printf '#!/bin/sh\nprintf 000\nexit 6\n' > "$BIN/curl"; printf '#!/bin/sh\nexit 1\n' > "$BIN/git"; printf '#!/bin/sh\nexit 2\n' > "$BIN/getent"; chmod +x "$BIN/curl" "$BIN/git" "$BIN/getent"
t "no DNS => the failure says DNS, not just 'HTTP 000'" bash -c 'runnet | grep -q "nodejs.org dist: DNS failure: nodejs.example.invalid does not resolve"'
printf '#!/bin/sh\necho "1.2.3.4 $2"\n' > "$BIN/getent"
t "resolves but cannot connect => connection/TLS failure" bash -c 'runnet | grep -q "connection or TLS failure to nodejs.example.invalid"'
printf '#!/bin/sh\nprintf 503\n' > "$BIN/curl"
t "reachable but HTTP error => reports the status"   bash -c 'runnet | grep -q "HTTP 503 from nodejs.example.invalid"'
printf '#!/bin/sh\nprintf 200\n' > "$BIN/curl"; printf '#!/bin/sh\nexit 0\n' > "$BIN/git"
t "negative control: all reachable => PASS lines"    bash -c 'o=$(runnet); echo "$o" | grep -q "PASS .* nodejs.org dist reachable" && echo "$o" | grep -q "PASS .* npm registry reachable"'
rm -f "$BIN/curl" "$BIN/git" "$BIN/getent"

echo "# read-only guarantee"
before="$(cd "$T" && find . -type f -newer "$T/os26" 2>/dev/null | sort | md5sum)"
run >/dev/null; after="$(cd "$T" && find . -type f -newer "$T/os26" 2>/dev/null | sort | md5sum)"
t "preflight creates and modifies no files (outside --out)" test "$before" = "$after"
t "--out is the only thing written, mode 0600"   bash -c 'pf "$ROOT/vps/preflight.sh" --offline --out "$T/report" >/dev/null 2>&1; [ "$(stat -c %a "$T/report")" = 600 ] && grep -q "^RESULT:" "$T/report"'
# Scan a script for write/modify COMMANDS. Comments and string literals are stripped first, so a message that merely mentions "apt" does not count.
scan_writes() {
  sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g" "$1" | grep -vE '^[[:space:]]*#' \
    | grep -E '(^|[;&|(]|then|do|else)[[:space:]]*(rm|mkdir|chmod|chown|useradd|usermod|userdel|apt|apt-get|tee|touch|mv|cp|ln|systemctl (enable|start|restart|stop|disable|daemon-reload))([[:space:]]|$)'
}
export -f scan_writes
t "the real script contains no write/modify command" bash -c '! scan_writes "$ROOT/vps/preflight.sh"'
cp "$ROOT/vps/preflight.sh" "$T/mutant.sh"; printf '\nmkdir -p /tmp/should-not-be-here\n' >> "$T/mutant.sh"
t "mutation control: the scan DOES catch an injected 'mkdir'" bash -c 'scan_writes "$T/mutant.sh"'
printf 'echo "install via apt"  # apt is only text here\n' > "$T/benign.sh"
t "negative control: the word 'apt' inside a string or comment is not flagged" bash -c '! scan_writes "$T/benign.sh"'

echo "preflight-extra: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
