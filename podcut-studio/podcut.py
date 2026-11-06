#!/usr/bin/env python3
"""PodCut CLI — edit long-form podcasts with ffmpeg, from the command line.

Two jobs, the same ones the PodCut browser tool does, but built to handle a full
2-3 hour recording by streaming through ffmpeg instead of loading it into memory:

  jumpcut   remove silences/dead-air from one recording
  multicam  switch between synced camera tracks to whoever is speaking

It reads a low-rate (1 kHz) mono copy of the audio to find the edits — about 43 MB
of memory for a 3-hour show — then renders with ffmpeg. Needs: python3 and ffmpeg.

Examples
  python3 podcut.py jumpcut episode.mp4 -o episode_cut.mp4
  python3 podcut.py jumpcut episode.mp4 --dry-run          # just report the cuts
  python3 podcut.py jumpcut episode.mp4 --edl episode.edl --dry-run
  python3 podcut.py multicam -o show.mp4 host.mov guest.mov wide.mov
"""
import argparse, array, math, os, shutil, subprocess, sys, tempfile

ANALYZE_RATE = 1000  # Hz; plenty for loudness, tiny in memory even for hours
# Audio cleanup: FFT noise reduction + EBU R128 loudness normalisation to a podcast target.
AUDIO_CLEAN = "afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11"

# ---------------------------------------------------------------- audio input
def ffmpeg_bin():
    b = shutil.which("ffmpeg")
    if not b:
        sys.exit("ffmpeg not found on PATH. Install it (macOS: brew install ffmpeg; "
                 "Ubuntu/Debian: sudo apt install ffmpeg; Windows: https://ffmpeg.org/download.html).")
    return b

def read_mono(path, rate=ANALYZE_RATE):
    if not os.path.isfile(path):
        sys.exit("file not found: " + path)
    cmd = [ffmpeg_bin(), "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", str(rate), "-f", "f32le", "-"]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        sys.exit("ffmpeg could not read audio from " + path + ":\n" + p.stderr.decode("utf-8", "replace"))
    a = array.array("f")
    n = len(p.stdout) // 4
    a.frombytes(p.stdout[:n * 4])
    return a, rate

