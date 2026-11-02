#!/usr/bin/env node
// Download the OpenCode linux-arm64 binary from the npm registry, VERIFY the registry's sha512 integrity, and extract bin/opencode.
// Used instead of `npm install` because npm skips Linux-only packages on Termux (Node reports platform "android"). Zero dependencies.
//   node fetch-opencode.mjs --version 1.19.5 --out DIR [--package opencode-linux-arm64] [--registry https://registry.npmjs.org]
// Refuses: a wrong platform package, an integrity mismatch, a non-aarch64 binary, a non-https registry (loopback http is allowed for tests only).
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync, renameSync, mkdtempSync, rmSync, openSync, readSync, closeSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';

const a = process.argv.slice(2);
const opt = (k, d) => { const i = a.indexOf(`--${k}`); return i >= 0 ? a[i + 1] : d; };
const version = opt('version'); const out = opt('out'); const pkg = opt('package', 'opencode-linux-arm64'); const registry = String(opt('registry', 'https://registry.npmjs.org')).replace(/\/+$/, '');
const die = (m) => { process.stderr.write(`fetch-opencode: ${m}\n`); process.exit(1); };
if (!/^\d+\.\d+\.\d+$/.test(version ?? '') || !out) die('usage: --version X.Y.Z --out DIR');
const okUrl = (u) => /^https:\/\//.test(u) || /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(u);
if (!okUrl(`${registry}/`)) die('registry must be https');

const bin = path.join(out, 'bin', 'opencode'); const stamp = path.join(out, 'VERSION');
if (existsSync(bin) && existsSync(stamp) && readFileSync(stamp, 'utf8').trim() === version) { console.log(`opencode ${version} binary already present (kept): ${bin}`); process.exit(0); }

const get = async (u, asBuffer) => {
  let lastErr;
  for (let n = 1; n <= 4; n++) {   // mobile networks drop long downloads: retry with growing pauses
    try { const r = await fetch(u, { signal: AbortSignal.timeout(600_000) }); if (!r.ok) throw new Error(`HTTP ${r.status}`); return asBuffer ? Buffer.from(await r.arrayBuffer()) : await r.json(); }
    catch (e) { lastErr = e; await new Promise((res) => setTimeout(res, n * 5000)); }
  }
  die(`download failed: ${u.replace(/\?.*/, '')} (${lastErr?.cause?.code ?? lastErr?.message})`);
};

const meta = await get(`${registry}/${pkg}/${version}`, false);
if (!(meta.os ?? []).includes('linux') || !(meta.cpu ?? []).includes('arm64')) die(`${pkg}@${version} is not a linux/arm64 package (os=${JSON.stringify(meta.os)} cpu=${JSON.stringify(meta.cpu)})`);
const { tarball, integrity } = meta.dist ?? {};
if (!tarball || !/^sha512-/.test(integrity ?? '')) die('registry metadata has no sha512 integrity: refusing to install an unverifiable binary');
if (!okUrl(tarball)) die('tarball URL is not https');
console.log(`downloading ${pkg}@${version} (${Math.round((meta.dist.unpackedSize ?? 0) / 1e6)} MB unpacked)...`);
const buf = await get(tarball, true);
const got = `sha512-${createHash('sha512').update(buf).digest('base64')}`;
if (got !== integrity) die('INTEGRITY MISMATCH: the downloaded file is not what the registry published; nothing was installed');
console.log('integrity verified (sha512 matches the registry)');

const tmp = mkdtempSync(path.join(tmpdir(), 'ocfetch-'));
try {
  writeFileSync(path.join(tmp, 'p.tgz'), buf);
  const t = spawnSync('tar', ['-xzf', path.join(tmp, 'p.tgz'), '-C', tmp, 'package/bin/opencode'], { encoding: 'utf8' });
  const ex = path.join(tmp, 'package', 'bin', 'opencode');
  if (t.status !== 0 || !existsSync(ex)) die(`could not extract bin/opencode (${(t.stderr || '').trim().slice(0, 120)})`);
  const fd = openSync(ex, 'r'); const head = Buffer.alloc(20); readSync(fd, head, 0, 20, 0); closeSync(fd);
  const isElf = head.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46])); const machine = head.readUInt16LE(18);
  if (!isElf || machine !== 0xb7) die(`the extracted file is not an ELF aarch64 binary (machine=0x${machine.toString(16)}); refusing`);
  mkdirSync(path.join(out, 'bin'), { recursive: true });
  writeFileSync(`${bin}.new`, readFileSync(ex));   // copy, not rename: /tmp and the target are often different filesystems on Android
} catch (e) { rmSync(tmp, { recursive: true, force: true }); die(`install step failed: ${String(e.message).slice(0, 160)}`); }
rmSync(tmp, { recursive: true, force: true });
chmodSync(`${bin}.new`, 0o755); renameSync(`${bin}.new`, bin); writeFileSync(stamp, `${version}\n`);
console.log(`installed ${bin}`);
