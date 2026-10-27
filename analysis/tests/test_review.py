"""区間の判定が想定どおりかを確かめる。python -m unittest discover -s tests（analysis/ で）"""
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import review  # noqa: E402

FIXTURE = HERE / "fixture_basic.jsonl"
T0 = 1_790_000_000.0
C = {"start_z": 2.0, "start_min_s": 0.5, "end_z": 1.5, "end_min_s": 0.5}


class DetectTest(unittest.TestCase):
    """z を直接与えて、開始・終了・ヒステリシス・短い動きを見る"""

    def run_z(self, pieces):
        z = []
        for dur, val in pieces:
            z += [val] * int(round(dur * 30))
        t = np.arange(len(z)) / 30
        return review.detect(t, np.array(z, float), np.ones(len(z), bool), C)

    def test_start_needs_min_duration(self):
        segs, shorts = self.run_z([(1, 0), (0.4, 3), (1, 0)])
        self.assertEqual(len(segs), 0)
        self.assertEqual(len(shorts), 1)
        segs, shorts = self.run_z([(1, 0), (0.6, 3), (1, 0)])
        self.assertEqual(len(segs), 1)
        self.assertEqual(len(shorts), 0)

    def test_hysteresis(self):
        # 1.5 未満が 0.3秒だけ → 続く
        segs, _ = self.run_z([(1, 0), (1, 3), (0.3, 1.0), (1, 3), (1, 0)])
        self.assertEqual(len(segs), 1)
        # 1.5〜2 の間はずっと続く
        segs, _ = self.run_z([(1, 0), (1, 3), (2, 1.8), (1, 0)])
        self.assertEqual(len(segs), 1)
        self.assertAlmostEqual(segs[0].i1 / 30, 4.0, delta=0.05)   # 終わりは 1.5 を下回った時刻
        # 1.5 未満が 0.6秒 → 分かれる
        segs, _ = self.run_z([(1, 0), (1, 3), (0.6, 1.0), (1, 3), (1, 0)])
        self.assertEqual(len(segs), 2)

    def test_direction_and_peak(self):
        segs, _ = self.run_z([(1, 0), (0.5, -2.5), (0.5, -4), (1, 0)])
        self.assertEqual(len(segs), 1)
        self.assertEqual(segs[0].sign, -1)
        self.assertEqual(segs[0].peak_z, -4)

    def test_invalid_cuts(self):
        t = np.arange(90) / 30
        z = np.full(90, 3.0)
        ok = np.ones(90, bool)
        ok[45:] = False
        segs, _ = review.detect(t, z, ok, C)
        self.assertEqual(len(segs), 1)
        self.assertEqual(segs[0].truncated, "判定できない時間で打ち切り")

    def test_after_gap_not_short(self):
        t = np.arange(90) / 30
        z = np.concatenate([np.full(30, 3.0), np.full(5, 3.0), np.zeros(55)])
        ok = np.ones(90, bool)
        ok[:30] = False                      # 判定できない時間の直後に 2 を超えたまま始まる
        segs, shorts = review.detect(t, z, ok, C)
        self.assertEqual((len(segs), len(shorts)), (0, 0))


class FixtureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        c = review.load_criteria(review.HERE / "criteria.json", [])
        cls.rec = review.load(FIXTURE)
        cls.a = review.analyze(cls.rec, c)
        cls.segs = [(s.metric, s.sign, cls.rec.t[s.i0] - T0, cls.rec.t[s.i1] - T0) for s in cls.a.segments]

    def starts(self, metric):
        return [(sign, round(t0, 2), round(t1, 2)) for m, sign, t0, t1 in self.segs if m == metric]

    def test_brow_down(self):
        s = self.starts("brow_down")
        self.assertEqual(len(s), 2, s)
        sign, t0, t1 = s[0]
        self.assertEqual(sign, 1)
        self.assertTrue(20.0 < t0 < 20.3, s)          # ならし 0.3秒で z=2 を超えるのは約0.15秒後
        self.assertTrue(1.0 < t1 - t0 < 1.5, s)       # 終わりは 21 + 0.3·ln(5/1.5) ≈ 21.36
        self.assertTrue(40.0 < s[1][1] < 40.3 and 42.0 < s[1][2] < 42.6, s)   # 41–41.3 の谷では切れない

    def test_short_movement(self):
        shorts = [self.rec.t[i0] - T0 for i0, _ in self.a.shorts["brow_down"]]
        self.assertEqual(len(shorts), 1, shorts)
        self.assertAlmostEqual(shorts[0], 30.15, delta=0.15)

    def test_excluded_and_no_baseline(self):
        for _, _, t0, _ in self.segs:
            self.assertFalse(50 <= t0 < 53 or 60 <= t0 < 63 or 90 <= t0 < 100, self.segs)

    def test_voice(self):
        self.assertEqual([x[0] for x in self.starts("rms_db")], [1, -1])
        self.assertEqual(self.starts("f0_hz"), [])     # insufficient は計算しない
        self.assertFalse(self.a.usable["f0_hz"])

    def test_jaw_after_retake(self):
        s = self.starts("jaw_open")
        self.assertEqual(len(s), 1)
        self.assertTrue(105 < s[0][1] < 105.3)

    def test_rows_and_quality(self):
        rows = review.segment_rows(self.a)
        first = rows[0]
        self.assertEqual(first["指標"], "brow_down")
        self.assertEqual(first["場面"], "食事")
        self.assertIn("不快", first["前後の家族の印"])
        self.assertEqual(first["向き"], "いつもより強い")
        self.assertEqual(first["普段の平均"], 0.05)
        q = review.quality(self.a, calm=True)
        # 判定対象外：yaw 50° の 2秒と、顔が映らない約1.5秒
        self.assertTrue(3.0 < q["excluded_s"] < 4.2, q["excluded_s"])
        self.assertEqual(q["rates"]["total"], 5)
        self.assertEqual(q["mark_rows"][0][2][0], 0.0)                  # 20.8 の印は最初の区間の中
        self.assertAlmostEqual(q["mark_rows"][1][2][0], 0.17, delta=0.1)  # 21.5 は終わり（≈21.33）の後

    def test_outputs(self):
        with tempfile.TemporaryDirectory() as d:
            review.main([str(FIXTURE), "--calm", "--out-dir", d, "--set", "brow_down.start_min_s=0.5"])
            csv_text = (Path(d) / "fixture_basic_segments.csv").read_text(encoding="utf-8-sig")
            self.assertTrue(csv_text.startswith("# 基準 version"))
            self.assertIn("brow_down: ならし 0.3秒", csv_text)
            html_text = (Path(d) / "fixture_basic.html").read_text(encoding="utf-8")
            self.assertIn("data:image/png;base64,", html_text)
            self.assertIn("10分あたり", html_text)
            # docs/wording-guide.md の使わない語（「不快」は家族の印の名前としてだけ出る）
            for word in ["笑顔", "痛み", "怒り", "苦痛", "異常", "検知", "緊急", "危険", "助けを求めて", "要求している",
                         "安心してください", "監視", "見守り", "患者", "誤報", "%増", "%減"]:
                self.assertNotIn(word, html_text)
            self.assertIn("通知候補", html_text)
            self.assertIn("仮の値", csv_text)


    def test_baseline_times(self):
        """v0.4 の baseline 行（wall_s / valid_s）と、古い行（duration_s だけ）の両方を出す"""
        import json
        with tempfile.TemporaryDirectory() as d:
            lines = FIXTURE.read_text(encoding="utf-8").splitlines()
            out, first = [], True
            for line in lines:
                o = json.loads(line)
                if o.get("type") == "baseline" and first:
                    first = False
                    o.pop("duration_s", None)
                    o.update({"wall_s": 23.4, "valid_s": 10.0, "yaw_limit_deg": 35, "warmup_s": 5})
                out.append(json.dumps(o, ensure_ascii=False))
            p = Path(d) / "new.jsonl"
            p.write_text("\n".join(out) + "\n", encoding="utf-8")
            review.main([str(p), "--out-dir", d])
            doc = (Path(d) / "new.html").read_text(encoding="utf-8")
            self.assertIn("23.4秒", doc)
            self.assertIn("10秒", doc)
            self.assertIn("開いてから 5秒より後", doc)
            self.assertIn("時計の時間で数えた（v0.3 までの記録）", doc)   # 2つ目の baseline は古い形のまま


