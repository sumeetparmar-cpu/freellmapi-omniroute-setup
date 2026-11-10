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
import argparse, array, json, math, os, re, shutil, subprocess, sys, tempfile

ANALYZE_RATE = 1000  # Hz; plenty for loudness, tiny in memory even for hours
# Audio cleanup: FFT noise reduction + EBU R128 loudness normalisation to a podcast target.
AUDIO_CLEAN = "afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000"

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
    return analyze_db(db, hop, len(samples) / sr, threshold_db, min_silence, min_keep, pad)

def analyze_db(db, hop, total, threshold_db=-40, min_silence=0.5, min_keep=0.2, pad=0.12):
    # Same decision as analyze_silence, from loudness frames that were already measured.
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

def script_flag(td, kind="filter"):
    """ffmpeg 7+ reads a filter from a file with -/filter; older builds use -filter_script. Ask the binary."""
    probe = os.path.join(td, "probe.txt")
    open(probe, "w").write("anull")
    r = subprocess.run([ffmpeg_bin(), "-v", "error", "-f", "lavfi", "-i", "anullsrc=d=0.05", "-/filter:a", probe,
                        "-f", "null", "-"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return ("-/" + kind) if r.returncode == 0 else ("-" + kind + "_script")

def render_jumpcut(inp, outp, keep, args):
    # Frame-accurate: picture and sound are cut on the same grid, so lip-sync holds over any number of cuts.
    media = probe_media(inp) or {"has_video": False}
    fps = media["fps"] if media.get("has_video") else (100, 1)
    spec = default_spec(clean=bool(getattr(args, "clean", False)))
    with tempfile.TemporaryDirectory() as td:
        vf, af, _, _ = build_filters(quantize_keep(keep, fps), fps, media, spec, os.path.join(td, "cmds.txt"))
        flag, cmd = script_flag(td), [ffmpeg_bin(), "-y", "-i", inp]
        if vf:
            open(os.path.join(td, "vf.txt"), "w").write(vf)
            cmd += [flag + ":v", os.path.join(td, "vf.txt")]
        else:
            cmd += ["-vn"]
        open(os.path.join(td, "af.txt"), "w").write(af)
        cmd += [flag + ":a", os.path.join(td, "af.txt")]
        cmd += (encode_opts(args) if vf else ["-c:a", "aac", "-b:a", args.abitrate]) + [outp]
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
        cmd += [script_flag(td, "filter_complex"), fc, "-map", "[outv]", "-map", "%d:a:0" % audio_index]
        if getattr(args, "clean", False):
            cmd += ["-af", AUDIO_CLEAN]
        cmd += encode_opts(args) + [outp]
        run_ffmpeg(cmd)

# ---------------------------------------------------------------- single-camera auto-angles
def even(x):
    x = int(round(x)); return x - (x % 2)

# Crop rectangles as fractions (w, h, x, y) of the frame; angle 0 is always the full wide shot.
LAYOUTS = {
    "single": [None, (0.70, 0.70, 0.15, 0.08)],
    "duo":    [None, (0.60, 0.60, 0.00, 0.12), (0.60, 0.60, 0.40, 0.12)],
}

def probe_dimensions(path):
    pr = shutil.which("ffprobe")
    if not pr:
        return None
    p = subprocess.run([pr, "-v", "error", "-select_streams", "v:0", "-show_entries",
                        "stream=width,height", "-of", "csv=p=0:s=x", path],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        w, h = p.stdout.decode().strip().split("x")
        return int(w), int(h)
    except Exception:
        return None

def auto_angle_shots(keep, total, n_angles, min_shot=2.5, wide_every=3):
    # Cut at the start of speech runs (each conversational "beat"); no shot shorter than min_shot.
    cuts = [0.0]
    for s, e in keep:
        if s - cuts[-1] >= min_shot:
            cuts.append(s)
    if len(cuts) > 1 and total - cuts[-1] < min_shot:
        cuts.pop()
    cuts.append(total)
    shots, punch = [], 1
    for i in range(len(cuts) - 1):
        if n_angles <= 1:
            angle = 0
        elif i % wide_every == 0:
            angle = 0            # periodic wide shot
        else:
            angle = punch
            if n_angles > 2:
                punch = 1 + (punch % (n_angles - 1))
        shots.append({"start": cuts[i], "end": cuts[i + 1], "angle": angle})
    return shots

def render_autocam(video, outp, shots, layout, W, H, args):
    rects = LAYOUTS[layout]
    parts, cat = [], ""
    for i, s in enumerate(shots):
        base = "[0:v]trim=%.3f:%.3f,setpts=PTS-STARTPTS" % (s["start"], s["end"])
        rect = rects[s["angle"]] if s["angle"] < len(rects) else None
        if rect:
            fw, fh, fx, fy = rect
            cw, ch = even(fw * W), even(fh * H)
            cx, cy = min(even(fx * W), W - cw), min(even(fy * H), H - ch)
            base += ",crop=%d:%d:%d:%d" % (cw, ch, cx, cy)
        base += ",scale=%d:%d,setsar=1[v%d]" % (W, H, i)
        parts.append(base); cat += "[v%d]" % i
    graph = ";".join(parts) + ";" + cat + "concat=n=%d:v=1:a=0[outv]" % len(shots)
    with tempfile.TemporaryDirectory() as td:
        fc = os.path.join(td, "fc.txt"); open(fc, "w").write(graph)
        cmd = [ffmpeg_bin(), "-y", "-i", video, script_flag(td, "filter_complex"), fc,
               "-map", "[outv]", "-map", "0:a:0?"]
        if getattr(args, "clean", False):
            cmd += ["-af", AUDIO_CLEAN]
        cmd += encode_opts(args) + [outp]
        run_ffmpeg(cmd)

# ---------------------------------------------------------------- frame-accurate edits (PodCut Studio)
# The studio cuts picture and sound on the same frame grid, so lip-sync cannot drift however
# many cuts an episode has, and it describes the whole edit as two short linear filter chains.
OUT_RATE = 48000   # sound is brought to this rate before it is cut
CHUNK = 256        # ...and cut in chunks of this many samples (5.3 ms)
STD_RATES = [(24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (50, 1), (60000, 1001), (60, 1)]
FOCUS = {"single": [(0.5, 0.42)], "duo": [(0.27, 0.42), (0.73, 0.42)],
         "trio": [(0.2, 0.42), (0.5, 0.42), (0.8, 0.42)]}

def snap_rate(val):
    n, d = min(STD_RATES, key=lambda nd: abs(val - nd[0] / nd[1]))   # nearest: 30 and 29.97 are only 0.1% apart
    if abs(val - n / d) <= 0.005 * n / d:
        return (n, d)
    return (int(round(val * 100)), 100)

def _ratio(txt):
    try:
        a, b = str(txt).split("/")
        return float(a) / float(b) if float(b) else 0.0
    except Exception:
        return 0.0

def probe_media(path):
    """What the file holds: picture size as displayed, frame rate, duration. None if unreadable."""
    pr = shutil.which("ffprobe")
    if not pr:
        return None
    p = subprocess.run([pr, "-v", "error", "-show_streams", "-show_format", "-of", "json", path],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        info = json.loads(p.stdout.decode("utf-8", "replace") or "{}")
    except ValueError:
        return None
    out = {"has_video": False, "has_audio": False, "width": 0, "height": 0, "fps": (30, 1), "duration": 0.0}
    try:
        out["duration"] = float(info.get("format", {}).get("duration") or 0)
    except ValueError:
        pass
    for st in info.get("streams", []):
        if st.get("codec_type") == "audio":
            out["has_audio"] = True
        elif st.get("codec_type") == "video" and not out["has_video"]:
            if st.get("disposition", {}).get("attached_pic"):
                continue                                   # cover art, not a picture track
            w, h, rot = int(st.get("width") or 0), int(st.get("height") or 0), 0.0
            if not w or not h:
                continue
            try:
                rot = float(st.get("tags", {}).get("rotate", 0))
            except ValueError:
                pass
            for sd in st.get("side_data_list", []):
                try:
                    rot = float(sd.get("rotation", rot))
                except (TypeError, ValueError):
                    pass
            if int(abs(rot)) % 180 == 90:                 # ffmpeg turns the picture before filtering
                w, h = h, w
            rate = _ratio(st.get("avg_frame_rate"))
            if not 5 <= rate <= 120:
                rate = _ratio(st.get("r_frame_rate"))
            if not 5 <= rate <= 120:
                rate = 30.0
            out.update(has_video=True, width=even(w), height=even(h), fps=snap_rate(rate))
    return out

def subtract_ranges(runs, cuts):
    out = [list(r) for r in runs]
    for c0, c1 in merge_overlaps([list(c) for c in cuts]):
        nxt = []
        for s, e in out:
            if e <= c0 or s >= c1:
                nxt.append([s, e]); continue
            if s < c0:
                nxt.append([s, c0])
            if e > c1:
                nxt.append([c1, e])
        out = nxt
    return out

def quantize_keep(keep, fps):
    """Snap kept ranges to whole frames -> sorted, merged [first_frame, end_frame) pairs."""
    r, out = fps[0] / fps[1], []
    for s, e in keep:
        a, b = int(round(s * r)), int(round(e * r))
        if b <= a:
            continue
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out

def audio_plan(frames, fps):
    """Sound chunks that follow the picture cuts: every segment starts with its picture and the
    running total stays within half a chunk (2.7 ms) of the picture, whatever the number of cuts."""
    r, k = fps[0] / fps[1], OUT_RATE / CHUNK
    out, vdone, adone, prev_end = [], 0, 0, 0
    for a, b in frames:
        vdone += b - a
        start = max(prev_end, int(round(a / r * k)))
        n = int(round(vdone / r * k)) - adone
        if n > 0:
            out.append([start, start + n]); adone += n; prev_end = start + n
    return out

def tree_expr(ranges, var="n"):
    """ffmpeg expression that is true inside any [a, b) range, as a balanced if() tree (log time per frame)."""
    def rec(lo, hi):
        if hi - lo == 1:
            return "between(%s,%d,%d)" % (var, ranges[lo][0], ranges[lo][1] - 1)
        mid = (lo + hi) // 2
        return "if(lt(%s,%d),%s,%s)" % (var, ranges[mid][0], rec(lo, mid), rec(mid, hi))
    return rec(0, len(ranges)) if ranges else "0"

def zoom_rect(focus, zoom):
    """(w, h, x, y) as fractions: a punch-in showing `zoom` of the frame around a focus point, same shape as the frame."""
    z = min(0.95, max(0.35, zoom))
    return (z, z, min(1 - z, max(0.0, focus[0] - z / 2)), min(1 - z, max(0.0, focus[1] - z / 2)))

def plan_shots(frames, fps, spec):
    """Virtual camera angles on the edited timeline -> [(output_frame, rect or None for the wide shot)].
    The angle changes on a cut once a shot has run min_shot, and inside a long take after max_shot."""
    r = fps[0] / fps[1]
    lo, hi = max(1, int(spec["min_shot"] * r)), max(2, int(spec["max_shot"] * r))
    focus, every = FOCUS.get(spec["layout"], FOCUS["duo"]), max(2, int(spec["wide_every"]))
    shots, st = [(0, None)], {"shot0": 0, "sw": 0, "punch": 0}
    def switch(at):
        st["sw"] += 1; st["shot0"] = at
        if st["sw"] % every == 0:
            shots.append((at, None))
        else:
            shots.append((at, zoom_rect(focus[st["punch"] % len(focus)], spec["zoom"]))); st["punch"] += 1
    pos = 0
    for a, b in frames:
        if pos and pos - st["shot0"] >= lo:
            switch(pos)
        end = pos + (b - a)
        while end - st["shot0"] > hi:
            switch(st["shot0"] + hi)
        pos = end
    return shots

def out_seconds(frames, fps):
    return sum(b - a for a, b in frames) * fps[1] / fps[0]

def edited_to_source(frames, fps, t):
    """The source time that plays at edited-timeline time t."""
    r = fps[0] / fps[1]; left = max(0.0, t) * r
    for a, b in frames:
        if left <= b - a:
            return (a + left) / r
        left -= b - a
    return frames[-1][1] / r if frames else 0.0

def default_spec(**kw):
    s = {"silence": True, "threshold": -40.0, "min_silence": 0.5, "pad": 0.12, "min_keep": 0.2,
         "clean": True, "lufs": -16, "angles": False, "layout": "duo", "zoom": 0.62,
         "min_shot": 3.0, "max_shot": 14.0, "wide_every": 3, "fade": 0.0, "cuts": [], "protect": []}
    s.update(kw)
    return s

def edit_frames(db, hop, total, fps, spec):
    """The whole edit as kept frame ranges: silence removal, then restored pauses, then manual cuts."""
    if spec["silence"]:
        keep = analyze_db(db, hop, total, spec["threshold"], spec["min_silence"], spec["min_keep"], spec["pad"])["keep"]
    else:
        keep = [[0.0, total]]
    if spec["protect"]:
        keep = merge_overlaps(keep + [list(p) for p in spec["protect"]])
    if spec["cuts"]:
        keep = subtract_ranges(keep, spec["cuts"])
    return quantize_keep(keep, fps)

def build_filters(frames, fps, media, spec, cmd_path):
    """-> (video chain or None, audio chain, sendcmd file text, output seconds)."""
    r = fps[0] / fps[1]
    dur = out_seconds(frames, fps)
    fade = float(spec.get("fade") or 0)
    if fade * 2 >= dur:
        fade = 0
    vf, cmds = None, ""
    if media.get("has_video"):
        W, H = media["width"], media["height"]
        vf = "fps=%d/%d:start_time=0,select='%s',setpts=N/FRAME_RATE/TB" % (fps[0], fps[1], tree_expr(frames))
        if spec.get("angles"):
            lines = []
            for at, rect in plan_shots(frames, fps, spec)[1:]:
                if rect:
                    cw, ch = even(rect[0] * W), even(rect[1] * H)
                    cx, cy = min(even(rect[2] * W), W - cw), min(even(rect[3] * H), H - ch)
                else:
                    cw, ch, cx, cy = W, H, 0, 0
                # the last command makes the scaler re-read its new input size
                lines.append("%.4f crop@c w %d, crop@c h %d, crop@c x %d, crop@c y %d, scale@z w %d;"
                             % (max(0.0, (at - 0.5) / r), cw, ch, cx, cy, W))
            cmds = "\n".join(lines) + "\n"
            vf += ",sendcmd=f=%s,crop@c=w=%d:h=%d:x=0:y=0,scale@z=w=%d:h=%d:flags=bicubic,setsar=1" % (cmd_path, W, H, W, H)
        else:
            vf += ",crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0"
        if fade:
            vf += ",fade=t=in:st=0:d=%.2f,fade=t=out:st=%.3f:d=%.2f" % (fade, dur - fade, fade)
    af = "aresample=%d:async=1:first_pts=0,asetnsamples=n=%d:p=0,aselect='%s',asetpts=N/SR/TB" % (
        OUT_RATE, CHUNK, tree_expr(audio_plan(frames, fps)))
    if spec.get("clean"):
        af += ",afftdn=nf=-25,loudnorm=I=%d:TP=-1.5:LRA=11,aresample=%d" % (int(spec.get("lufs", -16)), OUT_RATE)
    if fade:
        af += ",afade=t=in:st=0:d=%.2f,afade=t=out:st=%.3f:d=%.2f" % (fade, dur - fade, fade)
    return vf, af, cmds, dur

# ---------------------------------------------------------------- edit by typing
_T = (r"(\d+:\d{1,2}:\d{1,2}(?:\.\d+)?|\d+:\d{1,2}(?:\.\d+)?|"
      r"\d+(?:\.\d+)?\s*(?:hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"
      r"(?:\s*(?:and\s*)?\d+(?:\.\d+)?\s*(?:minutes?|mins?|m|seconds?|secs?|s)\b)*|\d+(?:\.\d+)?)")
_SEP = r"\s*(?:to|until|till|through|thru|and|-|–|—)\s*"
_OFF = r"\b(no|not|off|disable|disabled|without|don'?t|dont|do not|stop|remove|kill|drop|turn off)\b"
HELP = ("Try: tighter / looser · cut 1:20 to 1:45 · remove the first 30 seconds · end at 42:10 · "
        "restore the pause at 3:20 · audio cleanup off · louder · multi-angle on · zoom in more · "
        "switch angles slower · fade in and out · undo · reset · render")

def parse_time(tok):
    tok = tok.strip().lower()
    if ":" in tok:
        v = 0.0
        for part in tok.split(":"):
            v = v * 60 + float(part)
        return v
    v = 0.0
    for num, unit in re.findall(r"(\d+(?:\.\d+)?)\s*([a-z]*)", tok):
        v += float(num) * (3600 if unit.startswith("h") else 60 if unit.startswith("m") else 1)
    return v

def clock(sec):
    sec = max(0.0, sec); h, m, s = int(sec // 3600), int(sec % 3600 // 60), int(sec % 60)
    return ("%d:%02d:%02d" % (h, m, s)) if h else ("%d:%02d" % (m, s))

def describe_spec(sp):
    bits = [("Silence removal on (%d dB, pauses over %.2f s, %.2f s padding)" % (sp["threshold"], sp["min_silence"], sp["pad"]))
            if sp["silence"] else "Silence removal off",
            ("audio cleanup on (%d LUFS)" % sp["lufs"]) if sp["clean"] else "audio cleanup off",
            ("multi-angle on (%s, shots about %.0f s)" % ({"single": "one person", "duo": "two people", "trio": "three people"}
                                                         .get(sp["layout"], sp["layout"]), sp["min_shot"]))
            if sp["angles"] else "multi-angle off"]
    if sp["cuts"]:
        bits.append("%d manual cut%s" % (len(sp["cuts"]), "" if len(sp["cuts"]) == 1 else "s"))
    if sp["fade"]:
        bits.append("fades on")
    return "; ".join(bits) + "."

def _pace(sp, step):
    sp["silence"] = True
    sp["threshold"] = min(-20.0, max(-60.0, sp["threshold"] + 3 * step))
    sp["min_silence"] = round(min(3.0, max(0.15, sp["min_silence"] * 0.75 ** step)), 3)
    sp["pad"] = round(min(0.5, max(0.03, sp["pad"] * 0.85 ** step)), 3)
    return "%s: pauses over %.2f s are cut, with %.2f s of padding." % ("Tighter" if step > 0 else "Looser", sp["min_silence"], sp["pad"])

def _restore(sp, t, cx):
    r, pos, prev, best = cx["fps"][0] / cx["fps"][1], 0, 0, None
    gaps = []
    for a, b in cx["frames"]:
        if a > prev:
            gaps.append((pos / r, prev / r, a / r))
        pos += b - a; prev = b
    if cx["total"] - prev / r > 0.05:
        gaps.append((pos / r, prev / r, cx["total"]))
    for g in gaps:
        if best is None or abs(g[0] - t) < abs(best[0] - t):
            best = g
    if best is None:
        return "There are no cuts to restore."
    if abs(best[0] - t) > 5:
        return "There is no cut within 5 seconds of %s; the nearest is at %s." % (clock(t), clock(best[0]))
    sp["cuts"] = [c for c in sp["cuts"] if c[1] <= best[1] + 1e-6 or c[0] >= best[2] - 1e-6]
    sp["protect"].append([best[1], best[2]])
    return "Restored %.1f s at %s." % (best[2] - best[1], clock(best[0]))

def _one(c, sp, cx):
    has = lambda pat: re.search(pat, c) is not None
    src, edited, total = cx["src"], cx["edited"], cx["total"]
    if has(r"^(help|\?+|commands?|what can (i|you) .*)$"):
        return ("help",)
    if has(r"^(undo|go back|undo that|undo (the )?last.*|revert that)$"):
        return ("undo",)
    if has(r"^(reset|start over|start again|reset (all|everything|it)|undo (all|everything))$"):
        return ("reset",)
    if has(r"^(render|export|finali[sz]e|make (the )?final|save)\b"):
        return ("render",)
    if has(r"\b(captions?|subtitles?|filler|transcri\w*)\b"):
        return "Captions and filler-word removal are not available yet."
    m = re.search(r"\b(?:keep only|only keep|keep just|just keep)\s+(?:from\s+)?%s%s%s" % (_T, _SEP, _T), c)
    if m:
        a, b = parse_time(m.group(1)), min(parse_time(m.group(2)), edited)
        if not a < b:
            return "The start time must be before the end time."
        sp["cuts"] += [[0.0, src(a)], [src(b), total]]
        return "Kept only %s to %s." % (clock(a), clock(b))
    m = re.search(r"\b(?:restore|put back|bring back|uncut|un-cut|undo|keep)\b.*?\b(?:at|around|near)\s+%s" % _T, c)
    if m:
        return _restore(sp, parse_time(m.group(1)), cx)
    m = re.search(r"\b(?:cut|remove|delete|trim|drop|chop|skip|take out|get rid of)\b.*?%s%s%s" % (_T, _SEP, _T), c)
    if m:
        a, b = parse_time(m.group(1)), min(parse_time(m.group(2)), edited)
        if not a < b:
            return "The start time must be before the end time (the edit is %s long)." % clock(edited)
        sp["cuts"].append([src(a), src(b)])
        return "Cut %s to %s (%.1f s)." % (clock(a), clock(b), b - a)
    m = re.search(r"\b(?:cut|remove|delete|trim|drop|chop|skip)\b\s+(?:the\s+)?%s\s+(?:from|off|at)\s+(?:the\s+)?(start|beginning|front|top|end|back)" % _T, c)
    if m:
        d, at_end = min(parse_time(m.group(1)), edited), m.group(2) in ("end", "back")
        sp["cuts"].append([src(edited - d), total] if at_end else [0.0, src(d)])
        return "Removed the %s %s." % ("last" if at_end else "first", clock(d))
    m = (re.search(r"\b(?:start|begin)\w*\s+(?:at|from)\s+%s" % _T, c)
         or re.search(r"\b(?:cut|remove|delete|trim|drop|chop|skip)\b.*?\b(?:first|beginning|start|intro)\b.*?%s" % _T, c)
         or re.search(r"\beverything before\s+%s" % _T, c))
    if m:
        d = min(parse_time(m.group(1)), edited)
        sp["cuts"].append([0.0, src(d)])
        return "Removed the first %s." % clock(d)
    m = re.search(r"\b(?:cut|remove|delete|trim|drop|chop)\b.*?\blast\s+%s" % _T, c)
    if m:
        d = min(parse_time(m.group(1)), edited)
        sp["cuts"].append([src(edited - d), total])
        return "Removed the last %s." % clock(d)
    m = re.search(r"\b(?:end|stop|finish)\w*\s+at\s+%s" % _T, c) or re.search(r"\beverything after\s+%s" % _T, c)
    if m:
        d = parse_time(m.group(1))
        if d >= edited:
            return "The edit is only %s long." % clock(edited)
        sp["cuts"].append([src(d), total])
        return "It now ends at %s." % clock(d)
    m = re.search(r"threshold\D*?(-?\d+(?:\.\d+)?)", c)
    if m:
        sp["threshold"] = min(-20.0, max(-60.0, -abs(float(m.group(1))))); sp["silence"] = True
        return "Silence threshold set to %d dB." % sp["threshold"]
    m = re.search(r"\b(?:min(?:imum)?[ -]?(?:silence|pause|gap)|pauses? (?:longer|over|above))\D*?(\d+(?:\.\d+)?)\s*(ms)?", c)
    if m:
        sp["min_silence"] = min(5.0, max(0.1, float(m.group(1)) / (1000 if m.group(2) else 1))); sp["silence"] = True
        return "Pauses longer than %.2f s are cut." % sp["min_silence"]
    m = re.search(r"\bpad(?:ding)?\D*?(\d+(?:\.\d+)?)\s*(ms)?", c)
    if m:
        sp["pad"] = min(1.0, max(0.0, float(m.group(1)) / (1000 if m.group(2) else 1)))
        return "Padding set to %.2f s." % sp["pad"]
    if has(r"\b(keep (all )?(the )?(silences?|pauses)|(no|without|disable|turn off|stop) (the )?(silence|pause)s? ?(removal|cutting|cuts|trimming)?|"
           r"(don'?t|dont|do not|stop) (cut|remov|trim)\w* (the )?(silences?|pauses)|silence removal off)\b"):
        sp["silence"] = False
        return "Silence removal off — only your manual cuts apply."
    if has(r"\b((remove|cut|trim) (the )?(silences?|pauses|dead air)|silence removal( on)?|turn on silence\w*)\b"):
        sp["silence"] = True
        return "Silence removal on."
    if has(r"\bfad(e|es|ing)\b"):
        m = re.search(r"(\d+(?:\.\d+)?)\s*(?:s|secs?|seconds?)\b", c)
        sp["fade"] = 0.0 if has(_OFF) else min(5.0, max(0.1, float(m.group(1)))) if m else 0.6
        return "Fades off." if not sp["fade"] else "Fade in and out added (%.1f s)." % sp["fade"]
    if has(r"\b(angles?|multi[- ]?(cam|angle|camera)\w*|zoom\w*|punch\w*|cameras?|shots?|wide|close[- ]?ups?|"
           r"(one|two|three|1|2|3) (person|people|persons|speakers?|hosts?|guests?)|solo)\b"):
        if not cx["has_video"]:
            return "This file has no picture, so angles do not apply."
        m = re.search(r"\b(?:hold|shots?|angles?|every)\b.*?(\d+(?:\.\d+)?)\s*(?:s|secs?|seconds?)\b", c)
        if has(r"\b(one|1) (person|speaker|host)|solo\b"):
            sp.update(angles=True, layout="single"); return "Multi-angle on, framed for one person."
        if has(r"\b(two|2) (person|people|persons|speakers|hosts|guests)\b"):
            sp.update(angles=True, layout="duo"); return "Multi-angle on, framed for two people."
        if has(r"\b(three|3) (person|people|persons|speakers|hosts|guests)\b"):
            sp.update(angles=True, layout="trio"); return "Multi-angle on, framed for three people."
        if m:
            sp.update(angles=True, min_shot=min(30.0, max(1.5, float(m.group(1)))))
            sp["max_shot"] = max(sp["max_shot"], sp["min_shot"] * 3)
            return "Angles now hold for about %.1f s." % sp["min_shot"]
        if has(r"\b(more zoom|zoom(ed)? in more|zoom more|closer|tighter)\b"):
            sp.update(angles=True, zoom=round(max(0.4, sp["zoom"] - 0.08), 2)); return "Zooming in closer."
        if has(r"\b(less zoom|zoom(ed)? (in )?less|zoom out|not so close|too (close|zoomed|tight))\b"):
            sp.update(angles=True, zoom=round(min(0.9, sp["zoom"] + 0.08), 2)); return "Zooming in less."
        if has(r"\bmore wide\b"):
            sp.update(angles=True, wide_every=max(2, sp["wide_every"] - 1)); return "More wide shots."
        if has(r"\b(less|fewer) wide\b"):
            sp.update(angles=True, wide_every=min(8, sp["wide_every"] + 1)); return "Fewer wide shots."
        if has(r"\b(faster|quicker|more often|more frequent\w*|more (switch|chang|cut)\w*)\b"):
            sp.update(angles=True, min_shot=round(max(1.5, sp["min_shot"] * 0.7), 1), max_shot=round(max(5.0, sp["max_shot"] * 0.7), 1))
            return "Angles change more often (about every %.1f s)." % sp["min_shot"]
        if has(r"\b(slower|less often|longer|calmer|fewer (switch|chang|cut)\w*|too (fast|many|often|much))\b"):
            sp.update(angles=True, min_shot=round(min(30.0, sp["min_shot"] * 1.4), 1), max_shot=round(min(90.0, sp["max_shot"] * 1.4), 1))
            return "Angles change less often (about every %.1f s)." % sp["min_shot"]
        if has(_OFF):
            sp["angles"] = False; return "Multi-angle off."
        sp["angles"] = True
        return "Multi-angle on."
    if has(r"\b(audio|sound|noise|clean\w*|denois\w*|volume|loud\w*|quiet\w*|softer|boost|enhance\w*)\b"):
        if has(r"\b(louder|volume up|more volume|too (quiet|soft)|boost)\b"):
            sp.update(clean=True, lufs=min(-12, sp["lufs"] + 2)); return "Louder (target %d LUFS)." % sp["lufs"]
        if has(r"\b(quieter|softer|volume down|less volume|too loud)\b"):
            sp.update(clean=True, lufs=max(-24, sp["lufs"] - 2)); return "Quieter (target %d LUFS)." % sp["lufs"]
        if has(r"\b(raw|original)\b") or (has(_OFF) and not has(r"\b(remove|reduce|cut|kill|drop) (the )?(background )?noise\b")):
            sp["clean"] = False; return "Audio cleanup off — the original sound is kept."
        sp["clean"] = True
        return "Audio cleanup on (less noise, even volume)."
    step = 2 if has(r"\b(much|a lot|way|far|very|super|lots)\b") else 0.5 if has(r"\b(bit|slightly|little|tad)\b") else 1
    if has(r"\b(tighter|tighten|tight|cut more|more cuts|more aggressive|aggressive|faster|quicker|snappier|punchier|remove more|"
           r"shorter (pauses|gaps|silences?)|less (silence|pauses?|dead air|gaps?)|too (slow|long|loose|many pauses|much silence))\b"):
        return _pace(sp, step)
    if has(r"\b(looser|loosen|loose|cut less|fewer cuts|less cuts|less aggressive|gentler|more natural|natural|slower|"
           r"longer (pauses|gaps)|more (pauses?|breathing|room|air|space)|keep more|too (choppy|tight|fast|aggressive|jumpy|abrupt|many cuts))\b"):
        return _pace(sp, -step)
    if has(r"\b(status|settings|summary|what did you|what have you)\b"):
        return describe_spec(sp)
    return None

def apply_command(text, spec, frames, fps, total, has_video=True):
    """Apply a plain-English instruction. -> (new spec, replies, action) with action None/'undo'/'reset'/'render'."""
    sp = json.loads(json.dumps(spec))
    edited = out_seconds(frames, fps)
    cx = {"frames": frames, "fps": fps, "total": total, "edited": edited, "has_video": has_video,
          "src": lambda t: edited_to_source(frames, fps, min(max(t, 0.0), edited))}
    replies, action = [], None
    for c in [x.strip(" .!,") for x in re.split(r"[;\n]+|\.\s+|\bthen\b|\balso\b", text.lower())][:8]:
        if not c:
            continue
        parts, got = [c], None
        if " and " in c:
            # "tighter and louder", "cut 1:00 to 1:10 and 2:00 to 2:10": each half is its own instruction,
            # the second borrowing the verb if it has none. "cut between 1:00 and 1:10" is not: halves fail.
            halves, trial = [x.strip() for x in c.split(" and ") if x.strip()], json.loads(json.dumps(sp))
            res = []
            for i, x in enumerate(halves):
                g = _one(x, trial, cx)
                if g is None and i:
                    g = _one(halves[0].split()[0] + " " + x, trial, cx)
                res.append(g)
            if res and all(g is not None for g in res):
                sp.clear(); sp.update(trial); parts, got = halves, res
        if got is None:
            got = [_one(c, sp, cx)]
        for part, g in zip(parts, got):
            if g in replies:
                continue
            if g is None:
                replies.append("I did not understand “%s”." % part[:60])
            elif isinstance(g, tuple):
                action = g[0]
                if action == "help":
                    replies.append(HELP); action = None
            else:
                replies.append(g)
    if replies and all(x.startswith("I did not understand") for x in replies):
        replies.append(HELP)
    return sp, replies, action

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

def cmd_autocam(args):
    dim = probe_dimensions(args.input)
    if not dim:
        sys.exit("Could not read the video's size (need ffprobe and a real video file).")
    W, H = even(dim[0]), even(dim[1])
    print("Scanning %s (%dx%d) ..." % (args.input, W, H))
    samples, sr = read_mono(args.input)
    sil = analyze_silence(samples, sr, args.threshold, args.min_silence, 0.2, args.pad)
    n_angles = len(LAYOUTS[args.layout])
    shots = auto_angle_shots(sil["keep"], sil["total"], n_angles, args.min_shot, args.wide_every)
    names = {0: "WIDE", 1: ("ZOOM" if args.layout == "single" else "LEFT"), 2: "RIGHT"}
    print("  layout   : %s (%d angles)" % (args.layout, n_angles))
    print("  duration : %s" % fmt_dur(sil["total"]))
    print("  shots    : %d" % len(shots))
    for s in shots[:12]:
        print("    %-5s %s - %s" % (names.get(s["angle"], "A%d" % s["angle"]), fmt_dur(s["start"]), fmt_dur(s["end"])))
    if len(shots) > 12:
        print("    ... (%d more)" % (len(shots) - 12))
    if args.dry_run:
        print("\nDry run - nothing rendered.")
        return
    out = args.output or (os.path.splitext(args.input)[0] + "_angles" + os.path.splitext(args.input)[1])
    print("\nRendering multi-angle edit...")
    render_autocam(args.input, out, shots, args.layout, W, H, args)
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

    a = sub.add_parser("autocam", help="make multi-angle cuts from a single camera")
    a.add_argument("input")
    a.add_argument("-o", "--output")
    a.add_argument("--layout", choices=["single", "duo"], default="duo",
                   help="single = one person (wide + zoom-in); duo = two people side by side (wide + left + right)")
    a.add_argument("--min-shot", type=float, default=2.5, help="hold each angle at least this long, seconds (default 2.5)")
    a.add_argument("--wide-every", type=int, default=3, help="show the wide shot every Nth cut (default 3)")
    a.add_argument("--threshold", type=float, default=-40)
    a.add_argument("--min-silence", type=float, default=0.5)
    a.add_argument("--pad", type=float, default=0.12)
    a.add_argument("--fps", type=int, default=30)
    a.add_argument("--dry-run", action="store_true")
    add_encode_args(a)
    a.set_defaults(func=cmd_autocam)
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
