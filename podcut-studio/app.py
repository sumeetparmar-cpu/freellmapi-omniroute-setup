#!/usr/bin/env python3
"""PodCut Studio — a small authenticated web service that edits a full podcast
server-side, so you can run it from any device. Deliberately conservative on a
shared box: one job at a time, nice'd ffmpeg, upload cap, auto-cleanup. It reuses
the tested podcut.py edit logic. Configuration comes from the environment:

  PODCUT_SECRET      cookie-signing secret (required in production)
  PODCUT_PWHASH      login password hash as "iterations$salthex$hashhex" (required)
  PODCUT_DATA_DIR    where jobs/outputs live (default ./podcut-data)
  PODCUT_PORT        loopback port to bind (default 8820)
  PODCUT_MAX_GB      max upload size in GB (default 8)
  PODCUT_KEEP_HOURS  hours to keep a finished output before deleting (default 12)
  PODCUT_PRESET      x264 preset (default veryfast — light on a shared CPU)
  PODCUT_CRF         quality 0-51 (default 21)
"""
import base64, hashlib, hmac, html, json, os, queue, re, shutil, subprocess, sys, threading, time, uuid
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import podcut  # the tested edit logic

from flask import Flask, request, Response, send_file, redirect, abort, make_response

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
PRESET = os.environ.get("PODCUT_PRESET", "veryfast")
CRF = int(os.environ.get("PODCUT_CRF", "21"))
COOKIE = "podcut_session"
SESSION_TTL = 7 * 24 * 3600

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

# ------------------------------------------------------------------ jobs
JOBS = {}
JOB_LOCK = threading.Lock()
WORK = queue.Queue()

def set_job(jid, **kw):
    with JOB_LOCK:
        JOBS.setdefault(jid, {}).update(kw)

def get_job(jid):
    with JOB_LOCK:
        j = JOBS.get(jid)
        return dict(j) if j else None

def render_with_progress(inp, outp, keep, kept_dur, jid, clean=False):
    expr = podcut.keep_expr(keep)
    jd = os.path.dirname(outp)
    vf = os.path.join(jd, "vf.txt"); af = os.path.join(jd, "af.txt")
    open(vf, "w").write("select='%s',setpts=N/FRAME_RATE/TB" % expr)
    af_chain = "aselect='%s',asetpts=N/SR/TB" % expr
    if clean:
        af_chain += "," + podcut.AUDIO_CLEAN
    open(af, "w").write(af_chain)
    args = SimpleNamespace(encoder="libx264", preset=PRESET, crf=CRF, abitrate="192k")
    cmd = ["nice", "-n", "15", podcut.ffmpeg_bin(), "-y", "-i", inp,
           "-filter_script:v", vf, "-filter_script:a", af] + podcut.encode_opts(args) + \
          ["-progress", "pipe:1", "-nostats", outp]
    logf = open(os.path.join(jd, "ffmpeg.log"), "wb")
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=logf, text=True)
    denom = max(0.1, kept_dur)
    for line in p.stdout:
        line = line.strip()
        if line.startswith("out_time_us="):
            try:
                cur = int(line.split("=", 1)[1]) / 1e6
                set_job(jid, progress=min(99, round(cur / denom * 100)))
            except ValueError:
                pass
        elif line == "progress=end":
            set_job(jid, progress=100)
    p.wait(); logf.close()
    return p.returncode

def assign_angles_timed(keep, n_angles, min_shot=3.0, wide_every=3):
    # Hold each angle for ~min_shot of kept content, then rotate (wide every Nth switch).
    angles, cur, acc, switches, punch = [], 0, 0.0, 0, 1
    for (s, e) in keep:
        angles.append(cur)
        acc += (e - s)
        if acc >= min_shot:
            acc = 0.0; switches += 1
            if n_angles <= 1:
                cur = 0
            elif switches % wide_every == 0:
                cur = 0
            else:
                cur = punch
                if n_angles > 2:
                    punch = 1 + (punch % (n_angles - 1))
    return angles