class HeadTurnTest(unittest.TestCase):
    """顔を向ける・そむける：アプリの HeadTurnTracker と同じ決まり（0.5秒続いたら、15° と 35° のヒステリシス）"""

    def run_yaw(self, pieces):
        """pieces：(秒, yaw)。yaw が None なら顔が見えない"""
        t, face, yaw = [], [], []
        for dur, y in pieces:
            for _ in range(int(round(dur * 30))):
                t.append(len(t) / 30)
                face.append(y is not None)
                yaw.append(np.nan if y is None else y)
        return review.head_states(np.array(t), np.array(face), np.array(yaw, float))

    def test_sequence(self):
        states, ch = self.run_yaw([(1, 0), (0.3, 40), (0.5, 0), (1, 40), (1, 25), (1, 10), (1, None),
                                   (1, -20), (1, -40), (1, 0)])
        self.assertEqual([c["value"] for c in ch],
                         ["右へ", "正面に戻った", "見えなくなった（直前は正面）", "見えるようになった（左 20°）",
                          "左へ", "正面に戻った"])
        self.assertAlmostEqual(ch[0]["t"], 1.8, delta=0.05)    # 0.3秒だけの右は数えない。右は 1.8秒から
        self.assertEqual(ch[0]["from"], "front")
        self.assertAlmostEqual(ch[1]["t"], 3.8, delta=0.05)    # 25° の間は右を続け、10° になった時刻から正面
        self.assertEqual(states[0], "front")                   # 0.5秒続いて決まったら、なり始めた時刻から数える
        self.assertEqual(states[int(2.5 * 30)], "right")
        self.assertEqual(states[int(3.5 * 30)], "right")   # 25° の間は右を続ける
        self.assertEqual(states[int(5.5 * 30)], "hidden")
        self.assertEqual(states[int(6.3 * 30)], "oblique")

    def test_hidden_keeps_last_yaw(self):
        _, ch = self.run_yaw([(1, 40), (1, None)])
        self.assertEqual([c["value"] for c in ch], ["見えなくなった（直前は右 40°）"])
        self.assertEqual(ch[0]["yaw"], 40)

    def test_fixture_events_match(self):
        """作り物の記録に書いた head_turn と、1コマごとの向きから数え直したものが同じ"""
        rec = review.load(FIXTURE)
        _, ch = review.head_states(rec.t, rec.face, rec.yaw)
        written = review.head_events(rec)
        self.assertEqual([c["value"] for c in ch], [e["value"] for e in written])
        for c, e in zip(ch, written):
            self.assertAlmostEqual(c["t"], e["t_ms"] / 1000, delta=0.05)
            self.assertEqual((c["from"], c["to"]), (e["from"], e["head"]))

    def test_report(self):
        c = review.load_criteria(review.HERE / "criteria.json", [])
        a = review.analyze(review.load(FIXTURE), c)
        q = review.quality(a, calm=False)
        self.assertAlmostEqual(q["head"]["right"][0], 2.0, delta=0.1)
        self.assertAlmostEqual(q["head"]["hidden"][0], 2.0, delta=0.1)
        with tempfile.TemporaryDirectory() as d:
            review.main([str(FIXTURE), "--out-dir", d])
            doc = (Path(d) / "fixture_basic.html").read_text(encoding="utf-8")
            self.assertIn("顔を向けた・そむけた記録（head_turn、4件）", doc)
            self.assertIn("見えなくなった（直前は正面）", doc)
            self.assertIn("カメラ：広角", doc)
            self.assertNotIn("超広角で記録しています", doc)

    def test_ultra_wide_note(self):
        import json
        with tempfile.TemporaryDirectory() as d:
            lines = FIXTURE.read_text(encoding="utf-8").splitlines()
            h = json.loads(lines[0])
            h.update({"camera": "ultra_wide", "camera_label": "超広角"})
            p = Path(d) / "uw.jsonl"
            p.write_text("\n".join([json.dumps(h, ensure_ascii=False)] + lines[1:]) + "\n", encoding="utf-8")
            review.main([str(p), "--out-dir", d])
            doc = (Path(d) / "uw.html").read_text(encoding="utf-8")
            self.assertIn("カメラ：超広角", doc)
            self.assertIn("超広角で記録しています", doc)


