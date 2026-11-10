#!/usr/bin/env python3
"""PodCut Studio — a small authenticated web service that edits a full podcast
server-side, from any device. Upload an episode, watch the edit live in the page,
change it by typing, then render the final file once. Deliberately conservative on a
shared box: one job at a time, nice'd ffmpeg, upload cap, free-disk guard,
auto-cleanup. The edit logic lives in podcut.py. Configuration (environment):

  PODCUT_SECRET       cookie-signing secret (required in production)
  PODCUT_PWHASH       login password hash as "iterations$salthex$hashhex" (required)
  PODCUT_DATA_DIR     where jobs/outputs live (default ./podcut-data)
  PODCUT_PORT         loopback port to bind (default 8820)
  PODCUT_MAX_GB       max upload size in GB (default 8)
  PODCUT_KEEP_HOURS   hours an idle episode is kept before it is deleted (default 12)
  PODCUT_MIN_FREE_GB  uploads and renders never take the disk below this (default 2)
  PODCUT_PRESET       x264 preset (default veryfast — light on a shared CPU)
  PODCUT_CRF          quality 0-51 (default 21)
"""
import array, base64, hashlib, hmac, html, json, os, queue, re, shutil, subprocess, sys, threading, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import podcut  # the edit logic

from flask import Flask, request, send_file, redirect, abort, make_response