def render_combined(inp, outp, keep, angles, layout, W, H, clean, jid):
    # Remove silences AND cut between virtual angles in one pass: trim each kept
    # segment, crop it to its angle, scale back to full frame, and concat video + audio.
    rects = podcut.LAYOUTS.get(layout, podcut.LAYOUTS["duo"])
    parts, cat = [], ""
    for i, ((s, e), a) in enumerate(zip(keep, angles)):
        v = "[0:v]trim=%.3f:%.3f,setpts=PTS-STARTPTS" % (s, e)
        rect = rects[a] if a < len(rects) else None
        if rect:
            fw, fh, fx, fy = rect
            cw, ch = podcut.even(fw * W), podcut.even(fh * H)
            cx, cy = min(podcut.even(fx * W), W - cw), min(podcut.even(fy * H), H - ch)
            v += ",crop=%d:%d:%d:%d" % (cw, ch, cx, cy)
        v += ",scale=%d:%d,setsar=1[v%d]" % (W, H, i)
        parts.append(v)
        parts.append("[0:a]atrim=%.3f:%.3f,asetpts=PTS-STARTPTS[a%d]" % (s, e, i))
        cat += "[v%d][a%d]" % (i, i)
    graph = ";".join(parts) + ";" + cat + "concat=n=%d:v=1:a=1[outv][outa]" % len(keep)
    amap = "[outa]"
    if clean:
        graph += ";[outa]" + podcut.AUDIO_CLEAN + "[outac]"; amap = "[outac]"
    jd = os.path.dirname(outp)
    fc = os.path.join(jd, "fc.txt"); open(fc, "w").write(graph)
    args = SimpleNamespace(encoder="libx264", preset=PRESET, crf=CRF, abitrate="192k")
    cmd = ["nice", "-n", "15", podcut.ffmpeg_bin(), "-y", "-i", inp,
           "-filter_complex_script", fc, "-map", "[outv]", "-map", amap] + podcut.encode_opts(args) + \
          ["-progress", "pipe:1", "-nostats", outp]
    logf = open(os.path.join(jd, "ffmpeg.log"), "wb")
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=logf, text=True)
    denom = max(0.1, sum(e - s for s, e in keep))
    for line in p.stdout:
        line = line.strip()
        if line.startswith("out_time_us="):
            try:
                set_job(jid, progress=min(99, round(int(line.split("=", 1)[1]) / 1e6 / denom * 100)))
            except ValueError:
                pass
        elif line == "progress=end":
            set_job(jid, progress=100)
    p.wait(); logf.close()
    return p.returncode

def worker():
    while True:
        jid = WORK.get()
        job = get_job(jid)
        if not job:
            continue
        jd = os.path.join(JOBS_DIR, jid)
        inp = job["input_path"]
        try:
            set_job(jid, state="analyzing", progress=0)
            samples, sr = podcut.read_mono(inp)
            r = podcut.analyze_silence(samples, sr, job["threshold"], job["min_silence"], job["min_keep"], job["pad"])
            if not r["keep"]:
                set_job(jid, state="error", error="No speech detected above the threshold — try a lower silence threshold.")
                continue
            set_job(jid, state="rendering", progress=0,
                    original=r["total"], edited=r["kept"], removed=r["removed"], cuts=len(r["remove"]))
            out = os.path.join(jd, "edited.mp4")
            if job.get("angles"):
                dim = podcut.probe_dimensions(inp)
                if dim:
                    W, H = podcut.even(dim[0]), podcut.even(dim[1])
                    layout = job.get("layout", "duo")
                    n_angles = len(podcut.LAYOUTS.get(layout, podcut.LAYOUTS["duo"]))
                    ang = assign_angles_timed(r["keep"], n_angles)
                    rc = render_combined(inp, out, r["keep"], ang, layout, W, H, job.get("clean", True), jid)
                else:
                    rc = render_with_progress(inp, out, r["keep"], r["kept"], jid, job.get("clean", True))
            else:
                rc = render_with_progress(inp, out, r["keep"], r["kept"], jid, job.get("clean", True))
            if rc != 0 or not os.path.isfile(out):
                set_job(jid, state="error", error="ffmpeg failed while rendering (see server log).")
                continue
            set_job(jid, state="done", progress=100, output_path=out,
                    output_size=os.path.getsize(out), done_at=time.time())
        except BaseException as e:  # podcut calls sys.exit on unreadable files; never let that kill the worker
            set_job(jid, state="error", done_at=time.time(),
                    error=(str(e).split("\n")[0].replace(inp, job.get("name", "the file")).rstrip(": ")[:300]
                           or "Could not process this file."))
        finally:
            try:
                if os.path.isfile(inp):
                    os.remove(inp)  # drop the big upload as soon as it is processed
            except OSError:
                pass