class BaselineRebuildTest(unittest.TestCase):
    """--baseline-s / --compare-baseline：普段を1コマごとの値から作り直す（アプリと同じ条件）"""

    @classmethod
    def setUpClass(cls):
        cls.rec = review.load(FIXTURE)

    def test_rebuild_times(self):
        b30 = review.rebuild_baselines(self.rec, 30)
        # 開いてから5秒は数えない → 5 + 30 = 35秒で記録し終える。90秒の取り直しの後は 20秒しかないので作れない
        self.assertEqual(len(b30), 1)
        self.assertAlmostEqual(b30[0]["t_ms"] / 1000 - T0, 35.0, delta=0.15)
        self.assertEqual((b30[0]["target_s"], b30[0]["valid_s"]), (30, 30.0))
        self.assertEqual(b30[0]["metrics"]["brow_down"]["n"], 300)   # 3コマに1コマ（30コマ/秒 → 10コマ/秒）
        # 60秒：yaw 50° の 50–52 と、顔が映らない 60–62（と、その後の読めない時間）は数えないので、65 より遅れる
        b60 = review.rebuild_baselines(self.rec, 60)
        self.assertEqual(len(b60), 1)
        self.assertTrue(69.0 < b60[0]["t_ms"] / 1000 - T0 < 70.0, b60[0]["t_ms"] / 1000 - T0)

    def test_restart_starts_new_period(self):
        b = review.rebuild_baselines(self.rec, 10)
        self.assertEqual(len(b), 2)
        self.assertAlmostEqual(b[1]["started_ms"] / 1000 - T0, 90.0, delta=0.01)
        self.assertAlmostEqual(b[1]["t_ms"] / 1000 - T0, 100.0, delta=0.15)

    def test_compare_and_report(self):
        with tempfile.TemporaryDirectory() as d:
            review.main([str(FIXTURE), "--calm", "--compare-baseline", "30,60", "--baseline-s", "30", "--out-dir", d])
            doc = (Path(d) / "fixture_basic.html").read_text(encoding="utf-8")
            self.assertIn("普段の長さの比べ", doc)
            self.assertIn("30秒で作り直し", doc)
            self.assertIn("60秒で作り直し", doc)
            self.assertIn("10分あたりの区間", doc)
            self.assertIn("30秒で作り直したもの", doc)          # 本体のレポートも 30秒の普段で数えた
        c = review.load_criteria(review.HERE / "criteria.json", [])
        rows = review.compare_baselines(self.rec, c, [30, 60])
        self.assertEqual([x["label"] for x in rows], ["記録の baseline 行（アプリ）", "30秒で作り直し", "60秒で作り直し"])
        self.assertGreater(rows[1]["judged_s"], rows[2]["judged_s"])   # 短い普段ほど早く判定を始める


class FaceBelowTest(unittest.TestCase):
    """表情の「いつもより弱い」は、アプリと揃えて違いに数えず、参考として別に出す（face_below_counts=false）"""

    @classmethod
    def setUpClass(cls):
        import json
        cls.dir = tempfile.TemporaryDirectory()
        out = []
        for line in FIXTURE.read_text(encoding="utf-8").splitlines():
            o = json.loads(line)
            if o.get("type") == "baseline":
                o["metrics"]["mouth_smile"]["std"] = 0.02          # 下限 0.03 → 0 にすると z≈−3.3
            if o.get("type") == "frame" and o.get("bs") and 25 <= (o["t_ms"] / 1000 - T0) < 27:
                o["bs"]["mouthSmileLeft"] = o["bs"]["mouthSmileRight"] = 0.0
            out.append(json.dumps(o, ensure_ascii=False))
        cls.path = Path(cls.dir.name) / "weak.jsonl"
        cls.path.write_text("\n".join(out) + "\n", encoding="utf-8")
        cls.rec = review.load(cls.path)

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def test_not_counted_by_default(self):
        c = review.load_criteria(review.HERE / "criteria.json", [])
        self.assertFalse(c["face_below_counts"])
        a = review.analyze(self.rec, c)
        self.assertEqual([(s.metric, s.sign) for s in a.weak_segments], [("mouth_smile", -1)])
        self.assertNotIn("mouth_smile", [s.metric for s in a.segments])
        q = review.quality(a, calm=True)
        self.assertEqual(q["rates"]["total"], 5)                  # 10分あたりにも入れない（元の5件のまま）
        self.assertEqual(q["rates"]["per_metric"]["mouth_smile"][2], 1)
        self.assertEqual([x["weak"] for x in review.compare_baselines(self.rec, c, [])], [1])

    def test_counted_when_enabled(self):
        c = review.load_criteria(review.HERE / "criteria.json", [])
        c["face_below_counts"] = True
        a = review.analyze(self.rec, c)
        self.assertEqual(a.weak_segments, [])
        self.assertIn(("mouth_smile", -1), [(s.metric, s.sign) for s in a.segments])

    def test_outputs(self):
        with tempfile.TemporaryDirectory() as d:
            review.main([str(self.path), "--calm", "--out-dir", d])
            doc = (Path(d) / "weak.html").read_text(encoding="utf-8")
            self.assertIn("表情の弱い方への変化（参考）（1件）", doc)
            self.assertIn("face_below_counts=false", doc)
            csv_text = (Path(d) / "weak_segments.csv").read_text(encoding="utf-8-sig")
            self.assertIn("参考（表情の弱い方）", csv_text)
            self.assertIn("違い,", csv_text)


