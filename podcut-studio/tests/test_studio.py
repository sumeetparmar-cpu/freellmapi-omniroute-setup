#!/usr/bin/env python3
"""PodCut Studio tests: the edit engine, the typed-command parser, and the web API end to end.
Needs python3, flask and ffmpeg.  Run:  python3 podcut-studio/tests/test_studio.py"""
import json, os, shutil, subprocess, sys, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
TMP = tempfile.mkdtemp(prefix="podcut-test-")
os.environ.update(PODCUT_DATA_DIR=os.path.join(TMP, "data"), PODCUT_MIN_FREE_GB="0.01", PODCUT_PRESET="ultrafast")
os.environ.pop("PODCUT_PWHASH", None)
import podcut, app as studio

FPS = (30, 1)
FRAMES = [[0, 300], [330, 600], [660, 900]]          # 30 s source, 1 s and 2 s removed

def ff(*args):
    subprocess.run([podcut.ffmpeg_bin(), "-y", "-v", "error"] + list(args), check=True)

def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type,sample_rate,width,height",
                          "-of", "json", path], stdout=subprocess.PIPE, check=True).stdout
    return json.loads(out)

class Engine(unittest.TestCase):
    def test_tree_expr_matches_ranges(self):
        rng = [[3, 7], [10, 11], [20, 40], [41, 45], [90, 91]]
        e = podcut.tree_expr(rng).replace("between(n,", "B(n,").replace("if(lt(n,", "I(n<").replace("lt(", "")
        B = lambda n, a, b: a <= n <= b
        I = lambda c, x, y: x if c else y
        for n in range(100):
            self.assertEqual(bool(eval(e.replace("I(n<", "I(n<").replace("),B", ",B") if False else self._py(podcut.tree_expr(rng)), {"n": n, "B": B, "I": I})),
                             any(a <= n < b for a, b in rng), n)
    @staticmethod
    def _py(expr):   # ffmpeg expression -> python: between(n,a,b) -> B(n,a,b); if(lt(n,x),p,q) -> I(n<x,p,q)
        import re
        expr = re.sub(r"if\(lt\(n,(\d+)\)", r"I(n<\1", expr)
        return expr.replace("between(", "B(")
    def test_audio_follows_picture_without_drift(self):
        import random
        random.seed(7)
        for fps in ((30, 1), (30000, 1001), (25, 1), (60, 1), (2997, 100)):
            frames, pos = [], 0
            for _ in range(4000):
                pos += random.randint(1, 40); n = random.randint(2, 120); frames.append([pos, pos + n]); pos += n
            plan, r, k = podcut.audio_plan(frames, fps), fps[0] / fps[1], podcut.OUT_RATE / podcut.CHUNK
            self.assertEqual(len(plan), len(frames))
            v = a = 0; prev = 0
            for (f0, f1), (c0, c1) in zip(frames, plan):
                self.assertGreaterEqual(c0, prev); prev = c1
                self.assertLess(abs(c0 / k - f0 / r), 0.006)            # segment starts with its picture
                v += f1 - f0; a += c1 - c0
                self.assertLess(abs(a / k - v / r), 0.003)              # running total never drifts
    def test_rates_ranges_shots(self):
        self.assertEqual(podcut.snap_rate(30.0), (30, 1)); self.assertEqual(podcut.snap_rate(29.97), (30000, 1001))
        self.assertEqual(podcut.snap_rate(23.976), (24000, 1001)); self.assertEqual(podcut.snap_rate(15.0), (1500, 100))
        self.assertEqual(podcut.subtract_ranges([[0, 10], [20, 30]], [[5, 22], [28, 40]]), [[0, 5], [22, 28]])
        self.assertEqual(podcut.quantize_keep([[0, 1.0], [1.01, 2.0], [5, 5.001]], FPS), [[0, 60]])
        for layout in podcut.FOCUS:
            for rect in [podcut.zoom_rect(f, 0.62) for f in podcut.FOCUS[layout]]:
                self.assertEqual(rect[0], rect[1])                       # same shape as the frame: no stretching
                self.assertTrue(0 <= rect[2] <= 1 - rect[0] and 0 <= rect[3] <= 1 - rect[1])
        spec = podcut.default_spec(angles=True)
        shots = podcut.plan_shots([[0, 3000]], FPS, spec)                 # one long take still changes angle
        self.assertGreater(len(shots), 3)
        gaps = [b[0] - a[0] for a, b in zip(shots, shots[1:])]
        self.assertTrue(all(g >= spec["min_shot"] * 30 for g in gaps), gaps)
        self.assertIsNone(shots[0][1]); self.assertIsNone(shots[3][1]); self.assertIsNotNone(shots[1][1])