DATA_DIR = os.environ.get("PODCUT_DATA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "podcut-data"))
JOBS_DIR = os.path.join(DATA_DIR, "jobs")
os.makedirs(JOBS_DIR, exist_ok=True)
# Jobs live in memory, so anything still on disk at startup is an orphan (a dropped
# upload, or files left by a restart). Remove it so it never eats the disk.
for _d in os.listdir(JOBS_DIR):
    shutil.rmtree(os.path.join(JOBS_DIR, _d), ignore_errors=True)
SECRET = os.environ.get("PODCUT_SECRET", "").encode() or hashlib.sha256(b"dev-insecure-secret").digest()
PWHASH = os.environ.get("PODCUT_PWHASH", "")  # empty => dev mode, password "podcut"
MAX_BYTES = int(float(os.environ.get("PODCUT_MAX_GB", "8")) * (1024 ** 3))
KEEP_SECONDS = float(os.environ.get("PODCUT_KEEP_HOURS", "12")) * 3600
MIN_FREE = int(float(os.environ.get("PODCUT_MIN_FREE_GB", "2")) * (1024 ** 3))
PRESET = os.environ.get("PODCUT_PRESET", "veryfast")
CRF = int(os.environ.get("PODCUT_CRF", "21"))
COOKIE = "podcut_session"
SESSION_TTL = 7 * 24 * 3600
MIME = {".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/mp4", ".webm": "video/webm",
        ".mkv": "video/x-matroska", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac",
        ".wav": "audio/wav", ".ogg": "audio/ogg", ".opus": "audio/ogg", ".flac": "audio/flac"}

def script_flag():
    """ffmpeg 7+ reads a filter from a file with -/filter; older builds use -filter_script. Ask the binary."""
    ff, probe = shutil.which("ffmpeg"), os.path.join(DATA_DIR, "probe.txt")
    try:
        with open(probe, "w") as f:
            f.write("anull")
        r = subprocess.run([ff, "-v", "error", "-f", "lavfi", "-i", "anullsrc=d=0.05", "-/filter:a", probe, "-f", "null", "-"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        return "-/filter" if r.returncode == 0 else "-filter_script"
    except Exception:
        return "-filter_script"
    finally:
        try:
            os.remove(probe)
        except OSError:
            pass

SCRIPT = script_flag()

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_BYTES

# ------------------------------------------------------------------ auth
def verify_password(pw):
    if not PWHASH:
        return pw == "podcut"  # dev only; production always sets PODCUT_PWHASH
    try:
        iters, salt_hex, hash_hex = PWHASH.split("$")
        dk = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt_hex), int(iters))
        return hmac.compare_digest(dk.hex(), hash_hex)
    except Exception:
        return False

def make_token():
    exp = str(int(time.time()) + SESSION_TTL)
    sig = hmac.new(SECRET, exp.encode(), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode((exp + "." + sig).encode()).decode()

def valid_token(tok):
    try:
        raw = base64.urlsafe_b64decode(tok.encode()).decode()
        exp, sig = raw.split(".")
        good = hmac.new(SECRET, exp.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(sig, good) and int(exp) > time.time()
    except Exception:
        return False

def is_authed():
    return valid_token(request.cookies.get(COOKIE, ""))

def require_auth():
    if not is_authed():
        abort(401)

FAILS = {}  # client address -> times of recent wrong passwords

def too_many(ip):
    now = time.time()
    if len(FAILS) > 5000:
        FAILS.clear()
    FAILS[ip] = [t for t in FAILS.get(ip, []) if now - t < 600]
    return len(FAILS[ip]) >= 8

# ------------------------------------------------------------------ jobs
JOBS, LOCK, WORK = {}, threading.RLock(), queue.Queue()
ENERGY = {}  # job id -> (loudness of every 20 ms frame, frame step in seconds)
PROCS = {}   # job id -> the running ffmpeg, so a render can be cancelled

def set_job(jid, **kw):
    with LOCK:
        if jid in JOBS:
            JOBS[jid].update(kw)

def get_job(jid):
    with LOCK:
        j = JOBS.get(jid)
        return dict(j) if j else None

def drop_job(jid):
    with LOCK:
        JOBS.pop(jid, None); ENERGY.pop(jid, None)
        p = PROCS.get(jid)
    if p:
        try:
            p.kill()
        except OSError:
            pass
    shutil.rmtree(os.path.join(JOBS_DIR, jid), ignore_errors=True)

def rm(path):
    try:
        os.remove(path)
    except OSError:
        pass

def free_bytes():
    return shutil.disk_usage(DATA_DIR).free

def make_room(need):
    """If a new upload would not fit: older episodes first give up their original (a finished
    render stays downloadable), then idle episodes with nothing rendered are removed."""
    with LOCK:
        items = sorted(((j.get("touched", 0), jid, dict(j)) for jid, j in JOBS.items()), key=lambda x: x[0])
    idle = [(jid, j) for _, jid, j in items if j.get("state") in ("ready", "error")]
    for jid, j in idle:
        if free_bytes() - need >= MIN_FREE:
            return
        if j.get("output_path"):
            rm(j["input_path"])
    for jid, j in idle:
        if free_bytes() - need >= MIN_FREE:
            return
        if not j.get("output_path"):
            drop_job(jid)

def rebuild(j, jid):
    """Recompute the edit from the job's settings (call with LOCK held). False if nothing would be left."""
    db, hop = ENERGY[jid]
    frames = podcut.edit_frames(db, hop, j["total"], j["fps"], j["spec"])
    if not frames:
        return False
    j["frames"] = frames; j["edited"] = podcut.out_seconds(frames, j["fps"]); j["v"] = j.get("v", 0) + 1
    return True

def do_analyze(jid):
    j = get_job(jid)
    if not j:
        return
    inp = j["input_path"]
    set_job(jid, state="analyzing")
    media = podcut.probe_media(inp)
    if not media or not media["has_audio"]:
        raise RuntimeError("This file has no readable audio track, so there is nothing to find silences in.")
    # Same clock as the render: sound is placed on its timestamps, starting at zero.
    p = subprocess.run(["nice", "-n", "15", podcut.ffmpeg_bin(), "-v", "error", "-i", inp, "-vn",
                        "-af", "aresample=async=1:first_pts=0", "-ac", "1", "-ar", str(podcut.ANALYZE_RATE),
                        "-f", "f32le", "-"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    n = len(p.stdout) // 4
    if p.returncode != 0 or n < podcut.ANALYZE_RATE // 2:
        raise RuntimeError("Could not read the audio in this file.")
    a = array.array("f"); a.frombytes(p.stdout[:n * 4]); del p
    db, hop = podcut.frame_energies(a, podcut.ANALYZE_RATE)
    with LOCK:
        j = JOBS.get(jid)
        if not j:
            return
        ENERGY[jid] = (array.array("f", db), hop)
        j.update(media=media, fps=tuple(media["fps"]) if media["has_video"] else (100, 1),
                 total=n / podcut.ANALYZE_RATE, v=0)
        if not media["has_video"]:
            j["spec"]["angles"] = False
        if not rebuild(j, jid):
            raise RuntimeError("No speech found above the silence threshold — try a lower threshold.")
        j.update(state="ready", spec0=json.loads(json.dumps(j["spec"])), touched=time.time())

def do_render(jid):
    with LOCK:
        j = JOBS.get(jid)
        if not j or j.get("state") != "rendering":
            return
        frames, fps, media, v = [list(x) for x in j["frames"]], j["fps"], j["media"], j["v"]
        spec, inp, total = json.loads(json.dumps(j["spec"])), j["input_path"], j["total"]
        j.update(progress=0, eta=None, cancel=False, note="")
    jd = os.path.join(JOBS_DIR, jid)
    ext = ".mp4" if media["has_video"] else ".m4a"
    tmp, final = os.path.join(jd, "render" + ext), os.path.join(jd, "edited" + ext)
    vf, af, cmds, dur = podcut.build_filters(frames, fps, media, spec, os.path.join(jd, "cmds.txt"))
    if free_bytes() - os.path.getsize(inp) * dur / max(1.0, total) * 1.2 < MIN_FREE:
        set_job(jid, state="ready", note="Not enough free disk space on the server to render. Remove old episodes first.")
        return
    for name, text in (("vf.txt", vf), ("af.txt", af), ("cmds.txt", cmds)):
        with open(os.path.join(jd, name), "w") as f:
            f.write(text or "")
    cmd = ["nice", "-n", "15", podcut.ffmpeg_bin(), "-y", "-i", inp]
    cmd += [SCRIPT + ":v", os.path.join(jd, "vf.txt")] if vf else ["-vn"]
    cmd += [SCRIPT + ":a", os.path.join(jd, "af.txt")]
    if vf:
        cmd += ["-c:v", "libx264", "-preset", PRESET, "-crf", str(CRF), "-pix_fmt", "yuv420p"]
    cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", str(podcut.OUT_RATE), "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats", tmp]
    with open(os.path.join(jd, "ffmpeg.log"), "wb") as logf:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=logf, text=True)
        with LOCK:
            PROCS[jid] = p
        cur = 0.0
        for line in p.stdout:
            line = line.strip()
            if line.startswith(("out_time_us=", "out_time_ms=")):
                try:
                    cur = int(line.split("=", 1)[1]) / 1e6
                except ValueError:
                    continue
                set_job(jid, progress=min(99, int(cur / max(0.1, dur) * 100)))
            elif line.startswith("speed="):
                try:
                    speed = float(line.split("=", 1)[1].rstrip("x"))
                    set_job(jid, eta=int((dur - cur) / speed) if speed > 0 else None)
                except ValueError:
                    pass
        p.stdout.close()
        rc = p.wait()
    with LOCK:
        PROCS.pop(jid, None)
        j = JOBS.get(jid)
        cancelled = bool(j and j.get("cancel"))
    if not j:
        return
    if cancelled or rc != 0 or not os.path.isfile(tmp):
        rm(tmp)
        set_job(jid, state="ready", progress=0, eta=None,
                note="" if cancelled else "Rendering failed. Change the edit or try again.")
        return
    os.replace(tmp, final)
    set_job(jid, state="ready", progress=100, eta=None, output_path=final,
            output_size=os.path.getsize(final), rendered_v=v, touched=time.time())

def worker():
    while True:
        kind, jid = WORK.get()
        try:
            (do_analyze if kind == "analyze" else do_render)(jid)
        except BaseException as e:  # podcut calls sys.exit when ffmpeg is missing; never let that kill the worker
            j = get_job(jid)
            if not j:
                continue
            msg = (str(e).split("\n")[0].replace(j.get("input_path", "\0"), j.get("name", "the file")).rstrip(": ")[:300]
                   or "Could not process this file.")
            if kind == "render":
                with LOCK:
                    PROCS.pop(jid, None)
                set_job(jid, state="ready", note="Rendering failed: " + msg)
            else:
                set_job(jid, state="error", error=msg, touched=time.time())
                rm(j["input_path"])

def reaper():
    while True:
        now = time.time()
        with LOCK:
            items = [(jid, j.get("state"), j.get("touched", now)) for jid, j in JOBS.items()]
        for jid, state, touched in items:
            if state in ("ready", "error") and now - touched > KEEP_SECONDS:
                drop_job(jid)
        time.sleep(600)

threading.Thread(target=worker, daemon=True).start()
threading.Thread(target=reaper, daemon=True).start()

# ------------------------------------------------------------------ helpers
def fmt_dur(sec):
    sec = max(0, sec or 0); h = int(sec // 3600); m = int((sec % 3600) // 60); s = int(sec % 60)
    return ("%d:%02d:%02d" % (h, m, s)) if h else ("%d:%02d" % (m, s))

def clampf(v, lo, hi, d):
    try:
        return min(hi, max(lo, float(v)))
    except (TypeError, ValueError):
        return d

def need_job(jid):
    require_auth()
    if not re.match(r"^[0-9a-f]{32}$", jid):
        abort(404)
    j = get_job(jid)
    if not j:
        abort(404)
    return j

def start_render(jid):
    with LOCK:
        j = JOBS.get(jid)
        if not j or j.get("state") != "ready" or not j.get("frames") or not os.path.isfile(j["input_path"]):
            return False
        j.update(state="rendering", progress=0, eta=None, note="", touched=time.time())
    WORK.put(("render", jid))
    return True

# ------------------------------------------------------------------ routes
@app.after_request
def harden(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    if resp.mimetype in ("text/html", "application/json"):
        resp.headers["Cache-Control"] = "no-store"  # always the current page and the current status
    return resp

@app.route("/healthz")
def healthz():
    return "ok"

@app.route("/login", methods=["POST"])
def login():
    ip = (request.headers.get("X-Forwarded-For", "") or request.remote_addr or "?").split(",")[-1].strip()
    if too_many(ip):
        return render_login("Too many wrong passwords. Wait ten minutes and try again."), 429
    if verify_password(request.form.get("password", "")):
        resp = make_response(redirect("/"))
        resp.set_cookie(COOKIE, make_token(), max_age=SESSION_TTL, httponly=True, samesite="Lax",
                        secure=request.is_secure or request.headers.get("X-Forwarded-Proto") == "https")
        return resp
    FAILS[ip].append(time.time())
    return render_login("Wrong password."), 401

@app.route("/logout", methods=["POST"])
def logout():
    resp = make_response(redirect("/"))
    resp.delete_cookie(COOKIE)
    return resp

@app.route("/")
def index():
    if not is_authed():
        return render_login("")
    return render_app()

@app.route("/api/space")
def api_space():
    require_auth()
    need = int(clampf(request.args.get("bytes"), 0, 1e15, 0))
    if need > MAX_BYTES:
        return {"ok": False, "error": "File is larger than the %d GB limit." % round(MAX_BYTES / (1024 ** 3))}
    make_room(need)
    if free_bytes() - need < MIN_FREE:
        return {"ok": False, "error": "Not enough free disk space on the server for this file (%.1f GB free)." % (free_bytes() / 1e9)}
    return {"ok": True}

@app.route("/api/job", methods=["POST"])
def api_job():
    require_auth()
    # The file is sent as the raw request body (params in the query string), so a
    # multi-GB upload streams straight to disk — no multipart spooling or extra copy.
    name = os.path.basename(request.args.get("name", "episode"))[:120] or "episode"
    ext = os.path.splitext(name)[1].lower()
    if not re.match(r"^\.[a-z0-9]{1,5}$", ext):
        ext = ".mp4"
    make_room(request.content_length or 0)
    if free_bytes() - (request.content_length or 0) < MIN_FREE:
        return {"error": "Not enough free disk space on the server for this file."}, 507
    jid = uuid.uuid4().hex
    jd = os.path.join(JOBS_DIR, jid); os.makedirs(jd, exist_ok=True)
    inp = os.path.join(jd, "input" + ext)
    total = 0
    try:
        with open(inp, "wb") as out:
            while True:
                chunk = request.stream.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_BYTES:
                    raise ValueError("too large")
                if total % (64 * 1024 * 1024) < len(chunk) and free_bytes() < MIN_FREE // 2:
                    raise OSError("disk nearly full")
                out.write(chunk)
    except ValueError:
        shutil.rmtree(jd, ignore_errors=True)
        return {"error": "File is larger than the %d GB limit." % round(MAX_BYTES / (1024 ** 3))}, 413
    except Exception:  # connection dropped mid-upload, or the disk filled: leave nothing behind
        shutil.rmtree(jd, ignore_errors=True)
        return {"error": "Upload was interrupted."}, 400
    if total == 0:
        shutil.rmtree(jd, ignore_errors=True)
        return {"error": "No file received."}, 400
    a = request.args
    spec = podcut.default_spec(
        threshold=clampf(a.get("threshold"), -60, -20, -40), min_silence=clampf(a.get("min_silence"), 0.1, 5, 0.5),
        pad=clampf(a.get("pad"), 0, 1, 0.12), min_keep=clampf(a.get("min_keep"), 0, 2, 0.2),
        clean=a.get("clean", "1") not in ("0", "false", "no", "off"),
        angles=a.get("angles", "0") in ("1", "true", "yes", "on"),
        layout=a.get("layout") if a.get("layout") in podcut.FOCUS else "duo")
    now = time.time()
    with LOCK:
        JOBS[jid] = {"state": "queued", "progress": 0, "name": name, "created": now, "touched": now,
                     "input_path": inp, "spec": spec, "history": [], "chat": [], "v": 0, "note": "", "error": None}
    WORK.put(("analyze", jid))
    return {"id": jid}

@app.route("/api/job/<jid>")
def api_status(jid):
    j = need_job(jid)
    out = {k: j.get(k) for k in ("state", "progress", "name", "error", "note", "eta")}
    out["v"] = j.get("v", 0)
    out["has_video"] = bool(j.get("media", {}).get("has_video"))
    if j.get("frames"):
        tot, ed = j["total"], j["edited"]
        out.update(original_h=fmt_dur(tot), edited_h=fmt_dur(ed), cuts=max(0, len(j["frames"]) - 1),
                   saved_pct=round((tot - ed) / tot * 100) if tot else 0, edl="/api/job/%s/edl" % jid)
        if os.path.isfile(j["input_path"]):
            out["source"] = "/api/job/%s/source" % jid
    if j.get("output_path"):
        out.update(download="/api/job/%s/file" % jid, preview="/api/job/%s/preview" % jid,
                   size_mb=round(j.get("output_size", 0) / 1e6, 1), stale=j.get("rendered_v") != j.get("v"))
    if request.args.get("chat"):
        out["chat"] = j.get("chat", [])
    return out

@app.route("/api/job/<jid>/edl")
def api_edl(jid):
    j = need_job(jid)
    if not j.get("frames"):
        abort(404)
    r, shots = j["fps"][0] / j["fps"][1], []
    if j["spec"]["angles"] and j["media"]["has_video"]:
        shots = [[round(at / r, 3)] + [round(x, 4) for x in (rect or (1, 1, 0, 0))]
                 for at, rect in podcut.plan_shots(j["frames"], j["fps"], j["spec"])]
    return {"v": j["v"], "total": round(j["total"], 3), "shots": shots,
            "keep": [[round(a / r, 4), round(b / r, 4)] for a, b in j["frames"]]}

@app.route("/api/job/<jid>/command", methods=["POST"])
def api_command(jid):
    need_job(jid)
    text = str((request.get_json(silent=True) or {}).get("text", ""))[:400].strip()
    if not text:
        return {"error": "Type what you want to change."}, 400
    render = changed = False
    with LOCK:
        j = JOBS.get(jid)
        if not j:
            abort(404)
        if not j.get("frames"):
            return {"reply": "Still finding the edit — one moment.", "changed": False}
        if not os.path.isfile(j["input_path"]):
            return {"reply": "The original upload for this episode was removed to free space, so it can no longer be changed.", "changed": False}
        before = j["edited"]
        spec, replies, action = podcut.apply_command(text, j["spec"], j["frames"], j["fps"], j["total"],
                                                     j["media"]["has_video"])
        old = j["spec"]
        if action == "undo":
            if j["history"]:
                j["spec"] = j["history"].pop(); rebuild(j, jid); changed = True; replies.append("Undone.")
            else:
                replies.append("Nothing to undo.")
        elif action == "reset":
            if old != j["spec0"]:
                j["history"].append(old); j["spec"] = json.loads(json.dumps(j["spec0"])); rebuild(j, jid); changed = True
            replies.append("Back to the first edit.")
        elif action == "render":
            render = True
        elif spec != old:
            j["spec"] = spec
            if rebuild(j, jid):
                j["history"].append(old); del j["history"][:-40]; changed = True
            else:
                j["spec"] = old
                replies = ["That would remove everything, so nothing was changed."]
        if changed and fmt_dur(j["edited"]) != fmt_dur(before):
            replies.append("The edit is now %s (was %s)." % (fmt_dur(j["edited"]), fmt_dur(before)))
    if render:
        replies.append("Rendering the final file now." if start_render(jid) else "A render is already running.")
    reply = " ".join(replies) or "Nothing changed."
    with LOCK:
        j = JOBS.get(jid)
        if j:
            j["chat"] += [{"who": "you", "text": text}, {"who": "podcut", "text": reply}]; del j["chat"][:-80]
            j["touched"] = time.time()
    return {"reply": reply, "changed": changed}

@app.route("/api/job/<jid>/render", methods=["POST"])
def api_render(jid):
    need_job(jid)
    return {"ok": start_render(jid)}

@app.route("/api/job/<jid>/cancel", methods=["POST"])
def api_cancel(jid):
    need_job(jid)
    with LOCK:
        j, p = JOBS.get(jid), PROCS.get(jid)
        if j and j.get("state") == "rendering":
            j["cancel"] = True
    if p:
        try:
            p.terminate()
        except OSError:
            pass
    return {"ok": True}

@app.route("/api/job/<jid>/delete", methods=["POST"])
def api_delete(jid):
    need_job(jid)
    drop_job(jid)
    return {"ok": True}

@app.route("/api/job/<jid>/source")
def api_source(jid):
    j = need_job(jid)
    if not os.path.isfile(j["input_path"]):
        abort(404)
    set_job(jid, touched=time.time())
    # inline + range support so the page can play and seek the original while showing the edit
    return send_file(j["input_path"], conditional=True,
                     mimetype=MIME.get(os.path.splitext(j["input_path"])[1], "application/octet-stream"))

def _output(jid):
    j = need_job(jid)
    if not j.get("output_path") or not os.path.isfile(j["output_path"]):
        abort(404)
    set_job(jid, touched=time.time())
    return j

@app.route("/api/job/<jid>/file")
def api_file(jid):
    j = _output(jid)
    base = re.sub(r"[^A-Za-z0-9_.-]+", "_", os.path.splitext(j.get("name", "episode"))[0])[:60] or "episode"
    return send_file(j["output_path"], as_attachment=True,
                     download_name=base + "_podcut" + os.path.splitext(j["output_path"])[1])

@app.route("/api/job/<jid>/preview")
def api_preview(jid):
    j = _output(jid)
    return send_file(j["output_path"], conditional=True,
                     mimetype="video/mp4" if j["output_path"].endswith(".mp4") else "audio/mp4")

# ------------------------------------------------------------------ pages
def page(title, body):
    return ("""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>%s</title><style>
:root{--bg:#131210;--surface:#1c1b18;--surface2:#26241f;--border:#332f28;--fg:#f2f0e9;--muted:#a39f93;--accent:#ff8a3d;--accent-ink:#241100;--keep:#34c28c;color-scheme:dark}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
[hidden]{display:none!important}
.wrap{max-width:680px;margin:0 auto;padding:28px max(16px,env(safe-area-inset-left)) 60px}
h1{font-size:1.6rem;margin:0 0 2px}.logo{width:40px;height:40px;border-radius:10px;background:var(--accent);color:var(--accent-ink);display:grid;place-items:center;font-weight:800;font-size:1.3rem}
.head{display:flex;align-items:center;gap:12px;margin-bottom:6px}.sub{color:var(--muted);margin:0 0 22px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:20px;margin-bottom:16px}
label{display:block;font-size:.82rem;color:var(--muted);font-weight:600;margin:14px 0 5px}
input[type=file],input[type=password],input[type=text],select{width:100%%;background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:11px;color:var(--fg);font:inherit}
input[type=range]{width:100%%;accent-color:var(--accent)}
.rangeval{float:right;color:var(--fg);font-variant-numeric:tabular-nums}
.btn{appearance:none;border:0;border-radius:10px;background:var(--accent);color:var(--accent-ink);font:600 .95rem system-ui;padding:12px 18px;cursor:pointer;width:100%%;margin-top:18px}
.btn.sec{background:var(--surface2);color:var(--fg);border:1px solid var(--border);width:auto;margin:0}
.btn:disabled{opacity:.5;cursor:default}
.muted{color:var(--muted);font-size:.85rem}.err{color:#ff6d90;font-size:.9rem;margin-top:10px}
.bar{height:12px;background:var(--surface2);border-radius:99px;overflow:hidden;margin:12px 0}.bar>i{display:block;height:100%%;width:0;background:var(--accent);transition:width .4s}
.tiles{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;margin:14px 0}
.tile{background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:10px}.tile b{font-size:1.1rem;font-variant-numeric:tabular-nums}.tile span{display:block;font-size:.68rem;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.dl{display:inline-block;background:var(--keep);color:#06281c;font-weight:700;text-decoration:none;padding:12px 20px;border-radius:10px}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px}
.frame{overflow:hidden;border-radius:10px;background:#000;margin-top:14px}.frame video{display:block;width:100%%;transform-origin:0 0}
.frame.audio{height:0}
#strip{display:block;width:100%%;height:14px;border-radius:4px;margin-top:8px;cursor:pointer}
.ctl{display:flex;gap:10px;align-items:center;margin-top:8px}.ctl .muted{white-space:nowrap;font-variant-numeric:tabular-nums}
.chat{display:flex;flex-direction:column;gap:6px;max-height:230px;overflow:auto;margin-top:16px}
.msg{padding:8px 11px;border-radius:10px;font-size:.9rem;max-width:90%%;white-space:pre-wrap;overflow-wrap:anywhere}
.msg.you{align-self:flex-end;background:var(--accent);color:var(--accent-ink)}.msg.podcut{align-self:flex-start;background:var(--surface2);border:1px solid var(--border)}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
.chip{appearance:none;border:1px solid var(--border);background:var(--surface2);color:var(--fg);border-radius:99px;padding:6px 12px;font:inherit;font-size:.82rem;cursor:pointer}.chip:disabled{opacity:.45}
.say{display:flex;gap:8px;margin-top:8px}.say input{flex:1;min-width:0}
.row{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-top:12px}
</style></head><body><div class=wrap>%s</div></body></html>""") % (title, body)

def render_login(msg):
    return page("PodCut Studio", """
<div class=head><div class=logo>P</div><div><h1>PodCut Studio</h1></div></div>
<p class=sub>Sign in to edit your episodes.</p>
<div class=card><form method=post action=/login>
<label for=pw>Password</label><input id=pw name=password type=password autofocus autocomplete=current-password>
<button class=btn type=submit>Sign in</button>
%s</form></div>""" % ("<p class=err>" + html.escape(msg) + "</p>" if msg else ""))

def render_app():
    return page("PodCut Studio", """
<div class=top><div class=head><div class=logo>P</div><div><h1>PodCut Studio</h1></div></div>
<form method=post action=/logout><button class="btn sec" type=submit>Sign out</button></form></div>
<p class=sub>Upload an episode, watch the edit, change it by typing, then render the final file.</p>
<div class=card id=form>
  <label for=file>Episode (audio or video)</label>
  <input id=file type=file accept="audio/*,video/*">
  <label>Silence threshold <span class=rangeval id=thv>-40 dB</span></label>
  <input id=th type=range min=-60 max=-20 step=1 value=-40>
  <label>Min silence to cut <span class=rangeval id=msv>0.50 s</span></label>
  <input id=ms type=range min=0.1 max=3 step=0.05 value=0.5>
  <label>Keep padding <span class=rangeval id=pdv>0.12 s</span></label>
  <input id=pd type=range min=0 max=0.5 step=0.01 value=0.12>
  <label style="display:flex;align-items:center;gap:8px;margin-top:16px;color:var(--fg)"><input id=clean type=checkbox checked style="width:auto;accent-color:var(--accent)"> Clean up audio (reduce noise, even out volume)</label>
  <label style="display:flex;align-items:center;gap:8px;margin-top:12px;color:var(--fg)"><input id=angles type=checkbox style="width:auto;accent-color:var(--accent)"> Multi-angle: make one camera look multi-camera (auto zoom-ins)</label>
  <div id=layoutrow hidden><label for=layout>Who's on camera</label><select id=layout><option value=duo>Two people, side by side</option><option value=single>One person</option><option value=trio>Three people</option></select></div>
  <button class=btn id=go>Upload &amp; edit</button>
  <p class=muted style=margin-top:12px>Big files take a while to upload. Keep this tab open until the upload finishes.</p>
  <p class=err id=err hidden></p>
</div>
<div class=card id=work hidden>
  <div class=top><b id=pname>Working…</b><span class=muted id=pstate></span></div>
  <div class=bar id=barwrap><i id=pbar></i></div>
  <div class=tiles id=ptiles hidden>
    <div class=tile><span>Original</span><b id=torig>–</b></div>
    <div class=tile><span>Edited</span><b id=tedit>–</b></div>
    <div class=tile><span>Saved</span><b id=tsave>–</b></div>
  </div>
  <p class=err id=perr hidden></p>
  <div id=stage hidden>
    <div class=frame id=frame><video id=pv playsinline preload=metadata></video></div>
    <div id=live>
      <canvas id=strip height=14></canvas>
      <div class=ctl><button class="btn sec" id=play>Play</button><input id=seek type=range min=0 max=1 step=0.01 value=0 aria-label="Position in the edit"><span class=muted id=clock>0:00 / 0:00</span></div>
      <p class=muted id=pvnote>Live preview of the edit. Cuts can hitch slightly here; the rendered file is seamless and has the cleaned-up sound.</p>
    </div>
    <div class=chat id=chat></div>
    <div class=chips>
      <button class=chip data-c=tighter>Tighter</button><button class=chip data-c=looser>Looser</button>
      <button class=chip id=markin>Cut from here</button><button class=chip id=markout disabled>…to here</button>
      <button class=chip data-c=undo>Undo</button><button class=chip data-c=help>Help</button>
    </div>
    <div class=say><input id=cmd type=text maxlength=400 autocomplete=off placeholder="Tell PodCut what to change…" aria-label="Edit instruction"><button class="btn sec" id=send>Send</button></div>
    <button class=btn id=render>Render final file</button>
    <p class=muted id=stale hidden>You changed the edit after this render. Render again to include the latest changes.</p>
    <div class=row>
      <a class=dl id=dl hidden>Download</a>
      <button class="btn sec" id=viewfinal hidden>Watch final</button>
      <button class="btn sec" id=cancel hidden>Cancel render</button>
    </div>
  </div>
  <div class=row><button class="btn sec" id=again>New episode</button></div>
</div>
<script>
var $=function(i){return document.getElementById(i)},v=$('pv'),ID=null,J=null,E=null,mode='live',markA=null,drag=false,timer=null;
function rng(id,out,f){var e=$(id);function u(){$(out).textContent=f(+e.value)}e.addEventListener('input',u);u()}
rng('th','thv',function(x){return x+' dB'});rng('ms','msv',function(x){return x.toFixed(2)+' s'});rng('pd','pdv',function(x){return x.toFixed(2)+' s'});
$('angles').addEventListener('change',function(){$('layoutrow').hidden=!$('angles').checked;});
function fmt(t){t=Math.max(0,t||0);var h=Math.floor(t/3600),m=Math.floor(t%3600/60),s=Math.floor(t%60);return (h?h+':'+(m<10?'0':'')+m:m)+':'+(s<10?'0':'')+s;}
function api(p,o){return fetch(p,o).then(function(r){if(r.status===401){location.reload();}return r.json().catch(function(){return {};}).then(function(j){j._s=r.status;return j;});});}
function post(p,b){return api(p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b||{})});}
function fail(m){$('perr').hidden=!m;$('perr').textContent=m||'';}
$('go').addEventListener('click',function(){
  var f=$('file').files[0];
  if(!f){$('err').hidden=false;$('err').textContent='Choose a file first.';return;}
  $('err').hidden=true;$('go').disabled=true;
  api('/api/space?bytes='+f.size).then(function(s){
    if(!s.ok){$('go').disabled=false;$('err').hidden=false;$('err').textContent=s.error||'The server cannot take this file right now.';return;}
    var qs='?name='+encodeURIComponent(f.name)+'&threshold='+$('th').value+'&min_silence='+$('ms').value+'&pad='+$('pd').value+'&clean='+($('clean').checked?'1':'0')+'&angles='+($('angles').checked?'1':'0')+'&layout='+$('layout').value;
    $('form').hidden=true;$('work').hidden=false;$('pname').textContent=f.name;$('pstate').textContent='uploading…';
    var x=new XMLHttpRequest();x.open('POST','/api/job'+qs);x.setRequestHeader('Content-Type','application/octet-stream');
    x.upload.onprogress=function(e){if(e.lengthComputable){var p=Math.round(e.loaded/e.total*100);$('pbar').style.width=p+'%';$('pstate').textContent='uploading '+p+'%';}};
    x.onload=function(){var j={};try{j=JSON.parse(x.responseText);}catch(e){}
      if(x.status!==200||!j.id){fail(j.error||('Upload failed ('+x.status+').'));$('pstate').textContent='';return;}
      openJob(j.id);};
    x.onerror=function(){fail('Upload failed — check your connection.');$('pstate').textContent='';};
    x.send(f);
  }).catch(function(){$('go').disabled=false;});
});
function openJob(id){ID=id;try{history.replaceState(null,'','#'+id);}catch(e){}$('form').hidden=true;$('work').hidden=false;poll(true);}
function poll(first){clearTimeout(timer);api('/api/job/'+ID+(first===true?'?chat=1':'')).then(function(j){
  if(j._s===404){try{history.replaceState(null,'','#');}catch(e){}location.reload();return;}
  if(j._s!==200){timer=setTimeout(poll,3000);return;}
  J=j;if(j.chat){$('chat').textContent='';j.chat.forEach(function(m){add(m.who,m.text);});}
  paint();
  if(j.state==='queued'||j.state==='analyzing'||j.state==='rendering')timer=setTimeout(poll,1500);
 }).catch(function(){timer=setTimeout(poll,3000);});}
function paint(){var j=J,busy=(j.state==='queued'||j.state==='analyzing'||j.state==='rendering');
  $('pname').textContent=j.name||'Episode';
  $('pstate').textContent={queued:'queued…',analyzing:'finding the edit…',rendering:'rendering '+(j.progress||0)+'%'+(j.eta?' · about '+fmt(j.eta)+' left':''),ready:(j.download?(j.stale?'edit changed since the render':'rendered'):'ready to review'),error:''}[j.state]||j.state;
  $('barwrap').hidden=!busy;$('pbar').style.width=(j.state==='rendering'?(j.progress||0):100)+'%';
  fail(j.state==='error'?(j.error||'Something went wrong.'):(j.note||''));
  if(j.original_h){$('ptiles').hidden=false;$('torig').textContent=j.original_h;$('tedit').textContent=j.edited_h;$('tsave').textContent=j.saved_pct+'%';}
  if(j.edl){$('stage').hidden=false;$('frame').className='frame'+(j.has_video?'':' audio');if(!E||E.v!==j.v)loadEDL();}
  $('render').hidden=(j.state==='rendering')||!j.source;$('render').textContent=j.download?'Render again':'Render final file';
  $('cancel').hidden=j.state!=='rendering';
  $('dl').hidden=!j.download;if(j.download){$('dl').href=j.download;$('dl').textContent='Download ('+j.size_mb+' MB)';}
  $('viewfinal').hidden=!j.download;$('stale').hidden=!(j.download&&j.stale);
  if(!j.source&&j.edl){$('live').hidden=true;$('pvnote').hidden=true;}
}
function loadEDL(){api(J.edl).then(function(d){if(!d.keep)return;var acc=0,x=E?edited():0;d.pre=[];
  for(var i=0;i<d.keep.length;i++){d.pre.push(acc);acc+=d.keep[i][1]-d.keep[i][0];}
  d.edited=acc;E=d;$('seek').max=acc.toFixed(2);
  if(mode==='final')toLive();
  else if(J.source&&v.getAttribute('data-k')!=='src'){v.setAttribute('data-k','src');v.src=J.source;}
  else if(v.readyState>0)v.currentTime=toS(Math.min(x,Math.max(0,acc-0.05)));
  strip();ui();});}
function seg(t){var a=0,b=E.keep.length-1,r=-1;while(a<=b){var m=(a+b)>>1;if(E.keep[m][0]<=t){r=m;a=m+1;}else b=m-1;}return r;}
function toE(t){var i=seg(t);if(i<0)return 0;var k=E.keep[i];return E.pre[i]+Math.min(t,k[1])-k[0];}
function toS(x){var a=0,b=E.pre.length-1,r=0;while(a<=b){var m=(a+b)>>1;if(E.pre[m]<=x){r=m;a=m+1;}else b=m-1;}var k=E.keep[r];return Math.max(k[0],Math.min(k[1]-0.02,k[0]+(x-E.pre[r])));}
function edited(){return (E&&mode==='live')?toE(v.currentTime):(v.currentTime||0);}
function tick(){
  if(mode==='live'&&E&&E.keep.length){var t=v.currentTime,i=seg(t);
    if(i<0)v.currentTime=E.keep[0][0];
    else if(t>=E.keep[i][1]-0.012){if(i+1<E.keep.length)v.currentTime=E.keep[i+1][0];else v.pause();}}
  ui();if(!v.paused)requestAnimationFrame(tick);}
function ui(){if(!E)return;var x=edited();if(!drag)$('seek').value=x;
  $('clock').textContent=fmt(x)+' / '+fmt(E.edited);$('play').textContent=v.paused?'Play':'Pause';
  var r=null,s=E.shots;
  if(mode==='live'&&s&&s.length){var a=0,b=s.length-1,k=0;while(a<=b){var m=(a+b)>>1;if(s[m][0]<=x){k=m;a=m+1;}else b=m-1;}r=s[k];}
  v.style.transform=(r&&r[1]<1)?'scale('+(1/r[1])+') translate('+(-r[3]*100)+'%,'+(-r[4]*100)+'%)':'';}
function strip(){var c=$('strip'),w=c.clientWidth||600;c.width=w;var g=c.getContext('2d');g.fillStyle='#3a362e';g.fillRect(0,0,w,14);g.fillStyle='#34c28c';
  for(var i=0;i<E.keep.length;i++){var a=E.keep[i][0]/E.total*w,b=E.keep[i][1]/E.total*w;g.fillRect(a,0,Math.max(0.5,b-a),14);}}
v.addEventListener('play',function(){if(mode==='live'&&E&&edited()>=E.edited-0.1)v.currentTime=E.keep[0][0];requestAnimationFrame(tick);});
['pause','seeked','timeupdate'].forEach(function(e){v.addEventListener(e,ui);});
v.addEventListener('loadedmetadata',function(){if(mode==='live'&&E&&seg(v.currentTime)<0)v.currentTime=E.keep[0][0];
  if(mode==='live'&&J&&J.has_video&&!v.videoWidth)noPreview();ui();});
v.addEventListener('error',function(){if(mode==='live'&&v.getAttribute('data-k')==='src')noPreview();});
function noPreview(){$('live').hidden=true;$('frame').className='frame audio';fail('This file type cannot be played in the browser, so there is no live preview. Your typed changes still apply — render to see the result.');}
$('play').addEventListener('click',function(){if(v.paused)v.play();else v.pause();});
$('seek').addEventListener('input',function(){drag=true;if(E&&v.readyState>0)v.currentTime=toS(+this.value);$('clock').textContent=fmt(+this.value)+' / '+fmt(E?E.edited:0);});
$('seek').addEventListener('change',function(){drag=false;});
$('strip').addEventListener('click',function(e){if(!E||v.readyState<1)return;var r=this.getBoundingClientRect(),t=(e.clientX-r.left)/r.width*E.total,i=seg(t);
  v.currentTime=i<0?E.keep[0][0]:(t<E.keep[i][1]?t:(i+1<E.keep.length?E.keep[i+1][0]:E.keep[i][1]-0.05));});
function add(who,t){var d=document.createElement('div');d.className='msg '+(who==='you'?'you':'podcut');d.textContent=t;$('chat').appendChild(d);$('chat').scrollTop=1e9;}
function say(t){t=(t||'').trim();if(!t||!ID)return;$('cmd').value='';add('you',t);
  post('/api/job/'+ID+'/command',{text:t}).then(function(r){add('podcut',r.reply||r.error||'Something went wrong.');poll();});}
$('send').addEventListener('click',function(){say($('cmd').value);});
$('cmd').addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();say(this.value);}});
Array.prototype.forEach.call(document.querySelectorAll('.chip[data-c]'),function(b){b.addEventListener('click',function(){say(b.getAttribute('data-c'));});});
$('markin').addEventListener('click',function(){markA=edited();$('markout').disabled=false;this.textContent='Cut from '+fmt(markA);});
$('markout').addEventListener('click',function(){var b=edited();if(markA===null)return;var a=Math.min(markA,b),c=Math.max(markA,b);
  markA=null;this.disabled=true;$('markin').textContent='Cut from here';if(c-a>=0.1)say('cut '+a.toFixed(1)+' to '+c.toFixed(1));});
$('render').addEventListener('click',function(){post('/api/job/'+ID+'/render').then(function(){poll();});});
$('cancel').addEventListener('click',function(){post('/api/job/'+ID+'/cancel').then(function(){poll();});});
function toLive(){mode='live';v.pause();v.controls=false;v.setAttribute('data-k','src');v.src=J.source||'';$('live').hidden=!J.source;$('viewfinal').textContent='Watch final';}
$('viewfinal').addEventListener('click',function(){
  if(mode==='final'){toLive();return;}
  mode='final';v.pause();v.style.transform='';v.setAttribute('data-k','final');v.src=J.preview;v.controls=true;$('live').hidden=true;$('frame').className='frame';this.textContent='Back to live preview';});
$('again').addEventListener('click',function(){
  if(ID&&!confirm('This removes this episode and its files from the server. Download the final file first if you need it.'))return;
  var done=function(){try{history.replaceState(null,'','#');}catch(e){}location.reload();};
  if(ID)post('/api/job/'+ID+'/delete').then(done,done);else done();});
window.addEventListener('resize',function(){if(E)strip();});
if(/^#[0-9a-f]{32}$/.test(location.hash))openJob(location.hash.slice(1));
</script>""")

if __name__ == "__main__":
    port = int(os.environ.get("PODCUT_PORT", "8820"))
    app.run(host="127.0.0.1", port=port, threaded=True)