class BlinkAndVoiceFloorTest(unittest.TestCase):
    """目を細める：まばたきのコマ（と前後0.2秒）は判定対象外・普段にも数えない。声の大きさ：std の下限 6dB"""

    BLINKS = [7.0, 8.5, 33.0, 36.0]   # 7・8.5 は普段（0–10）の中

    @classmethod
    def setUpClass(cls):
        import json
        cls.dir = tempfile.TemporaryDirectory()
        out = []
        for line in FIXTURE.read_text(encoding="utf-8").splitlines():
            o = json.loads(line)
            if o.get("type") == "frame" and o.get("bs"):
                ts = o["t_ms"] / 1000 - T0
                for b in cls.BLINKS:
                    if b - 0.15 <= ts < b + 0.3:            # 目を細める数値が、まばたきの前後で高くなる（外す範囲の内側）
                        o["bs"]["eyeSquintLeft"] = o["bs"]["eyeSquintRight"] = 0.4
                    if b <= ts < b + 0.2:                  # まばたき
                        o["bs"]["eyeBlinkLeft"] = o["bs"]["eyeBlinkRight"] = 0.8
            out.append(json.dumps(o, ensure_ascii=False))
        cls.path = Path(cls.dir.name) / "blink.jsonl"
        cls.path.write_text("\n".join(out) + "\n", encoding="utf-8")
        cls.rec = review.load(cls.path)
        cls.c = review.load_criteria(review.HERE / "criteria.json", [])

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def test_criteria(self):
        self.assertEqual(self.c["metrics"]["eye_squint"]["blink_mask"], {"threshold": 0.3, "pad_s": 0.2})
        self.assertEqual(self.c["std_floor"]["rms_db"], 6.0)

    def test_mask_frames(self):
        m = review.blink_mask(self.rec, self.c)
        rel = self.rec.t - T0
        self.assertTrue(m[np.searchsorted(rel, 33.0)] and m[np.searchsorted(rel, 32.85)] and m[np.searchsorted(rel, 33.3)])
        self.assertFalse(m[np.searchsorted(rel, 32.7)] or m[np.searchsorted(rel, 33.5)])

    def test_no_eye_squint_segments_with_mask(self):
        a = review.analyze(self.rec, self.c)
        self.assertEqual([s for s in a.segments if s.metric == "eye_squint"], [])
        import copy
        c2 = copy.deepcopy(self.c)
        del c2["metrics"]["eye_squint"]["blink_mask"]
        a2 = review.analyze(self.rec, c2)
        starts = [round(self.rec.t[s.i0] - T0) for s in a2.segments if s.metric == "eye_squint"]
        self.assertEqual(starts, [33, 36])                # 外さなければ、まばたきの前後が区間になる

    def test_baseline_without_blinks(self):
        a = review.analyze(self.rec, self.c)
        b = a.rec.baselines[0]
        self.assertTrue(b["blink_masked"])
        self.assertEqual(b["metrics"]["eye_squint"]["mean"], 0.1)    # まばたきの前後（0.4）は数えていない
        self.assertEqual(b["eye_squint_app"]["mean"], 0.1)          # アプリの値は残す
        self.assertFalse(b["metrics"]["eye_squint"]["insufficient"])
        r = review.rebuild_baselines(self.rec, 30, self.c)[0]["metrics"]["eye_squint"]
        r0 = review.rebuild_baselines(self.rec, 30)[0]["metrics"]["eye_squint"]
        self.assertEqual(r["mean"], 0.1)
        self.assertGreater(r0["mean"], 0.1)
        self.assertLess(r["n"], r0["n"])

    def test_voice_floor(self):
        a = review.analyze(self.rec, self.c)
        i = int(np.searchsorted(self.rec.t, T0 + 71.4))
        self.assertAlmostEqual(a.z["rms_db"][i], (-30 + 50) / 6, delta=0.1)   # std 3dB → 下限 6dB で割る

    def test_report(self):
        with tempfile.TemporaryDirectory() as d:
            review.main([str(self.path), "--out-dir", d])
            doc = (Path(d) / "blink.html").read_text(encoding="utf-8")
            self.assertIn("まばたき（eyeBlinkLeft/Right の平均）が 0.3 以上", doc)
            self.assertIn("目を細めるだけ判定対象外だった時間（まばたき）", doc)
            self.assertIn("まばたきを外して数え直し", doc)
            self.assertIn("std下限 6", doc)