class Commands(unittest.TestCase):
    def run_cmd(self, text, spec=None, has_video=True):
        return podcut.apply_command(text, spec or podcut.default_spec(), FRAMES, FPS, 30.0, has_video)
    def test_pace(self):
        s, r, a = self.run_cmd("tighter")
        self.assertLess(s["min_silence"], 0.5); self.assertGreater(s["threshold"], -40); self.assertIsNone(a)
        s2, _, _ = self.run_cmd("make it a lot looser please")
        self.assertGreater(s2["min_silence"], 0.8); self.assertLess(s2["threshold"], -40)
    def test_cuts_use_the_edited_timeline(self):
        s, r, _ = self.run_cmd("cut 0:05 to 0:08")
        self.assertEqual(s["cuts"], [[5.0, 8.0]]); self.assertIn("Cut 0:05 to 0:08", r[0])
        s, _, _ = self.run_cmd("cut between 0:09 and 0:12")           # edited 10 s is source 11 s (1 s was removed)
        self.assertEqual(s["cuts"], [[9.0, 13.0]])
        s, _, _ = self.run_cmd("remove the first 2 seconds"); self.assertEqual(s["cuts"], [[0.0, 2.0]])
        s, _, _ = self.run_cmd("start at 0:03"); self.assertEqual(s["cuts"], [[0.0, 3.0]])
        s, _, _ = self.run_cmd("cut the last 2 seconds"); self.assertEqual(s["cuts"], [[28.0, 30.0]])
        s, _, _ = self.run_cmd("trim 10 seconds from the end"); self.assertEqual(s["cuts"], [[18.0, 30.0]])
        s, _, _ = self.run_cmd("end at 0:10"); self.assertEqual(s["cuts"], [[10.0, 30.0]])
        s, _, _ = self.run_cmd("keep only 0:02 to 0:06"); self.assertEqual(s["cuts"], [[0.0, 2.0], [6.0, 30.0]])
        s, _, _ = self.run_cmd("remove from 1 minute to 2 minutes")
        self.assertEqual(s["cuts"], []); self.assertEqual(podcut.parse_time("1h 2m 3s"), 3723.0); self.assertEqual(podcut.parse_time("1:02:03"), 3723.0)
        s, r, _ = self.run_cmd("cut 0:08 to 0:05"); self.assertEqual(s["cuts"], []); self.assertIn("before", r[0])
    def test_restore(self):
        s, r, _ = self.run_cmd("restore the pause at 0:10")
        self.assertEqual(s["protect"], [[10.0, 11.0]]); self.assertIn("Restored 1.0 s", r[0])
        spec = podcut.default_spec(cuts=[[10.2, 10.8]])
        s, _, _ = self.run_cmd("put back the cut at 0:10", spec); self.assertEqual(s["cuts"], [])
        s, r, _ = self.run_cmd("restore the pause at 0:02"); self.assertEqual(s["protect"], []); self.assertIn("nearest", r[0])
    def test_settings(self):
        for text, key, want in [("audio cleanup off", "clean", False), ("no noise reduction", "clean", False), ("use the original audio", "clean", False),
                                ("remove the background noise", "clean", True), ("keep all the pauses", "silence", False),
                                ("don't cut the silences", "silence", False), ("multi-angle on", "angles", True),
                                ("threshold -35", "threshold", -35.0), ("min silence 0.8", "min_silence", 0.8),
                                ("padding 200ms", "pad", 0.2), ("fade in and out", "fade", 0.6), ("louder", "lufs", -14),
                                ("hold shots for 6 seconds", "min_shot", 6.0)]:
            s, r, _ = self.run_cmd(text, podcut.default_spec(clean=(key != "clean" or not want)))
            self.assertEqual(s[key], want, text)
        on = podcut.default_spec(angles=True)
        self.assertFalse(self.run_cmd("no zoom", on)[0]["angles"]); self.assertFalse(self.run_cmd("turn off the angles", on)[0]["angles"])
        self.assertEqual(self.run_cmd("one person")[0]["layout"], "single"); self.assertEqual(self.run_cmd("there are three people")[0]["layout"], "trio")
        self.assertLess(self.run_cmd("zoom in more")[0]["zoom"], 0.62); self.assertGreater(self.run_cmd("less zoom")[0]["zoom"], 0.62)
        self.assertGreater(self.run_cmd("switch angles slower")[0]["min_shot"], 3.0); self.assertLess(self.run_cmd("change angles more often")[0]["min_shot"], 3.0)
        self.assertEqual(self.run_cmd("no fades", podcut.default_spec(fade=0.6))[0]["fade"], 0.0)
        self.assertIn("no picture", self.run_cmd("multi-angle on", has_video=False)[1][0])
    def test_actions_and_unknown(self):
        self.assertEqual(self.run_cmd("undo")[2], "undo"); self.assertEqual(self.run_cmd("Reset")[2], "reset"); self.assertEqual(self.run_cmd("render")[2], "render")
        self.assertEqual(self.run_cmd("help")[1], [podcut.HELP])
        self.assertIn("not available", self.run_cmd("add captions")[1][0])
        s, r, a = self.run_cmd("make it purple")
        self.assertEqual(s, podcut.default_spec()); self.assertIn("did not understand", r[0]); self.assertEqual(r[-1], podcut.HELP)
    def test_several_instructions(self):
        s, r, _ = self.run_cmd("tighter and louder"); self.assertLess(s["min_silence"], 0.5); self.assertEqual(s["lufs"], -14); self.assertEqual(len(r), 2)
        s, r, _ = self.run_cmd("cut 0:05 to 0:08; fade in and out. then audio cleanup off")
        self.assertEqual((s["cuts"], s["fade"], s["clean"]), ([[5.0, 8.0]], 0.6, False))