def probe_duration(path):
    pr = shutil.which("ffprobe")
    if not pr:
        return None
    p = subprocess.run([pr, "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=nk=1:nw=1", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        return float(p.stdout.decode().strip())
    except ValueError:
        return None

# ---------------------------------------------------------------- DSP (ported 1:1 from the tested PodCut core)
def frame_energies(samples, sample_rate, hop_ms=20, win_ms=40):
    hop = max(1, round(sample_rate * hop_ms / 1000))
    win = max(hop, round(sample_rate * win_ms / 1000))
    hop_sec = hop / sample_rate
    db, n = [], len(samples)
    start = 0
    while start < n:
        end = min(n, start + win)
        s = 0.0
        for i in range(start, end):
            v = samples[i]; s += v * v
        rms = math.sqrt(s / max(1, end - start))
        db.append(20 * math.log10(rms) if rms > 0 else float("-inf"))
        start += hop
    return db, hop_sec

def bool_runs(flag, hop_sec, total, want):
    runs, i, n = [], 0, len(flag)
    while i < n:
        if flag[i] == want:
            j = i
            while j < n and flag[j] == want:
                j += 1
            runs.append([i * hop_sec, min(total, j * hop_sec)])
            i = j
        else:
            i += 1
    return runs

def merge_gaps(runs, min_gap):
    if not runs:
        return []
    out = [list(runs[0])]
    for r in runs[1:]:
        if r[0] - out[-1][1] < min_gap:
            out[-1][1] = r[1]
        else:
            out.append(list(r))
    return out

def merge_overlaps(runs):
    if not runs:
        return []
    s = sorted(runs, key=lambda r: r[0])
    out = [list(s[0])]
    for r in s[1:]:
        if r[0] <= out[-1][1]:
            out[-1][1] = max(out[-1][1], r[1])
        else:
            out.append(list(r))
    return out

def complement(runs, total):
    out, cur = [], 0.0
    for r in runs:
        if r[0] > cur:
            out.append([cur, r[0]])
        cur = max(cur, r[1])
    if cur < total:
        out.append([cur, total])
    return out

def analyze_silence(samples, sr, threshold_db=-40, min_silence=0.5, min_keep=0.2, pad=0.12):
    db, hop = frame_energies(samples, sr)
    total = len(samples) / sr
    flag = [d > threshold_db for d in db]
    runs = bool_runs(flag, hop, total, True)
    runs = merge_gaps(runs, min_silence)
    runs = [r for r in runs if (r[1] - r[0]) >= min_keep]
    runs = [[max(0.0, r[0] - pad), min(total, r[1] + pad)] for r in runs]
    runs = merge_overlaps(runs)
    removed = complement(runs, total)
    kept = sum(r[1] - r[0] for r in runs)
    return {"keep": runs, "remove": removed, "total": total, "kept": kept, "removed": total - kept}

def moving_avg_db(arr, k, n):
    out = [0.0] * n
    half = k // 2
    for i in range(n):
        a, b, s, c = max(0, i - half), min(n - 1, i + half), 0.0, 0
        for j in range(a, b + 1):
            d = arr[j]
            s += 0.0 if d == float("-inf") else 10 ** (d / 10)
            c += 1
        p = s / max(1, c)
        out[i] = 10 * math.log10(p) if p > 0 else float("-inf")
    return out

def analyze_multicam(tracks, sr, gate_db=-45, min_shot=1.5, smoothing=0.25, margin=1.0):
    raw = [frame_energies(t, sr) for t in tracks]
    hop = raw[0][1]
    n = min(len(r[0]) for r in raw)
    k = max(1, round(smoothing / hop))
    sm = [moving_avg_db(r[0], k, n) for r in raw]
    total = n * hop
    cur, shot_start, shots = -1, 0.0, []
    for i in range(n):
        best, best_db = -1, float("-inf")
        for c in range(len(sm)):
            if sm[c][i] > best_db:
                best_db, best = sm[c][i], c
        t = i * hop
        if cur == -1:
            cur = best if (best >= 0 and best_db > gate_db) else 0
            shot_start = 0.0
            continue
        can = (t - shot_start) >= min_shot
        if best_db > gate_db and best != cur and can and best_db >= sm[cur][i] + margin:
            shots.append({"start": shot_start, "end": t, "cam": cur})
            cur, shot_start = best, t
    shots.append({"start": shot_start, "end": total, "cam": cur})
    per = [sum(s["end"] - s["start"] for s in shots if s["cam"] == i) for i in range(len(tracks))]
    return {"shots": shots, "total": total, "per_cam": per}

# ---------------------------------------------------------------- exports
def tc(sec, fps):
    sec = max(0.0, sec)
    f = round(sec * fps)
    ff = f % fps; f //= fps
    ss = f % 60; f //= 60
    mm = f % 60; hh = f // 60
    return "%02d:%02d:%02d:%02d" % (hh, mm, ss, ff)

def edl_from_keep(keep, fps, title):
    out = "TITLE: %s\nFCM: NON-DROP FRAME\n" % title
    rec = 0.0
    for i, (s, e) in enumerate(keep, 1):
        dur = e - s
        out += "%03d  AX       V     C        %s %s %s %s\n" % (i, tc(s, fps), tc(e, fps), tc(rec, fps), tc(rec + dur, fps))
        rec += dur
    return out

def edl_from_shots(shots, reels, fps, title="PodCut_multicam"):
    out = "TITLE: %s\nFCM: NON-DROP FRAME\n" % title
    for i, s in enumerate(shots, 1):
        reel = "".join(ch for ch in (reels[s["cam"]] if s["cam"] < len(reels) else "") if ch.isalnum())[:8] or ("CAM%d" % (s["cam"] + 1))
        out += "%03d  %-8s V     C        %s %s %s %s\n" % (i, reel, tc(s["start"], fps), tc(s["end"], fps), tc(s["start"], fps), tc(s["end"], fps))
    return out

def keep_expr(keep):
    return "+".join("between(t,%.3f,%.3f)" % (s, e) for s, e in keep) or "between(t,0,0)"

def fmt_dur(sec):
    sec = max(0.0, sec)
    h = int(sec // 3600); m = int((sec % 3600) // 60); s = sec % 60
    return ("%d:%02d:%05.2f" % (h, m, s)) if h else ("%d:%05.2f" % (m, s))

# ---------------------------------------------------------------- render
def encode_opts(args):
    o = ["-c:v", args.encoder, "-preset", args.preset]
    if args.encoder == "libx264":
        o += ["-crf", str(args.crf)]
    else:  # nvenc/qsv/etc.
        o += ["-cq", str(args.crf)]
    o += ["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", args.abitrate, "-movflags", "+faststart"]
    return o

def run_ffmpeg(cmd):
    print("\n$ " + " ".join(('"%s"' % c if " " in c else c) for c in cmd) + "\n")
    r = subprocess.run(cmd)
    if r.returncode != 0:
        sys.exit("ffmpeg exited with code %d" % r.returncode)

def render_jumpcut(inp, outp, keep, args):
    expr = keep_expr(keep)
    with tempfile.TemporaryDirectory() as td:
        vf = os.path.join(td, "vf.txt"); af = os.path.join(td, "af.txt")
        open(vf, "w").write("select='%s',setpts=N/FRAME_RATE/TB" % expr)
        af_chain = "aselect='%s',asetpts=N/SR/TB" % expr
        if getattr(args, "clean", False):
            af_chain += "," + AUDIO_CLEAN
        open(af, "w").write(af_chain)
        cmd = [ffmpeg_bin(), "-y", "-i", inp, "-filter_script:v", vf, "-filter_script:a", af]
        cmd += encode_opts(args) + [outp]
        run_ffmpeg(cmd)

def render_multicam(files, outp, shots, audio_index, args):
    parts, cat = [], ""
    for i, s in enumerate(shots):
        parts.append("[%d:v]trim=%.3f:%.3f,setpts=PTS-STARTPTS[v%d]" % (s["cam"], s["start"], s["end"], i))
        cat += "[v%d]" % i
    graph = ";".join(parts) + ";" + cat + "concat=n=%d:v=1:a=0[outv]" % len(shots)
    with tempfile.TemporaryDirectory() as td:
        fc = os.path.join(td, "fc.txt"); open(fc, "w").write(graph)
        cmd = [ffmpeg_bin(), "-y"]
        for f in files:
            cmd += ["-i", f]
        cmd += ["-filter_complex_script", fc, "-map", "[outv]", "-map", "%d:a:0" % audio_index]
        if getattr(args, "clean", False):
            cmd += ["-af", AUDIO_CLEAN]
        cmd += encode_opts(args) + [outp]
        run_ffmpeg(cmd)

# ---------------------------------------------------------------- commands
def cmd_jumpcut(args):
    print("Scanning audio of %s ..." % args.input)
    samples, sr = read_mono(args.input)
    r = analyze_silence(samples, sr, args.threshold, args.min_silence, args.min_keep, args.pad)
    pct = (r["removed"] / r["total"] * 100) if r["total"] else 0
    print("  original : %s" % fmt_dur(r["total"]))
    print("  edited   : %s" % fmt_dur(r["kept"]))
    print("  removed  : %s  (%.1f%%, %d cuts)" % (fmt_dur(r["removed"]), pct, len(r["remove"])))
    if args.edl:
        open(args.edl, "w").write(edl_from_keep(r["keep"], args.fps, os.path.splitext(os.path.basename(args.input))[0]))
        print("  EDL      : %s" % args.edl)
    if args.dry_run:
        print("\nDry run — nothing rendered. Re-run without --dry-run to write the edited file.")
        return
    out = args.output or (os.path.splitext(args.input)[0] + "_podcut" + os.path.splitext(args.input)[1])
    print("\nRendering edited file (this re-encodes once; a 2-3 h show takes a while)...")
    render_jumpcut(args.input, out, r["keep"], args)
    print("\nDone -> %s" % out)

def cmd_multicam(args):
    if len(args.tracks) < 2:
        sys.exit("multicam needs at least two synced tracks.")
    print("Scanning %d tracks ..." % len(args.tracks))
    tracks = []
    for f in args.tracks:
        s, sr = read_mono(f); tracks.append(s)
    r = analyze_multicam(tracks, ANALYZE_RATE, args.gate, args.min_shot, args.smoothing, args.margin)
    reels = [os.path.splitext(os.path.basename(f))[0] for f in args.tracks]
    print("  duration : %s" % fmt_dur(r["total"]))
    print("  shots    : %d across %d cameras" % (len(r["shots"]), len(tracks)))
    for i, f in enumerate(args.tracks):
        secs = r["per_cam"][i]; p = (secs / r["total"] * 100) if r["total"] else 0
        print("    cam %d %-20s %s (%.0f%%)" % (i + 1, os.path.basename(f), fmt_dur(secs), p))
    if args.edl:
        open(args.edl, "w").write(edl_from_shots(r["shots"], reels, args.fps))
        print("  EDL      : %s" % args.edl)
    if args.dry_run:
        print("\nDry run — nothing rendered.")
        return
    out = args.output or "podcut_multicam.mp4"
    ai = args.audio_from - 1 if args.audio_from else 0
    print("\nRendering switched video (audio from track %d)..." % (ai + 1))
    render_multicam(args.tracks, out, r["shots"], ai, args)
    print("\nDone -> %s" % out)

def build_parser():
    p = argparse.ArgumentParser(prog="podcut", description="Edit long podcasts with ffmpeg: silence removal and multicam switching.")
    sub = p.add_subparsers(dest="cmd", required=True)

    j = sub.add_parser("jumpcut", help="remove silences from one recording")
    j.add_argument("input")
    j.add_argument("-o", "--output")
    j.add_argument("--threshold", type=float, default=-40, help="dB below which a frame is silent (default -40)")
    j.add_argument("--min-silence", type=float, default=0.5, help="only cut silences at least this long, seconds (default 0.5)")
    j.add_argument("--pad", type=float, default=0.12, help="speech left around each cut, seconds (default 0.12)")
    j.add_argument("--min-keep", type=float, default=0.2, help="drop speech blips shorter than this, seconds (default 0.2)")
    j.add_argument("--fps", type=int, default=30, help="timecode frame rate for the EDL (default 30)")
    j.add_argument("--edl", help="also write an EDL to this path")
    j.add_argument("--dry-run", action="store_true", help="report the cuts without rendering")
    add_encode_args(j)
    j.set_defaults(func=cmd_jumpcut)

    m = sub.add_parser("multicam", help="switch between synced camera tracks")
    m.add_argument("tracks", nargs="+", help="one media file per camera, all starting together")
    m.add_argument("-o", "--output")
    m.add_argument("--gate", type=float, default=-45, help="ignore audio below this dB (default -45)")
    m.add_argument("--min-shot", type=float, default=1.5, help="hold a shot at least this long, seconds (default 1.5)")
    m.add_argument("--smoothing", type=float, default=0.25, help="loudness smoothing, seconds (default 0.25)")
    m.add_argument("--margin", type=float, default=1.0, help="dB a new speaker must beat the current by (default 1.0)")
    m.add_argument("--audio-from", type=int, default=1, help="which track supplies the audio, 1-based (default 1)")
    m.add_argument("--fps", type=int, default=30)
    m.add_argument("--edl", help="also write an EDL to this path")
    m.add_argument("--dry-run", action="store_true")
    add_encode_args(m)
    m.set_defaults(func=cmd_multicam)
    return p

def add_encode_args(sp):
    sp.add_argument("--encoder", default="libx264", help="video encoder (libx264 default; h264_nvenc / h264_qsv for GPU)")
    sp.add_argument("--preset", default="medium", help="encoder preset (default medium; veryfast is quicker, bigger)")
    sp.add_argument("--crf", type=int, default=20, help="quality 0-51, lower is better (default 20)")
    sp.add_argument("--abitrate", default="192k", help="audio bitrate (default 192k)")
    sp.add_argument("--clean", action="store_true", help="clean up audio: reduce background noise and normalise loudness")

def main():
    args = build_parser().parse_args()
    args.func(args)

if __name__ == "__main__":
    main()