class CompositeTest(unittest.TestCase):
    """研究用：上半分の顔の動きの合計（PSPI 型）。区間の判定には使わない"""

    @classmethod
    def setUpClass(cls):
        import json
        cls.dir = tempfile.TemporaryDirectory()
        out = []
        for line in FIXTURE.read_text(encoding="utf-8").splitlines():
            o = json.loads(line)
            if o.get("type") == "frame" and o.get("bs"):
                ts = o["t_ms"] / 1000 - T0
                bs = o["bs"]
                if 74 <= ts < 77:                        # 75 の印（快）の前後で、頬を上げる動き
                    bs["cheekSquintLeft"] = bs["cheekSquintRight"] = 0.3
                if 86 <= ts < 87:                        # 鼻にしわを寄せる・上唇を上げる（合計には入れない）
                    bs["noseSneerLeft"] = bs["noseSneerRight"] = 0.3
                    bs["mouthUpperUpLeft"] = bs["mouthUpperUpRight"] = 0.3
                if 80 <= ts < 81 or 85 <= ts < 85.2:     # 目を閉じる 1秒と、短いまばたき 0.2秒
                    bs["eyeBlinkLeft"] = bs["eyeBlinkRight"] = 0.8
            out.append(json.dumps(o, ensure_ascii=False))
        cls.path = Path(cls.dir.name) / "comp.jsonl"
        cls.path.write_text("\n".join(out) + "\n", encoding="utf-8")
        cls.rec = review.load(cls.path)
        cls.c = review.load_criteria(review.HERE / "criteria.json", [])
        cls.a = review.analyze(cls.rec, cls.c)
        cls.comp = review.research_composite(cls.a)

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def at(self, sec):
        return self.comp.value[int(np.searchsorted(self.rec.t, T0 + sec))]

    def test_values(self):
        self.assertEqual(self.comp.means[0]["values"]["cheekSquint"], 0.05)  # baseline 行の時間のコマから数え直し
        self.assertNotIn("noseSneer", self.comp.means[0]["values"])         # 2026-10-27 に外した
        self.assertAlmostEqual(self.at(76), 0.25, delta=0.01)               # max(cheekSquint, eyeSquint) の差
        self.assertAlmostEqual(self.at(86.5), 0.0, delta=0.01)              # noseSneer・mouthUpperUp は入れない
        self.assertAlmostEqual(self.at(30.8), 0.0, delta=0.01)              # 普段どおりなら 0（マイナスは 0）
        self.assertAlmostEqual(self.at(80.7), 0.75, delta=0.01)             # 目を閉じて 0.5秒以上：eyeBlink の差
        self.assertAlmostEqual(self.at(85.1), 0.0, delta=0.01)              # 短いまばたきは入れない
        self.assertTrue(np.isnan(self.at(51)))                              # 横を向いている（判定対象外）
        self.assertTrue(np.isnan(self.at(95)))                              # 普段を取り直している間

    def test_marks(self):
        rows = {r["value"]: r for r in self.comp.mark_rows}
        self.assertGreater(rows["快"]["mean"], self.comp.no_mark_mean)
        self.assertEqual(set(self.comp.by_value), {"不快", "分からない", "快"})

    def test_missing_values(self):
        self.assertEqual(review.missing_values(self.a), [])
        rec = review.load(self.path)
        rec.pairs["cheekSquint"][:] = np.where(np.isfinite(rec.pairs["cheekSquint"]), 0.0, np.nan)  # いつも 0
        del rec.pairs["jawOpen"]                                                                    # 記録に無い
        a = review.analyze(rec, self.c)
        self.assertEqual(review.missing_values(a), ["jawOpen", "cheekSquint"])
        self.assertEqual(review.quality(a, False)["missing"], ["jawOpen", "cheekSquint"])

    def test_not_used_for_segments(self):
        import copy
        c2 = copy.deepcopy(self.c)
        c2["research_composite"]["enabled"] = False
        a2 = review.analyze(self.rec, c2)
        self.assertIsNone(review.research_composite(a2))
        self.assertEqual(len(a2.segments), len(self.a.segments))
        self.assertEqual(len(review.candidates(a2)), len(review.candidates(self.a)))

    def test_report(self):
        with tempfile.TemporaryDirectory() as d:
            review.main([str(self.path), "--calm", "--out-dir", d])
            doc = (Path(d) / "comp.html").read_text(encoding="utf-8")
            self.assertIn("上半分の顔の動きの合計（PSPI 型・研究用）", doc)
            self.assertIn("数が少ない", doc)                     # 印は3件（10件たまるまで）
            self.assertIn("印のない時間", doc)
            self.assertNotIn("値が出ていません", doc)            # どの数値も出ている
            self.assertNotIn("痛み", doc)
            self.assertNotIn("目安", doc.split("<h2>区間の数")[1].split("</p>")[0])   # 10分に1回以下の目安は出さない
            self.assertNotIn("10分に1", doc.split("<h2>区間の数")[1].split("</table>")[0])