class Api(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.c = studio.app.test_client()
        tone = "volume=enable='between(mod(t,5),4,5)':volume=0"   # 4 s of sound, 1 s of silence, repeating
        cls.video, cls.audio, cls.long, cls.bad = [os.path.join(TMP, n) for n in ("clip.mp4", "clip.wav", "long.mp4", "bad.mp4")]
        ff("-f", "lavfi", "-i", "testsrc=s=320x240:r=30:d=24", "-f", "lavfi", "-i", "sine=f=440:d=24", "-af", tone,
           "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", cls.video)
        ff("-f", "lavfi", "-i", "sine=f=440:d=24", "-af", tone, cls.audio)
        ff("-f", "lavfi", "-i", "testsrc=s=1280x720:r=30:d=120", "-f", "lavfi", "-i", "sine=f=440:d=120", "-af", tone,
           "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", cls.long)
        open(cls.bad, "w").write("not a video")
    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(TMP, ignore_errors=True)
    def login(self):
        self.assertEqual(self.c.post("/login", data={"password": "podcut"}).status_code, 302)
    def upload(self, path, query=""):
        r = self.c.post("/api/job?name=" + os.path.basename(path) + query, data=open(path, "rb").read(), content_type="application/octet-stream")
        self.assertEqual(r.status_code, 200, r.data); return r.get_json()["id"]
    def wait(self, jid, busy=("queued", "analyzing", "rendering"), secs=120):
        end = time.time() + secs
        while time.time() < end:
            j = self.c.get("/api/job/" + jid).get_json()
            if j["state"] not in busy: return j
            time.sleep(0.2)
        self.fail("timed out: %s" % j)
    def say(self, jid, text):
        r = self.c.post("/api/job/%s/command" % jid, json={"text": text}); self.assertEqual(r.status_code, 200); return r.get_json()
    def render(self, jid):
        self.assertTrue(self.c.post("/api/job/%s/render" % jid).get_json()["ok"]); return self.wait(jid)
    def fetch(self, jid, name):
        r = self.c.get("/api/job/%s/file" % jid); self.assertEqual(r.status_code, 200)
        out = os.path.join(TMP, name); open(out, "wb").write(r.data); return probe(out), r
    def test_1_needs_login(self):
        c = studio.app.test_client()
        for url in ("/api/job/" + "0" * 32, "/api/job/" + "0" * 32 + "/source", "/api/space?bytes=1"):
            self.assertEqual(c.get(url).status_code, 401)
        self.assertEqual(c.post("/api/job?name=x.mp4", data=b"x").status_code, 401)
        self.assertEqual(c.post("/login", data={"password": "nope"}).status_code, 401)
        self.assertIn(b"Sign in", c.get("/").data); self.assertEqual(c.get("/").headers["Cache-Control"], "no-store")
    def test_2_review_edit_render(self):
        self.login()
        jid = self.upload(self.video); j = self.wait(jid)
        self.assertEqual((j["state"], j["cuts"], j["has_video"]), ("ready", 4, True)); self.assertNotIn("download", j)
        edl = self.c.get(j["edl"]).get_json()
        self.assertEqual(len(edl["keep"]), 5); self.assertEqual(edl["shots"], [])
        before = sum(b - a for a, b in edl["keep"]); self.assertAlmostEqual(before, 21.2, delta=0.3)
        src = self.c.get(j["source"], headers={"Range": "bytes=0-99"})                 # the page plays the original, seekable
        self.assertEqual((src.status_code, src.headers["Content-Type"], len(src.data)), (206, "video/mp4", 100))
        r = self.say(jid, "cut 0:02 to 0:05"); self.assertTrue(r["changed"]); self.assertIn("The edit is now", r["reply"])
        after = sum(b - a for a, b in self.c.get(j["edl"]).get_json()["keep"]); self.assertAlmostEqual(before - after, 3.0, delta=0.05)
        self.assertFalse(self.say(jid, "make it purple")["changed"])
        self.assertIn("remove everything", self.say(jid, "threshold -20 and cut 0:00 to 5:00")["reply"])
        self.assertTrue(self.say(jid, "undo")["changed"]); self.assertIn("Nothing to undo", self.say(jid, "undo")["reply"])
        self.say(jid, "multi-angle on, one person"); self.say(jid, "one person")
        shots = self.c.get(j["edl"]).get_json()["shots"]; self.assertGreater(len(shots), 2); self.assertLess(shots[1][1], 1)
        self.say(jid, "fade in and out"); self.say(jid, "cut 0:02 to 0:05")
        j = self.render(jid)
        self.assertEqual((j["state"], j["stale"], j["note"]), ("ready", False, ""))
        info, resp = self.fetch(jid, "out.mp4")
        self.assertIn("clip_podcut.mp4", resp.headers["Content-Disposition"])
        kinds = {s["codec_type"]: s for s in info["streams"]}
        self.assertEqual((kinds["video"]["width"], kinds["video"]["height"], kinds["audio"]["sample_rate"]), (320, 240, "48000"))
        self.assertAlmostEqual(float(info["format"]["duration"]), after, delta=0.15)
        self.assertEqual(self.c.get(j["preview"], headers={"Range": "bytes=0-9"}).status_code, 206)
        self.say(jid, "looser"); j = self.c.get("/api/job/" + jid + "?chat=1").get_json()
        self.assertTrue(j["stale"]); self.assertGreater(len(j["chat"]), 6)        # download now marked as out of date
        self.assertIn("Rendering", self.say(jid, "render")["reply"]); self.assertFalse(self.wait(jid)["stale"])
        self.assertTrue(self.c.post("/api/job/%s/delete" % jid).get_json()["ok"])
        self.assertEqual(self.c.get("/api/job/" + jid).status_code, 404)
        self.assertFalse(os.path.exists(os.path.join(studio.JOBS_DIR, jid)))
    def test_3_audio_only_and_bad_file(self):
        self.login()
        jid = self.upload(self.audio); j = self.wait(jid)
        self.assertEqual((j["state"], j["has_video"]), ("ready", False))
        self.assertIn("no picture", self.say(jid, "multi-angle on")["reply"])
        j = self.render(jid); info, resp = self.fetch(jid, "out.m4a")
        self.assertIn("clip_podcut.m4a", resp.headers["Content-Disposition"])
        self.assertEqual([s["codec_type"] for s in info["streams"]], ["audio"]); self.assertAlmostEqual(float(info["format"]["duration"]), 21.2, delta=0.4)
        bad = self.upload(self.bad); j = self.wait(bad)
        self.assertEqual(j["state"], "error"); self.assertNotIn(TMP, j["error"])
        self.assertEqual(os.listdir(os.path.join(studio.JOBS_DIR, bad)), [])          # nothing left behind
        again = self.upload(self.video); self.assertEqual(self.wait(again)["state"], "ready")   # the worker survived
    def test_4_cancel_and_disk_guard(self):
        self.login()
        jid = self.upload(self.long, "&angles=1&layout=duo"); self.assertEqual(self.wait(jid)["state"], "ready")
        self.assertTrue(self.c.post("/api/job/%s/render" % jid).get_json()["ok"])
        self.assertFalse(self.c.post("/api/job/%s/render" % jid).get_json()["ok"])    # one render at a time
        time.sleep(0.4); self.c.post("/api/job/%s/cancel" % jid); j = self.wait(jid)
        self.assertEqual((j["state"], j["note"]), ("ready", "")); self.assertNotIn("download", j)
        self.assertFalse(any(n.startswith("render") for n in os.listdir(os.path.join(studio.JOBS_DIR, jid))))
        j = self.render(jid); self.assertIn("download", j)                            # and it still renders afterwards
        info, _ = self.fetch(jid, "long.mp4"); self.assertAlmostEqual(float(info["format"]["duration"]), 101.0, delta=1.5)
        self.assertFalse(self.c.get("/api/space?bytes=%d" % (10 ** 14)).get_json()["ok"])
        self.assertTrue(self.c.get("/api/space?bytes=1000").get_json()["ok"])
        old = studio.MIN_FREE
        try:
            studio.MIN_FREE = 10 ** 15                                                # pretend the disk is full
            r = self.c.post("/api/job?name=x.mp4", data=b"12345", content_type="application/octet-stream"); self.assertEqual(r.status_code, 507)
        finally:
            studio.MIN_FREE = old

if __name__ == "__main__":
    unittest.main(verbosity=1)