def reaper():
    while True:
        now = time.time()
        with JOB_LOCK:
            items = list(JOBS.items())
        for jid, j in items:
            if j.get("state") in ("done", "error") and j.get("done_at") and now - j["done_at"] > KEEP_SECONDS:
                shutil.rmtree(os.path.join(JOBS_DIR, jid), ignore_errors=True)
                with JOB_LOCK:
                    JOBS.pop(jid, None)
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

# ------------------------------------------------------------------ routes
@app.after_request
def harden(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    if resp.mimetype == "text/html":
        resp.headers["Cache-Control"] = "no-store"  # always load the current page after an update
    return resp

@app.route("/healthz")
def healthz():
    return "ok"

@app.route("/login", methods=["POST"])
def login():
    if verify_password(request.form.get("password", "")):
        resp = make_response(redirect("/"))
        resp.set_cookie(COOKIE, make_token(), max_age=SESSION_TTL, httponly=True,
                        samesite="Lax", secure=request.is_secure)
        return resp
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

@app.route("/api/job", methods=["POST"])
def api_job():
    require_auth()
    # The file is sent as the raw request body (params in the query string), so a
    # multi-GB upload streams straight to disk — no multipart spooling or extra copy.
    name = os.path.basename(request.args.get("name", "episode"))[:120] or "episode"
    ext = os.path.splitext(name)[1].lower()
    if not re.match(r"^\.[a-z0-9]{1,5}$", ext):
        ext = ".mp4"
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
                out.write(chunk)
    except ValueError:
        shutil.rmtree(jd, ignore_errors=True)
        return {"error": "File is larger than the %d GB limit." % round(MAX_BYTES / (1024 ** 3))}, 413
    except Exception:  # connection dropped mid-upload: do not leave a partial file behind
        shutil.rmtree(jd, ignore_errors=True)
        return {"error": "Upload was interrupted."}, 400
    if total == 0:
        shutil.rmtree(jd, ignore_errors=True)
        return {"error": "No file received."}, 400
    set_job(jid, state="queued", progress=0, name=name, created=time.time(), input_path=inp,
            threshold=clampf(request.args.get("threshold"), -60, -20, -40),
            min_silence=clampf(request.args.get("min_silence"), 0.1, 5, 0.5),
            pad=clampf(request.args.get("pad"), 0, 1, 0.12),
            min_keep=clampf(request.args.get("min_keep"), 0, 2, 0.2),
            clean=request.args.get("clean", "1") not in ("0", "false", "no", "off"),
            angles=request.args.get("angles", "0") in ("1", "true", "yes", "on"),
            layout=request.args.get("layout") if request.args.get("layout") in ("single", "duo") else "duo")
    WORK.put(jid)
    return {"id": jid}

@app.route("/api/job/<jid>")
def api_status(jid):
    require_auth()
    if not re.match(r"^[0-9a-f]{32}$", jid):
        abort(404)
    j = get_job(jid)
    if not j:
        abort(404)
    out = {k: j.get(k) for k in ("state", "progress", "name", "error", "cuts")}
    for k in ("original", "edited", "removed"):
        if j.get(k) is not None:
            out[k] = round(j[k], 1); out[k + "_h"] = fmt_dur(j[k])
    if j.get("state") == "done":
        out["download"] = "/api/job/%s/file" % jid
        out["preview"] = "/api/job/%s/preview" % jid
        out["size_mb"] = round(j.get("output_size", 0) / 1e6, 1)
        if j.get("original"):
            out["saved_pct"] = round(j["removed"] / j["original"] * 100)
    return out

@app.route("/api/job/<jid>/file")
def api_file(jid):
    require_auth()
    if not re.match(r"^[0-9a-f]{32}$", jid):
        abort(404)
    j = get_job(jid)
    if not j or j.get("state") != "done" or not j.get("output_path"):
        abort(404)
    base = re.sub(r"[^A-Za-z0-9_.-]+", "_", os.path.splitext(j.get("name", "episode"))[0])[:60] or "episode"
    return send_file(j["output_path"], as_attachment=True, download_name=base + "_podcut.mp4")

@app.route("/api/job/<jid>/preview")
def api_preview(jid):
    require_auth()
    if not re.match(r"^[0-9a-f]{32}$", jid):
        abort(404)
    j = get_job(jid)
    if not j or j.get("state") != "done" or not j.get("output_path"):
        abort(404)
    # inline (not an attachment) + range support so the <video> player can stream and seek
    return send_file(j["output_path"], mimetype="video/mp4", as_attachment=False, conditional=True)

# ------------------------------------------------------------------ pages
def page(title, body):
    return ("""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>%s</title><style>
:root{--bg:#131210;--surface:#1c1b18;--surface2:#26241f;--border:#332f28;--fg:#f2f0e9;--muted:#a39f93;--accent:#ff8a3d;--accent-ink:#241100;--keep:#34c28c;color-scheme:dark}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:640px;margin:0 auto;padding:28px max(16px,env(safe-area-inset-left)) 60px}
h1{font-size:1.6rem;margin:0 0 2px}.logo{width:40px;height:40px;border-radius:10px;background:var(--accent);color:var(--accent-ink);display:grid;place-items:center;font-weight:800;font-size:1.3rem}
.head{display:flex;align-items:center;gap:12px;margin-bottom:6px}.sub{color:var(--muted);margin:0 0 22px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:20px;margin-bottom:16px}
label{display:block;font-size:.82rem;color:var(--muted);font-weight:600;margin:14px 0 5px}
input[type=file],input[type=password]{width:100%%;background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:11px;color:var(--fg);font:inherit}
input[type=range]{width:100%%;accent-color:var(--accent)}
.rangeval{float:right;color:var(--fg);font-variant-numeric:tabular-nums}
.btn{appearance:none;border:0;border-radius:10px;background:var(--accent);color:var(--accent-ink);font:600 .95rem system-ui;padding:12px 18px;cursor:pointer;width:100%%;margin-top:18px}
.btn.sec{background:var(--surface2);color:var(--fg);border:1px solid var(--border);width:auto;margin:0}
.muted{color:var(--muted);font-size:.85rem}.err{color:#ff6d90;font-size:.9rem;margin-top:10px}
.bar{height:12px;background:var(--surface2);border-radius:99px;overflow:hidden;margin:12px 0}.bar>i{display:block;height:100%%;width:0;background:var(--accent);transition:width .4s}
.tiles{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;margin:14px 0}
.tile{background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:10px}.tile b{font-size:1.1rem;font-variant-numeric:tabular-nums}.tile span{display:block;font-size:.68rem;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.dl{display:inline-block;margin-top:14px;background:var(--keep);color:#06281c;font-weight:700;text-decoration:none;padding:12px 20px;border-radius:10px}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px}
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
<p class=sub>Upload a full episode, PodCut removes the silences and gives you back the edited file.</p>
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
  <div id=layoutrow hidden><label for=layout>Who's on camera</label><select id=layout><option value=duo>Two people, side by side</option><option value=single>One person</option></select></div>
  <button class=btn id=go>Upload &amp; edit</button>
  <p class=muted id=hint style=margin-top:12px>Big files take a while to upload and render. Keep this tab open.</p>
  <p class=err id=err hidden></p>
</div>
<div class=card id=progress hidden>
  <div class=top><b id=pname>Working…</b><span class=muted id=pstate></span></div>
  <div class=bar><i id=pbar></i></div>
  <div class=tiles id=ptiles hidden>
    <div class=tile><span>Original</span><b id=torig>–</b></div>
    <div class=tile><span>Edited</span><b id=tedit>–</b></div>
    <div class=tile><span>Saved</span><b id=tsave>–</b></div>
  </div>
  <video id=preview controls playsinline style="width:100%;margin-top:14px;border-radius:10px;background:#000;display:none"></video>
  <div style="display:flex;flex-wrap:wrap;gap:10px;align-items:center">
    <a class=dl id=dl hidden>Download edited file</a>
    <button class="btn sec" id=again hidden>Edit another</button>
  </div>
  <p class=err id=perr hidden></p>
  <p class=muted id=keepnote hidden>Your edited file is kept on the server for a limited time, then deleted.</p>
</div>
<script>
var $=function(i){return document.getElementById(i)};
function rng(id,out,fmt){var e=$(id);function u(){$(out).textContent=fmt(+e.value)}e.addEventListener('input',u);u()}
rng('th','thv',function(v){return v+' dB'});rng('ms','msv',function(v){return v.toFixed(2)+' s'});rng('pd','pdv',function(v){return v.toFixed(2)+' s'});
$('angles').addEventListener('change',function(){$('layoutrow').hidden=!$('angles').checked;});
$('again').addEventListener('click',function(){location.reload();});
$('go').addEventListener('click',function(){
  var f=$('file').files[0];
  if(!f){$('err').hidden=false;$('err').textContent='Choose a file first.';return;}
  $('err').hidden=true;
  var qs='?name='+encodeURIComponent(f.name)+'&threshold='+$('th').value+'&min_silence='+$('ms').value+'&pad='+$('pd').value+'&clean='+($('clean').checked?'1':'0')+'&angles='+($('angles').checked?'1':'0')+'&layout='+$('layout').value;
  $('form').hidden=true;$('progress').hidden=false;$('pname').textContent=f.name;$('pstate').textContent='uploading…';
  var xhr=new XMLHttpRequest();xhr.open('POST','/api/job'+qs);
  xhr.setRequestHeader('Content-Type','application/octet-stream');
  xhr.upload.onprogress=function(e){if(e.lengthComputable){var p=Math.round(e.loaded/e.total*100);$('pbar').style.width=p+'%';$('pstate').textContent='uploading '+p+'%';}};
  xhr.onload=function(){
    if(xhr.status!==200){var m='Upload failed ('+xhr.status+').';try{m=JSON.parse(xhr.responseText).error||m;}catch(e){}showErr(m);return;}
    var j=JSON.parse(xhr.responseText);if(j.error){showErr(j.error);return;}
    $('pbar').style.width='0%';poll(j.id);
  };
  xhr.onerror=function(){showErr('Upload failed — check your connection.');};
  xhr.send(f);
});
function showErr(m){$('perr').hidden=false;$('perr').textContent=m;$('pstate').textContent='';}
function poll(id){
  fetch('/api/job/'+id).then(function(r){return r.json()}).then(function(j){
    if(j.state==='error'){showErr(j.error||'Something went wrong.');return;}
    var label={queued:'queued…',analyzing:'finding silences…',rendering:'rendering… ',done:'done'}[j.state]||j.state;
    $('pstate').textContent=label+(j.state==='rendering'?(j.progress||0)+'%':'');
    $('pbar').style.width=(j.progress||0)+'%';
    if(j.original_h){$('ptiles').hidden=false;$('torig').textContent=j.original_h;$('tedit').textContent=j.edited_h||'–';$('tsave').textContent=(j.saved_pct!=null?j.saved_pct+'%':'–');}
    if(j.state==='done'){if(j.preview){var v=$('preview');v.src=j.preview;v.style.display='block';}$('dl').hidden=false;$('dl').href=j.download;$('dl').textContent='Download ('+(j.size_mb||'?')+' MB)';$('again').hidden=false;$('keepnote').hidden=false;$('pstate').textContent='done';return;}
    setTimeout(function(){poll(id)},1500);
  }).catch(function(){setTimeout(function(){poll(id)},3000)});
}
</script>""")

if __name__ == "__main__":
    port = int(os.environ.get("PODCUT_PORT", "8820"))
    app.run(host="127.0.0.1", port=port, threaded=True)