class CandidateTest(unittest.TestCase):
    """作った区間を与えて、通知候補の条件 A・B・C と場面の振り分けを見る（fixture の時刻を使う）"""

    @classmethod
    def setUpClass(cls):
        cls.c = review.load_criteria(review.HERE / "criteria.json", [])
        cls.rec = review.load(FIXTURE)

    def run_segs(self, segs):
        a = review.analyze(self.rec, self.c)
        idx = lambda sec: int(np.searchsorted(self.rec.t, T0 + sec))
        a.segments = [review.Segment(m, sign, idx(s0), idx(s1), idx(s0), 3.0) for m, sign, s0, s1 in segs]
        return review.candidates(a)

    def test_cross_modal(self):
        got = self.run_segs([("brow_down", 1, 26, 50), ("rms_db", 1, 30, 50)])   # 同時は 30–50 の 20秒
        self.assertEqual([x.rule for x in got], ["A"])
        self.assertAlmostEqual(got[0].t - T0, 45, delta=0.1)
        self.assertEqual(self.run_segs([("brow_down", 1, 26, 50), ("rms_db", 1, 40, 50)]), [])   # 10秒だけ

    def test_long(self):
        got = self.run_segs([("jaw_open", 1, 26, 100)])
        self.assertEqual([x.rule for x in got], ["B"])
        self.assertAlmostEqual(got[0].t - T0, 86, delta=0.1)

    def test_repeat_and_scene(self):
        got = self.run_segs([("eye_squint", 1, 1, 2), ("eye_squint", 1, 5, 6), ("eye_squint", 1, 18, 19),
                             ("mouth_smile", 1, 30, 31), ("mouth_smile", 1, 40, 41), ("mouth_smile", 1, 50, 51)])
        self.assertEqual([(x.rule, round(x.t - T0)) for x in got], [("C", 18), ("C", 50)])
        self.assertTrue(got[0].in_scene)          # 15–25 は「食事」
        self.assertEqual(got[0].scene, "食事")
        self.assertFalse(got[1].in_scene)


if __name__ == "__main__":
    unittest.main()


class CompareSavedTest(unittest.TestCase):
    """v1.2：保存した普段（source: saved）で比べた記録。今日の普段は compared: false で書かれる"""

    @classmethod
    def setUpClass(cls):
        import json
        cls.dir = tempfile.TemporaryDirectory()
        out = []
        for line in FIXTURE.read_text(encoding="utf-8").splitlines():
            o = json.loads(line)
            if o.get("type") == "baseline" and o["t_ms"] / 1000 - T0 < 20:
                o["source"], o["compared"], o["blink_masked"] = "today", False, True
                saved = json.loads(json.dumps(o))
                saved.update({"source": "saved", "compared": True, "saved_ms": int((T0 - 86400) * 1000),
                              "t_ms": int((T0 + 0.5) * 1000)})
                saved.pop("started_ms", None)
                saved["metrics"]["brow_down"]["mean"] = 0.20      # 前に保存した眉の普段は高め
                out.append(json.dumps(saved, ensure_ascii=False))
            elif o.get("type") == "baseline":
                o["source"], o["compared"], o["blink_masked"] = "today", True, True   # 取り直したあとは今日の普段で比べる
            out.append(json.dumps(o, ensure_ascii=False))
        cls.path = Path(cls.dir.name) / "saved.jsonl"
        cls.path.write_text("\n".join(out) + "\n", encoding="utf-8")
        cls.rec = review.load(cls.path)
        cls.c = review.load_criteria(review.HERE / "criteria.json", [])

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def test_uses_compared_rows(self):
        self.assertEqual([b.get("source") for b in self.rec.baselines], ["saved", "today"])
        self.assertEqual(len(self.rec.all_baselines), 3)

    def test_compare(self):
        cs = review.compare_saved(self.rec, self.c)
        self.assertNotIn("missing", cs)
        self.assertAlmostEqual(cs["shift"]["brow_down"]["shift"], (0.20 - 0.05) / 0.03, places=3)   # 今日の std 0.02 → 下限 0.03
        self.assertAlmostEqual(cs["shift"]["mouth_smile"]["shift"], 0.0)
        # 眉の普段が高い保存した普段では、20秒・40秒の眉の区間が出ない
        self.assertLess(cs["runs"]["saved"]["per_metric"]["brow_down"], cs["runs"]["today"]["per_metric"]["brow_down"])

    def test_report(self):
        with tempfile.TemporaryDirectory() as d:
            review.main([str(self.path), "--compare-saved", "--out-dir", d])
            doc = (Path(d) / "saved.html").read_text(encoding="utf-8")
            self.assertIn("保存した普段と今日の普段（--compare-saved）", doc)
            self.assertIn("いいえ（記録しただけ）", doc)

    def test_missing_saved(self):
        rec = review.load(FIXTURE)
        self.assertIn("missing", review.compare_saved(rec, self.c))


class SavedOffTest(unittest.TestCase):
    """v1.2.1：「保存した普段ですぐ始める」がオフの記録。保存した普段は compared: false で書かれ、今日の普段で判定する"""

    def test_off_record(self):
        import json
        out = []
        for line in FIXTURE.read_text(encoding="utf-8").splitlines():
            o = json.loads(line)
            if o.get("type") == "baseline":
                o["source"], o["compared"], o["blink_masked"] = "today", True, True
                if o["t_ms"] / 1000 - T0 < 20:
                    sv = json.loads(json.dumps(o))
                    sv.update({"source": "saved", "compared": False, "saved_ms": int((T0 - 86400) * 1000),
                               "t_ms": int((T0 + 0.5) * 1000)})
                    sv.pop("started_ms", None)
                    sv["metrics"]["brow_down"]["mean"] = 0.20
                    out.append(json.dumps(sv, ensure_ascii=False))
            out.append(json.dumps(o, ensure_ascii=False))
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "off.jsonl"
            path.write_text("\n".join(out) + "\n", encoding="utf-8")
            rec = review.load(path)
            c = review.load_criteria(review.HERE / "criteria.json", [])
            self.assertEqual([b.get("source") for b in rec.baselines], ["today", "today"])   # 判定は今日の普段だけ
            base = review.analyze(review.load(FIXTURE), c)
            self.assertEqual(len(review.analyze(rec, c).segments), len(base.segments))      # 保存した普段の行があっても区間は変わらない
            cs = review.compare_saved(rec, c)
            self.assertNotIn("missing", cs)
            self.assertIn("saved", cs["runs"])
            self.assertAlmostEqual(cs["shift"]["brow_down"]["shift"], (0.20 - 0.05) / 0.03, places=3)
