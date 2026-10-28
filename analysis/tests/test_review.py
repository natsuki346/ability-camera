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
        # 作り物の記録は direction_version の無い古い形（映像で見て右）なので、読むときに入れ替えて本人から見て左（v1.7.1〜）
        self.assertAlmostEqual(q["head"]["left"][0], 2.0, delta=0.1)
        self.assertAlmostEqual(q["head"]["hidden"][0], 2.0, delta=0.1)
        with tempfile.TemporaryDirectory() as d:
            review.main([str(FIXTURE), "--out-dir", d])
            doc = (Path(d) / "fixture_basic.html").read_text(encoding="utf-8")
            self.assertIn("顔を向けた・そむけた記録（head_turn、4件）", doc)
            self.assertIn("見えなくなった（直前は正面）", doc)
            self.assertIn("本人から見た右・左にしています", doc)
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


EYES_FIXTURE = HERE / "fixture_eyes.jsonl"


class EyesClosedTest(unittest.TestCase):
    """目を閉じている（v1.4〜）：eyeBlink ≥ 0.5 が 0.5秒以上で区間、0.5 未満が 0.2秒で終わり。普段とは比べない"""

    @classmethod
    def setUpClass(cls):
        cls.c = review.load_criteria(review.HERE / "criteria.json", [])
        cls.rec = review.load(EYES_FIXTURE)
        cls.a = review.analyze(cls.rec, cls.c)
        cls.segs = [s for s in cls.a.segments if s.metric == review.EYES]

    def sec(self, i):
        return round(float(self.rec.t[i]) - T0, 3)

    def test_criteria(self):
        self.assertEqual(self.c["eyes_closed"], {**self.c["eyes_closed"], "threshold": 0.5, "start_min_s": 0.5, "end_open_s": 0.2})
        self.assertNotIn("eye_closed", self.c["research_composite"])   # 区間と同じ決まりに揃えた

    def test_fixture_segments(self):
        got = [(self.sec(s.i0), self.sec(s.i1), s.truncated) for s in self.segs]
        self.assertEqual(got, [(20.0, 24.0, ""),                           # 4秒
                               (30.0, 34.0, ""),                           # ちょうど 0.5、0.1秒だけ開いてもつながる
                               (40.0, 40.967, "判定できない時間で打ち切り"),  # 横を向いた
                               (50.0, 51.0, ""),                           # 顔の無いコマは何も変えない
                               (85.0, 89.967, "記録の終わりで打ち切り")])
        self.assertEqual(len(self.a.segments), len(self.segs))             # ほかの指標の区間は出ない（eye_squint はまばたきで外れる）
        self.assertTrue(all(s.sign > 0 and np.isnan(s.peak_z) for s in self.segs))

    def test_detect_direct(self):
        t = np.arange(0, 3, 0.1)
        ok = np.ones(len(t), bool)
        ec = self.c["eyes_closed"]
        def run(b):
            return [(round(t[s.i0], 1), round(t[s.i1], 1)) for s in review.detect_eyes_closed(t, np.array(b, float), ok, ec)]
        self.assertEqual(run([0.9] * 4 + [0.0] * 26), [])                         # 0.4秒はまばたき
        self.assertEqual(run([0.9] * 6 + [0.0] * 24), [(0.0, 0.6)])               # 0.5秒で始まり、開いた最初のコマで終わり
        self.assertEqual(run([0.49] * 30), [])                                    # 0.5 未満は閉じていない
        self.assertEqual(run([0.9] * 6 + [0.0] * 2 + [0.9] * 6 + [0.0] * 16), [(0.0, 1.4)])   # 0.2秒より短く開いた
        self.assertEqual(run([0.9] * 6 + [0.0] * 3 + [0.9] * 6 + [0.0] * 15), [(0.0, 0.6), (0.9, 1.5)])
        b = [0.9] * 30
        b[10] = float("nan")                                                      # 顔の無いコマ
        self.assertEqual(run(b), [(0.0, 2.9)])

    def test_no_baseline_and_excluded(self):
        self.assertFalse(any(70 <= self.sec(s.i0) < 80 for s in self.segs))        # 普段を取り直している間は判定しない
        self.assertFalse(any(41 <= self.sec(s.i0) < 42 for s in self.segs))        # 横を向いたあと 0.5秒に届かない

    def test_rows_counts_and_candidates(self):
        rows = review.segment_rows(self.a)
        self.assertEqual({r["指標名"] for r in rows}, {"目を閉じている"})
        self.assertEqual({r["向き"] for r in rows}, {"閉じている"})
        self.assertEqual(rows[0]["長さ_秒"], 4.0)
        self.assertEqual(rows[0]["普段の平均"], "")
        q = review.quality(self.a, True)
        self.assertEqual(q["rates"]["per_metric"][review.EYES], (5, 0, 0))
        self.assertEqual(q["rates"]["total"], 5)                                  # --calm の10分あたりにも入る
        self.assertEqual(review.candidates(self.a), [])                           # 通知候補には入れない

    def test_composite_uses_same_rule(self):
        comp = review.research_composite(self.a)
        np.testing.assert_array_equal(comp.closed, self.a.closed)
        self.assertTrue(comp.closed[int(np.searchsorted(self.rec.t, T0 + 32.05))])   # 0.1秒開いた間も閉じている
        self.assertFalse(comp.closed[int(np.searchsorted(self.rec.t, T0 + 73))])     # 普段が無い間は入れない

    def test_report(self):
        import json
        with tempfile.TemporaryDirectory() as d:
            # baseline 行に eyes_closed_s（v1.4〜）を書いた記録
            lines = EYES_FIXTURE.read_text(encoding="utf-8").splitlines()
            out = []
            for line in lines:
                o = json.loads(line)
                if o.get("type") == "baseline":
                    o.update({"valid_s": 10.0, "eyes_closed_s": 2.5})
                out.append(json.dumps(o, ensure_ascii=False))
            p = Path(d) / "eyes.jsonl"
            p.write_text("\n".join(out) + "\n", encoding="utf-8")
            review.main([str(p), "--calm", "--out-dir", d])
            doc = (Path(d) / "eyes.html").read_text(encoding="utf-8")
            csv_text = (Path(d) / "eyes_segments.csv").read_text(encoding="utf-8-sig")
        self.assertIn("目を閉じている（eyes_closed、普段とは比べない）", doc)
        self.assertIn("2.5秒（25%）", doc)
        self.assertIn("区間の一覧（5件）", doc)
        self.assertEqual(csv_text.count(",eyes_closed,目を閉じている,閉じている,"), 5)
        for word in ("眠", "痛", "意識"):
            self.assertNotIn(word, doc)


@unittest.skipUnless(sys.platform == "darwin" and __import__("shutil").which("swiftc"), "Mac の swiftc が必要")
class AppMatchTest(unittest.TestCase):
    """アプリ（DiffEngine、リプレイと同じ）と review.py で、作り物の記録の区間が一致する（check_app.py）"""

    def test_fixtures(self):
        import check_app
        c = review.load_criteria(review.HERE / "criteria.json", [])
        exe = check_app.build()
        for p, n in ((FIXTURE, 7), (EYES_FIXTURE, 5), (VOICE_FIXTURE, 5)):   # v1.7〜は声が出たの区間も入る
            diffs, count = check_app.compare(p, exe, c)
            self.assertEqual(diffs, [], p.name)
            self.assertEqual(count, n)


VOICE_FIXTURE = HERE / "fixture_voice.jsonl"


class VoiceSelfTest(unittest.TestCase):
    """本人の声（v1.6〜）：声の違いは本人の声のコマだけで判定し、声の普段は本人の声が10秒たまったら作る"""

    @classmethod
    def setUpClass(cls):
        cls.c = review.load_criteria(review.HERE / "criteria.json", [])
        cls.rec = review.load(VOICE_FIXTURE)
        cls.a = review.analyze(cls.rec, cls.c)

    def sec(self, i):
        return round(float(self.rec.t[i]) - T0, 3)

    def test_criteria(self):
        vc = self.c["voice_self"]
        self.assertEqual((vc["keys"], vc["window_s"], vc["min_range"]), (["jawOpen", "mouthClose", "mouthFunnel", "mouthPucker"], 0.3, 0.04))
        self.assertEqual(self.c["voice_baseline"]["target_s"], 10.0)

    def test_computed_matches_recorded(self):
        rec = review.load(VOICE_FIXTURE)
        rec.voice_self_rec = None                                   # 記録の値を使わずに決め直す
        got = review.voice_self_values(rec, self.c, review.face_valid(rec, self.c))
        want = self.rec.voice_self_rec
        same = (np.isnan(got) & np.isnan(want)) | (got == want)
        self.assertTrue(same.all())
        self.assertEqual(int((want == 0).sum()), 12 * 30)  # 本人以外の声 10秒 ＋ 横向き 2秒

    def test_segments_only_self_voice(self):
        got = [(s.metric, s.sign, self.sec(s.i0)) for s in self.a.segments if s.metric != review.VOICE_ON]
        self.assertEqual(got, [("f0_hz", 1, 50.0), ("rms_db", 1, 80.0)])   # 本人以外の声（12–20・60–62）と横向き（70–72）は区間なし
        # 声が出た（v1.7〜）：本人の声の時間だけ（本人以外の声・横向きは入らない）
        on = [round(self.sec(s.i0)) for s in self.a.segments if s.metric == review.VOICE_ON]
        self.assertEqual(on, [25, 50, 80])
        rows = [r for r in review.segment_rows(self.a) if r["指標"] != review.VOICE_ON]
        self.assertEqual(rows[0]["普段の平均"], 200.0)                         # 声の普段の行（part: voice）を使う

    def test_voice_baseline_rows(self):
        self.assertEqual([b.get("part") for b in self.rec.baselines], ["face", "voice"])
        rebuilt = review.rebuild_voice_baselines(self.rec, self.c)
        app = self.rec.baselines[1]
        self.assertEqual(len(rebuilt), 1)
        self.assertEqual(rebuilt[0]["t_ms"], app["t_ms"])                   # 本人の声が10秒たまった所（34.97秒）
        self.assertEqual(rebuilt[0]["metrics"], app["metrics"])
        self.assertTrue(np.isnan(self.a.z["f0_hz"][int(np.searchsorted(self.rec.t, T0 + 30))]))   # 集めている間は比べない
        both = review.rebuild_baselines(self.rec, 10.0, self.c)
        self.assertEqual(sorted(b.get("part") for b in both), ["face", "voice"])

    def test_quality_and_report(self):
        q = review.quality(self.a, False)
        self.assertAlmostEqual(q["voice"]["self_s"], 16.0, delta=0.1)       # 25–37・50–52・80–82
        self.assertAlmostEqual(q["voice"]["other_s"], 12.0, delta=0.1)      # 12–20・60–62・横向きの 70–72
        self.assertTrue(q["voice"]["recorded"])
        with tempfile.TemporaryDirectory() as d:
            review.main([str(VOICE_FIXTURE), "--out-dir", d])
            doc = (Path(d) / "fixture_voice.html").read_text(encoding="utf-8")
        self.assertIn("本人の声の時間 / 本人の声と言えない声の時間", doc)
        self.assertIn("声：本人の声のコマ", doc)
        self.assertIn("本人の声のコマだけで判定する", doc)

    def test_old_record_uses_rule(self):
        # voice_self の無い記録（fixture_basic）は決め直す：口が動いている声（70–71.5・80–81.5）だけ本人の声
        rec = review.load(FIXTURE)
        a = review.analyze(rec, self.c)
        on = [self_t for self_t in (70.5, 80.5, 30.0) if a.voice_self[int(np.searchsorted(rec.t, T0 + self_t))] == 1]
        self.assertEqual(on, [70.5, 80.5])


class FrontCameraTest(unittest.TestCase):
    """前面カメラの記録：v1.5〜v1.6（camera_orientation_version が無い）は、向きが合っていなかったと出す"""

    def report(self, header_extra):
        import json
        with tempfile.TemporaryDirectory() as d:
            lines = FIXTURE.read_text(encoding="utf-8").splitlines()
            h = json.loads(lines[0])
            h.update({"camera": "front", "camera_label": "前面（自分で試す用）", **header_extra})
            p = Path(d) / "front.jsonl"
            p.write_text("\n".join([json.dumps(h, ensure_ascii=False)] + lines[1:]) + "\n", encoding="utf-8")
            review.main([str(p), "--out-dir", d])
            return (Path(d) / "front.html").read_text(encoding="utf-8")

    def test_old_and_new(self):
        old = self.report({"mirror_corrected": True})
        self.assertIn("前面（自分で試す用）", old)
        self.assertIn("映像の向きが合っていなかった版", old)
        new = self.report({"mirror_corrected": False, "camera_orientation_version": 2})
        self.assertNotIn("映像の向きが合っていなかった版", new)


class PitchTest(unittest.TestCase):
    """声の高さ（v1.6.2〜）：アプリの求め方（Pitch.swift）が決まりどおりで、criteria.json と同じ値。範囲の外の f0 は読むときに外す"""

    def test_selftest(self):
        import pitch_check
        self.assertEqual(pitch_check.selftest(pitch_check.build()), [])

    def test_criteria_match_app(self):
        import re
        src = (review.HERE.parent / "ios" / "AbilityCam" / "Pitch.swift").read_text(encoding="utf-8")
        val = lambda name: float(re.search(rf"static let {name}(?:: \w+)? = (-?[\d.]+)", src).group(1))
        p = review.load_criteria(review.HERE / "criteria.json", [])["pitch"]
        self.assertEqual(val("floorDb"), p["floor_db"])
        self.assertEqual([val("minHz"), val("maxHz")], p["range_hz"])
        self.assertEqual(list(review.F0_RANGE), p["range_hz"])
        for k, name in (("clarity_min", "clarityMin"), ("first_peak_ratio", "firstPeakRatio"), ("octave_jump", "octaveJump"),
                        ("octave_alt_ratio", "octaveAltRatio"), ("history_s", "historyS")):
            self.assertEqual(val(name), p[k], k)

    def test_out_of_range_dropped_same_in_app(self):
        import json
        import check_app
        lines = VOICE_FIXTURE.read_text(encoding="utf-8").splitlines()
        out, n = [], 0
        for line in lines:
            o = json.loads(line)
            if o.get("type") == "frame" and o.get("f0_hz") is not None:
                n += 1
                if n % 7 == 0:
                    o["f0_hz"] = 842.0   # v1.6.1 までの取り違え
                    o.pop("voice_self", None)
            out.append(json.dumps(o, ensure_ascii=False))
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "old_f0.jsonl"
            p.write_text("\n".join(out) + "\n", encoding="utf-8")
            rec = review.load(p)
            self.assertEqual(rec.f0_dropped, n // 7)
            self.assertLessEqual(np.nanmax(rec.raw["f0_hz"]), 500)
            c = review.load_criteria(review.HERE / "criteria.json", [])
            diffs, _ = check_app.compare(p, check_app.build(), c)
            self.assertEqual(diffs, [])


def _frames_record(path, spans, marks=(), length=12.0, fps=30):
    """声が出たの確かめ用の作り物の記録（v1.6〜の形：frame に voice_self を書く）。spans：本人の声の [開始, 終了) 秒"""
    import json
    t0 = 1_800_000_000_000
    lines = [json.dumps({"schema": "ability-cam.ios.v0.2", "started_at_ms": t0, "camera": "wide"})]
    for k in range(int(length * fps)):
        s = k / fps
        on = any(a <= s < b for a, b in spans)
        lines.append(json.dumps({"type": "frame", "t_ms": t0 + round(s * 1000), "face": True,
                                 "bs": {"jawOpen": 0.3 if on and k % 2 else 0.05}, "yaw_deg": 0.0,
                                 "rms_db": -40.0 if on else -70.0, "f0_hz": 200.0 if on else None,
                                 "voice_self": True if on else None}))
    for m_t, v in marks:
        lines.append(json.dumps({"type": "event", "t_ms": t0 + round(m_t * 1000), "kind": "mark", "value": v}))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class VoiceOnTest(unittest.TestCase):
    """声が出た（v1.7〜）：本人の声のコマを 0.5秒未満の切れ目でまとめ、0.3秒以上なら区間。普段が無くても出し、違いの数には入れない"""

    SPANS = [(1.0, 1.2),              # 0.2秒 → 短いので無し
             (2.0, 3.0),              # 1秒 → 1件
             (4.0, 4.2), (4.5, 4.7),  # 0.3秒の切れ目 → つながって 1件（4.0〜4.67）
             (6.0, 6.4), (7.0, 7.4),  # 0.6秒の切れ目 → 別々に 2件
             (11.0, 12.0)]            # 記録の終わりまで → 1件（打ち切り）

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cls.path = Path(cls.dir.name) / "voice_on.jsonl"
        _frames_record(cls.path, cls.SPANS, marks=[(3.5, "快"), (9.5, "分からない")])
        cls.c = review.load_criteria(review.HERE / "criteria.json", [])
        cls.rec = review.load(cls.path)
        cls.a = review.analyze(cls.rec, cls.c)

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def segs(self):
        t0 = self.rec.t[0]
        return [(round(self.rec.t[s.i0] - t0, 2), round(self.rec.t[s.i1] - t0, 2)) for s in self.a.segments if s.metric == review.VOICE_ON]

    def test_segments(self):
        self.assertEqual(self.segs(), [(2.0, 2.97), (4.0, 4.67), (6.0, 6.37), (7.0, 7.37), (11.0, 11.97)])
        last = [s for s in self.a.segments if s.metric == review.VOICE_ON][-1]
        self.assertIn("記録の終わり", last.truncated)

    def test_no_baseline_needed_and_not_a_difference(self):
        self.assertEqual(self.rec.baselines, [])                 # 普段が無くても出す
        q = review.quality(self.a, calm=False)
        self.assertEqual(q["rates"]["total"], 0)                  # いつもとの違いの数には入れない
        self.assertEqual(q["rates"]["per_metric"][review.VOICE_ON][0], 5)
        self.assertEqual(review.candidates(self.a), [])           # 通知候補にも入れない
        self.assertTrue(all(best is None for _, _, best in q["mark_rows"]))

    def test_marks_and_totals(self):
        q = review.quality(self.a, calm=False)
        vq = q["voice_on"]
        self.assertEqual(vq["count"], 5)
        self.assertAlmostEqual(vq["total_s"], 0.97 + 0.67 + 0.37 + 0.37 + 0.97, delta=0.02)
        (t1, v1, b1, _, a1, _), (t2, v2, b2, _, a2, _) = vq["marks"]
        self.assertEqual((v1, b1, a1), ("快", True, True))        # 3.5 の前 10秒に 2.0〜、後 10秒に 4.0〜
        self.assertEqual((v2, b2, a2), ("分からない", True, True))

    def test_same_in_app(self):
        import check_app
        diffs, n = check_app.compare(self.path, check_app.build(), self.c)
        self.assertEqual(diffs, [])
        self.assertEqual(n, 5)

    def test_html(self):
        rows = review.segment_rows(self.a)
        self.assertEqual({r["指標名"] for r in rows}, {"声が出た"})
        self.assertTrue(all(r["ピークのz"] == "" for r in rows))


class VoiceCheckQualityTest(unittest.TestCase):
    """本人の声の見分けを見直すための記録の質（v1.7〜）"""

    def test_ratios(self):
        a = review.analyze(review.load(VOICE_FIXTURE), review.load_criteria(review.HERE / "criteria.json", []))
        v = review.quality(a, calm=False)["voice"]
        x, n = v["voiced_no_mouth"]
        self.assertGreater(n, 0)
        self.assertGreater(x, 0)          # 本人以外の声（口は動かない）が入っている
        self.assertLess(x, n)
        y, m = v["mouth_no_voice"]
        self.assertGreater(m, 0)
        self.assertLessEqual(y, m)


class VoiceCarryTest(unittest.TestCase):
    """途中まで集めた声の普段（v1.7〜）：セッションごとに足しても、まとめて集めたのと同じ平均・標準偏差になり、14日で捨てる"""

    def test_swift(self):
        import shutil
        import subprocess
        if not shutil.which("swiftc"):
            self.skipTest("swiftc がありません")
        app = review.HERE.parent / "ios"
        src = [app / "AbilityCam" / n for n in ("Baseline.swift", "DiffEngine.swift", "Pitch.swift")] + [app / "Tools" / "VoiceCarryCheck" / "main.swift"]
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / "voicecarry"
            subprocess.run(["swiftc", "-o", str(exe), *map(str, src)], check=True, capture_output=True)
            out = subprocess.run([str(exe)], capture_output=True, text=True)
        self.assertEqual(out.stdout.strip(), "OK", out.stdout)

    def test_criteria(self):
        import re
        c = review.load_criteria(review.HERE / "criteria.json", [])
        src = (review.HERE.parent / "ios" / "AbilityCam" / "DiffEngine.swift").read_text(encoding="utf-8")
        val = lambda name: float(re.search(rf"static let {name} = ([\d.]+)", src).group(1))
        self.assertEqual(val("voiceBaselineMaxAgeDays"), c["voice_baseline"]["max_age_days"])
        self.assertEqual(val("voiceOnMinS"), c["voice_on"]["min_s"])
        self.assertEqual(val("voiceOnGapS"), c["voice_on"]["gap_s"])


class VoiceCarryReportTest(unittest.TestCase):
    def test_baseline_row_text(self):
        b = {"type": "baseline", "t_ms": 1_800_000_000_000, "started_ms": 1_799_500_000_000, "part": "voice",
             "voice_valid_s": 10.0, "voice_sessions": 3, "voice_days": 2, "voice_carried_s": 7.4, "target_s": 10.0, "metrics": {}}
        cond = review.baseline_time_row(b)[-1]
        self.assertIn("3回のセッション・2日にまたがって集めた", cond)
        self.assertIn("前のセッションまでの分 7.4秒", cond)


class DirectionTest(unittest.TestCase):
    """顔の向きの左右（v1.7.1〜）：direction_version 2 の記録は本人から見た右・左のまま、無い記録は入れ替えて読む（アプリのリプレイと同じ）"""

    def write(self, d, version):
        import json
        lines = FIXTURE.read_text(encoding="utf-8").splitlines()
        h = json.loads(lines[0])
        if version:
            h["direction_version"] = version
        p = Path(d) / f"dir{version}.jsonl"
        p.write_text("\n".join([json.dumps(h, ensure_ascii=False)] + lines[1:]) + "\n", encoding="utf-8")
        return p

    def test_old_is_swapped_new_is_not(self):
        with tempfile.TemporaryDirectory() as d:
            old, new = review.load(self.write(d, None)), review.load(self.write(d, 2))
        self.assertTrue(old.direction_flipped)
        self.assertFalse(new.direction_flipped)
        self.assertTrue(np.allclose(np.nan_to_num(old.yaw), -np.nan_to_num(new.yaw)))
        ov = [e["value"] for e in review.head_events(old)]
        nv = [e["value"] for e in review.head_events(new)]
        self.assertEqual(nv[0], "右へ")
        self.assertEqual(ov[0], "左へ")
        self.assertEqual(ov, [review.swap_sides(v) for v in nv])
        self.assertEqual(review.head_events(old)[0]["head"], "left")

    def test_swap_sides(self):
        self.assertEqual(review.swap_sides("見えなくなった（直前は右 40°）"), "見えなくなった（直前は左 40°）")
        self.assertEqual(review.swap_sides("正面に戻った"), "正面に戻った")

    def test_same_in_replay(self):
        import json
        import check_app
        exe = check_app.build()
        with tempfile.TemporaryDirectory() as d:
            for v in (None, 2):
                p = self.write(d, v)
                out = __import__("subprocess").run([str(exe), "--heads", str(p)], check=True, capture_output=True, text=True).stdout
                rows = [json.loads(x) for x in out.splitlines() if x.strip()]
                texts = [r["text"] for r in rows if r["kind"] == "head_text"]
                rec = review.load(p)
                want = [f"顔の向き：{e['value']}（本人から見て）" for e in review.head_events(rec)]
                self.assertEqual(texts, want)
                runs = [r["value"] for r in rows if r["kind"] == "head"]
                states, _ = review.head_states(rec.t, rec.face, rec.yaw)
                seq = [s for i, s in enumerate(states) if s is not None and (i == 0 or s != states[i - 1])]
                self.assertEqual([x for i, x in enumerate(runs) if i == 0 or x != runs[i - 1]], [s for s in seq if s != "unknown"])

    def test_app_constant(self):
        import re
        src = (review.HERE.parent / "ios" / "AbilityCam" / "HeadTurn.swift").read_text(encoding="utf-8")
        self.assertEqual(int(re.search(r"static let version = (\d+)", src).group(1)), review.DIRECTION_VERSION)


def _pose_record(path, direction_version=2, with_pose=True):
    """顔の向きの確かめ用の作り物の記録（v1.8〜）。普段は 0〜20秒（yaw 0±2°、pitch・roll 0±1°）
      25–32 頭を右へ 15° 傾ける（本人から見て）→ いつもより右に傾いていた 7秒
      35–38 左へ 15° 向く                       → 3秒なので出さない
      40–44 右へ 30° 向く（0.5秒で 30° 変わる） → 急な向きの変化 2回（向いたとき・戻ったとき）
    場面：24 食事 → 33 なし。印：28 不快"""
    import json
    import math
    t0 = 1_800_000_000_000
    h = {"schema": "ability-cam.ios.v0.2", "started_at_ms": t0, "camera": "wide"}
    if direction_version:
        h["direction_version"] = direction_version
    lines = [json.dumps(h)]
    for k in range(60 * 30):
        s = k / 30
        yaw = 2 * math.sin(s * 1.3)
        pitch = math.sin(s * 0.7)
        roll = math.sin(s * 0.9)
        if 25 <= s < 32:
            roll = 15
        if 35 <= s < 38:
            yaw = -15
        if 40 <= s < 44:
            yaw = 30
        sign = 1 if direction_version == 2 else -1   # 古い記録は映像で見た右・左で書いてある
        lines.append(json.dumps({"type": "frame", "t_ms": t0 + round(s * 1000), "face": True, "bs": {"jawOpen": 0.1},
                                 "yaw_deg": round(sign * yaw, 1), "pitch_deg": round(pitch, 1), "roll_deg": round(sign * roll, 1)}))
    b = {"type": "baseline", "t_ms": t0 + 20000, "started_ms": t0, "valid_s": 15, "part": "face", "target_s": 15,
         "metrics": {"jaw_open": {"n": 100, "mean": 0.1, "std": 0.01, "insufficient": False}}}
    if with_pose:
        b["pose"] = {"yaw_deg": {"n": 400, "mean": 0.0, "std": 1.4, "insufficient": False},
                     "pitch_deg": {"n": 400, "mean": 0.0, "std": 0.7, "insufficient": False},
                     "roll_deg": {"n": 400, "mean": 0.0, "std": 0.7, "insufficient": False}}
    lines.append(json.dumps(b))
    for ms, kind, v in ((24000, "scene", "食事"), (33000, "scene", "なし"), (28000, "mark", "不快")):
        lines.append(json.dumps({"type": "event", "t_ms": t0 + ms, "kind": kind, "value": v}, ensure_ascii=False))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class PoseTest(unittest.TestCase):
    """顔の向きの普段と特徴（v1.8〜、振り返りレポートだけ）"""

    def analyze(self, **kw):
        import pose
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "pose.jsonl"
            _pose_record(p, **kw)
            a = review.analyze(review.load(p), review.load_criteria(review.HERE / "criteria.json", []))
            return a, pose.analyze_pose(a)

    def test_deviations(self):
        _, p = self.analyze()
        devs = p["deviations"]
        self.assertEqual([(d.key, d.sign) for d in devs], [("roll_deg", 1)])   # 3秒の左は出さない。30° の右は 4秒なので出さない
        self.assertAlmostEqual(devs[0].seconds, 7, delta=0.3)
        self.assertIn("いつもより右に傾いていた", devs[0].text())
        self.assertTrue(devs[0].text().endswith("（本人から見て）"))

    def test_floor(self):
        # 普段の標準偏差 0.7° でも下限 5° をかけるので、いつもの範囲は ±10°（±1° の揺れでは出さない）
        _, p = self.analyze()
        self.assertFalse(any(d.key == "pitch_deg" for d in p["deviations"]))

    def test_quick_and_dwell(self):
        _, p = self.analyze()
        self.assertEqual(len(p["quick"]), 2)
        self.assertEqual({k for _, _, k in p["quick"]}, {"yaw_deg"})
        self.assertEqual(p["changes"], 0)                 # 35° を超えないので、顔の向きの段はずっと正面
        self.assertEqual(p["dwell"]["n"], 1)

    def test_scene_and_marks(self):
        _, p = self.analyze()
        scenes = dict(p["by_scene"])
        self.assertAlmostEqual(scenes["食事"]["seconds"], 9, delta=0.2)
        self.assertGreater(scenes["食事"]["mean"]["roll_deg"], 10)
        (m_t, v, before, after), = p["by_mark"]
        self.assertEqual(v, "不快")
        self.assertAlmostEqual(after["mean"]["roll_deg"], 15 * 4 / 10, delta=0.5)   # 28〜38 のうち 28〜32 が 15°
        self.assertEqual(before["ratio"]["front"], 1.0)

    def test_old_record_is_swapped(self):
        _, p = self.analyze(direction_version=None)
        self.assertEqual([(d.key, d.sign) for d in p["deviations"]], [("roll_deg", 1)])   # 映像で見た向きで書いてあっても、本人から見て右

    def test_recount_without_pose(self):
        _, p = self.analyze(with_pose=False)
        (b, st, src), = p["baselines"]
        self.assertIn("数え直した", src)
        self.assertLess(abs(st["yaw_deg"]["mean"]), 1)
        self.assertGreater(st["yaw_deg"]["n"], 100)

    def test_html_words(self):
        import pose
        a, _ = self.analyze()
        doc = pose.html_section(a, __import__("html").escape)
        self.assertIn("いつもより右に傾いていた", doc)
        for bad in ("そむけ", "嫌が", "疲れ"):
            self.assertNotIn(bad, doc)

    def test_rebuilt_baseline_has_pose(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "pose.jsonl"
            _pose_record(p)
            rows = review.rebuild_baselines(review.load(p), 10.0, review.load_criteria(review.HERE / "criteria.json", []))
        self.assertIn("pose", rows[0])
        self.assertLess(abs(rows[0]["pose"]["roll_deg"]["mean"]), 1)


def _voice_mix_record(path, saved_pitch=None, two_faces=False, length=34.0):
    """本人の声の見分け（v1.9〜）の確かめ用。2026-10-28 20:25 の記録で起きたことを作り物で：
      0–10・20–22・32– 黙っている（口は小さく動く：直近0.3秒の変化 0.1 くらい）
      10–20 本人が話す（f0 150Hz 前後、口の開きと声の大きさが同じ 4Hz で揺れる）
      22–32 ほかの人が話す（f0 320Hz、声は 3.3Hz で揺れる。本人の口は黙っているときと同じ小さな動き）
    two_faces なら、ほかの人の顔も映っていて、その口が声と同じ 3.3Hz で揺れる（other_jaw_open）"""
    import json
    import math
    t0 = 1_800_000_000_000
    lines = [json.dumps({"schema": "ability-cam.ios.v0.2", "started_at_ms": t0, "camera": "front", "direction_version": 2})]
    if saved_pitch:
        lines.append(json.dumps({"type": "baseline", "t_ms": t0 + 500, "source": "saved", "compared": True, "part": "voice",
                                 "metrics": {"f0_hz": {"n": 300, "mean": saved_pitch[0], "std": saved_pitch[1], "median": saved_pitch[0],
                                                       "iqr": round(saved_pitch[1] * 1.349, 1), "insufficient": False},
                                             "rms_db": {"n": 300, "mean": -45.0, "std": 4.0, "insufficient": False}}}))
    for k in range(int(length * 30)):
        s = k / 30
        idle = 0.05 + 0.05 * math.sin(2 * math.pi * 1.7 * s) + 0.03 * math.sin(2 * math.pi * 5.3 * s + 1)
        jaw, rms, f0, other = idle, -70.0 + 2 * math.sin(2 * math.pi * 0.9 * s), None, None
        if 10 <= s < 20:
            jaw = 0.15 + 0.08 * math.sin(2 * math.pi * 4 * s)
            rms = -45 + 6 * math.sin(2 * math.pi * 4 * s) + 1.5 * math.sin(2 * math.pi * 0.7 * s)
            f0 = 150 + 20 * math.sin(2 * math.pi * 0.5 * s)
        if 22 <= s < 32:
            rms = -40 + 6 * math.sin(2 * math.pi * 3.3 * s)
            f0 = 320.0
        if two_faces:
            other = 0.05 if not (22 <= s < 32) else 0.15 + 0.08 * math.sin(2 * math.pi * 3.3 * s)
        o = {"type": "frame", "t_ms": t0 + round(s * 1000), "face": True, "yaw_deg": 0.0,
             "bs": {"jawOpen": round(jaw, 3), "mouthFunnel": round(idle, 3)}, "rms_db": round(rms, 1)}
        if f0 is not None:
            o["f0_hz"] = round(f0, 1)
        if other is not None:
            o["other_jaw_open"] = round(other, 3)
        lines.append(json.dumps(o))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class VoiceSyncTest(unittest.TestCase):
    """本人の声の見分け（v1.9〜）：口の動きと声のタイミング・声の高さの範囲"""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        d = Path(cls.dir.name)
        cls.paths = {}
        for name, kw in (("plain", {}), ("pitch", {"saved_pitch": (150.0, 15.0)}), ("two", {"two_faces": True})):
            cls.paths[name] = d / f"{name}.jsonl"
            _voice_mix_record(cls.paths[name], **kw)
        cls.c = review.load_criteria(review.HERE / "criteria.json", [])

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def details(self, name, c=None):
        rec = review.load(self.paths[name])
        c = c or self.c
        return rec, review.voice_self_details(rec, c, review.face_valid(rec, c), use_recorded=False)

    def rate(self, rec, d, a, b):
        sel = (rec.t - rec.t[0] >= a) & (rec.t - rec.t[0] < b) & np.isfinite(d.values)
        return float((d.values[sel] == 1).mean())

    def test_mouth_only_lets_other_voice_in(self):
        import voice_check
        rec, d = self.details("plain", voice_check.variant(self.c, sync=False, pitch=False))
        self.assertGreater(self.rate(rec, d, 22, 32), 0.9)    # v1.8 までの決まりでは、ほかの人の声も本人の声になる

    def test_timing_is_not_used_by_default(self):
        rec, d = self.details("plain")
        self.assertGreater(self.rate(rec, d, 22, 32), 0.9)    # v1.9.1〜：タイミングは判定に使わない
        self.assertNotIn("timing", set(d.reason))
        self.assertTrue(np.isfinite(d.corr[np.isfinite(d.values)]).any())   # 相関は求めてレポートに出す

    def test_timing(self):
        import voice_check
        rec, d = self.details("plain", voice_check.variant(self.c, sync=True, pitch=False))
        self.assertGreater(self.rate(rec, d, 10.5, 20), 0.95)  # 本人の声は本人
        self.assertLess(self.rate(rec, d, 22, 32), 0.05)       # ほかの人の声は本人と言わない
        other = [d.reason[i] for i in range(len(rec.t)) if 22 <= rec.t[i] - rec.t[0] < 32 and d.values[i] == 0]
        self.assertEqual(set(other), {"timing"})

    def test_pitch_range(self):
        rec, d = self.details("pitch")
        other = {d.reason[i] for i in range(len(rec.t)) if 22 <= rec.t[i] - rec.t[0] < 32}
        self.assertEqual(other, {"pitch"})                     # 保存した声の普段（中央値 150 ± 2.5×20Hz）の外
        self.assertGreater(self.rate(rec, d, 10.5, 20), 0.95)  # 本人の声（130〜170Hz）は範囲の中

    def test_two_faces_match(self):
        import voice_check
        rec, d = self.details("two", voice_check.variant(self.c, sync=True, pitch=False))
        rel = rec.t - rec.t[0]
        m_other = [d.match[i] for i in range(len(rec.t)) if 23 <= rel[i] < 32]
        m_self = [d.match[i] for i in range(len(rec.t)) if 11 <= rel[i] < 20]
        self.assertGreater(m_other.count("other") / len(m_other), 0.9)
        self.assertGreater(m_self.count("self") / len(m_self), 0.9)
        self.assertLess(self.rate(rec, d, 22, 32), 0.05)       # 判定は本人として選んだ顔で（ほかの人の声は本人と言わない）

    def test_same_in_app(self):
        import check_app
        exe = check_app.build()
        for p in self.paths.values():
            diffs, _ = check_app.compare(p, exe, self.c)
            self.assertEqual(diffs, [], p.name)
            self.assertEqual(check_app.compare_voice(p, exe, self.c), [], p.name)

    def test_voice_check_tool(self):
        import io
        import contextlib
        import voice_check
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = voice_check.main([str(self.paths["plain"]), "--self", "10-20", "--other", "22-32"])
        self.assertEqual(code, 0)
        rows = {ln.split("\t")[0]: ln.split("\t") for ln in buf.getvalue().splitlines()[2:]}
        self.assertEqual(rows["口の動きだけ（v1.8 まで）"][2], "100%")
        self.assertLess(int(rows["両方（v1.9）"][2].rstrip("%")), 10)   # ずれを探すので、たまたま合うことがある（v1.9.1〜）

    def test_criteria_match_app(self):
        import re
        src = (review.HERE.parent / "ios" / "AbilityCam" / "DiffEngine.swift").read_text(encoding="utf-8")
        val = lambda name: float(re.search(rf"static let {name} = ([\d.]+)", src).group(1))
        vc = self.c["voice_self"]
        self.assertEqual(val("syncWindowS"), vc["sync"]["window_s"])
        self.assertEqual(val("syncMinFrames"), vc["sync"]["min_frames"])
        self.assertEqual(val("syncMinCorr"), vc["sync"]["min_corr"])
        self.assertEqual(val("pitchRangeK"), vc["pitch_range"]["k_spread"])
        self.assertEqual(val("pitchSpreadFloorHz"), vc["pitch_range"]["spread_floor_hz"])
        self.assertEqual(val("voiceSpreadWarnHz"), vc["pitch_range"]["warn_spread_hz"])
        self.assertIn(f"static let syncEnabled = {'true' if vc['sync']['enabled'] else 'false'}", src)
        self.assertIn(f'static let syncKey = "{vc["sync"]["key"]}"', src)


class RobustPitchTest(unittest.TestCase):
    """声の高さの範囲（v1.9.1〜）：中央値と四分位範囲。外れ値（高い声・低い声）に強い"""

    def test_outliers(self):
        rng = np.random.default_rng(3)
        x = list(150 + 10 * rng.standard_normal(300)) + [400.0] * 30 + [80.0] * 30
        med, iqr = review.robust_pitch(x)
        self.assertLess(abs(med - 150), 5)
        self.assertLess(review.spread_of(iqr), 18)          # 平均・標準偏差なら 60Hz を超える
        self.assertGreater(float(np.std(x, ddof=1)), 60)

    def test_old_saved_voice_is_not_used(self):
        """中央値の無い保存した声の普段（v1.9 まで）は、声の高さの範囲に使わない"""
        import json
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "v.jsonl"
            _voice_mix_record(p, saved_pitch=(150.0, 15.0))
            lines = p.read_text(encoding="utf-8").splitlines()
            row = json.loads(lines[1])
            del row["metrics"]["f0_hz"]["median"], row["metrics"]["f0_hz"]["iqr"]
            lines[1] = json.dumps(row)
            p.write_text("\n".join(lines) + "\n", encoding="utf-8")
            rec = review.load(p)
        self.assertEqual(review.pitch_ranges(rec), [])

    def test_same_quantile_as_app(self):
        import shutil
        import subprocess
        if not shutil.which("swiftc"):
            self.skipTest("swiftc がありません")
        app = review.HERE.parent / "ios"
        src = [app / "AbilityCam" / n for n in ("Baseline.swift", "DiffEngine.swift", "Pitch.swift")] + [app / "Tools" / "VoiceCarryCheck" / "main.swift"]
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / "voicecarry"
            subprocess.run(["swiftc", "-o", str(exe), *map(str, src)], check=True, capture_output=True)
            out = subprocess.run([str(exe), "--pitch", "151.2", "149.8", "400", "80", "155.5", "147.1", "152.0"],
                                 capture_output=True, text=True).stdout.split()
        self.assertEqual([float(v) for v in out], list(review.robust_pitch([151.2, 149.8, 400, 80, 155.5, 147.1, 152.0])))

    def test_wide_saved_voice_note(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "w.jsonl"
            _voice_mix_record(p, saved_pitch=(151.0, 61.0))
            c = review.load_criteria(review.HERE / "criteria.json", [])
            q = review.quality(review.analyze(review.load(p), c), calm=False)
        (_, sp, robust), = q["voice"]["saved_spread"]
        self.assertTrue(robust)
        self.assertGreater(sp, c["voice_self"]["pitch_range"]["warn_spread_hz"])


class VoiceCheckSpansTest(unittest.TestCase):
    def test_comma_spans(self):
        import voice_check
        self.assertEqual(voice_check.spans(["35-38,42-51", "60-61"]), ["35-38", "42-51", "60-61"])
        import io
        import contextlib
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "v.jsonl"
            _voice_mix_record(p)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = voice_check.main([str(p), "--self", "10-15,15-20", "--other", "22-27,27-32", "--self-baseline"])
        self.assertEqual(code, 0)
        self.assertIn("本人の時間の声の高さ：中央値", buf.getvalue())


class AudioLagTest(unittest.TestCase):
    """映像のコマごとの声の大きさ（type: "audio"、v1.9.1〜）で、口の開きとのずれ（±0.2秒）を探して相関を取る"""

    def write(self, d, lag):
        import json
        import math
        t0 = 1_800_000_000_000
        lines = [json.dumps({"schema": "ability-cam.ios.v0.2", "started_at_ms": t0, "direction_version": 2})]
        for k in range(10 * 30):
            s = k / 30
            jaw = 0.15 + 0.08 * math.sin(2 * math.pi * 2.5 * s)
            lines.append(json.dumps({"type": "frame", "t_ms": t0 + round(s * 1000), "face": True, "yaw_deg": 0.0,
                                     "bs": {"jawOpen": round(jaw, 3), "mouthFunnel": round(jaw, 3)}, "rms_db": -45.0, "f0_hz": 150.0}))
        for b in range(100):   # 0.1秒ごとの塊を、1/30 秒ずつ3つに区切る。声は口より lag 秒あとに大きくなる
            start = b * 0.1
            db = [round(-45 + 6 * math.sin(2 * math.pi * 2.5 * (start + k / 30 - lag)), 1) for k in range(3)]
            lines.append(json.dumps({"type": "audio", "t_ms": t0 + round(start * 1000), "block_ms": 33.33, "rms_db": db}))
        p = Path(d) / "lag.jsonl"
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return p

    def test_lag_found(self):
        c = review.load_criteria(review.HERE / "criteria.json", [])
        with tempfile.TemporaryDirectory() as d:
            rec = review.load(self.write(d, 0.13))
        self.assertIsNotNone(rec.audio_t)
        corr, _, lag = review.sync_corr(rec, c["voice_self"])
        self.assertGreater(np.nanmedian(corr[60:]), 0.9)
        self.assertAlmostEqual(float(np.nanmedian(lag[60:])), 0.133, delta=0.04)
        c0 = review.load_criteria(review.HERE / "criteria.json", [])
        c0["voice_self"]["sync"]["lag_s"] = 0
        corr0, _, _ = review.sync_corr(rec, c0["voice_self"])
        self.assertLess(np.nanmedian(corr0[60:]), np.nanmedian(corr[60:]) - 0.1)   # ずれを探さないと低い


class VoiceRestartTest(unittest.TestCase):
    """声だけ取り直す（baseline_restart、part: "voice"、v1.9.2〜）：声の普段だけ消え、表情の普段はそのまま。アプリのリプレイと同じ"""

    def write(self, d, part):
        import json
        lines = VOICE_FIXTURE.read_text(encoding="utf-8").splitlines()
        e = {"type": "event", "t_ms": review.load(VOICE_FIXTURE).t[0] * 1000 + 45000, "kind": "baseline_restart", "value": None}
        if part:
            e["part"] = part
        e["t_ms"] = int(e["t_ms"])
        p = Path(d) / f"restart_{part}.jsonl"
        p.write_text("\n".join(lines + [json.dumps(e)]) + "\n", encoding="utf-8")
        return p

    def test_voice_only(self):
        import check_app
        c = review.load_criteria(review.HERE / "criteria.json", [])
        with tempfile.TemporaryDirectory() as d:
            p = self.write(d, "voice")
            a = review.analyze(review.load(p), c)
            kinds = [s.metric for s in a.segments]
            self.assertNotIn("f0_hz", kinds)            # 50秒の声の高さ・80秒の声の大きさは、声の普段が無いので出ない
            self.assertNotIn("rms_db", kinds)
            self.assertTrue((a.bidx[-10:] >= 0).all())  # 表情の普段はそのまま
            self.assertTrue((a.vbidx[-10:] < 0).all())
            self.assertIn(review.VOICE_ON, kinds)       # 声が出たは普段と関係なく出る
            diffs, _ = check_app.compare(p, check_app.build(), c)
            self.assertEqual(diffs, [])

    def test_face_only_keeps_voice(self):
        c = review.load_criteria(review.HERE / "criteria.json", [])
        with tempfile.TemporaryDirectory() as d:
            a = review.analyze(review.load(self.write(d, "face")), c)
        self.assertTrue((a.vbidx[-10:] >= 0).all())
        self.assertTrue((a.bidx[-10:] < 0).all())
        self.assertIn("rms_db", [s.metric for s in a.segments])


class PitchRangeRestartTest(unittest.TestCase):
    """声も取り直したら（baseline_restart、part が face でない、v1.9.3〜）、そこから声の高さの範囲を外す（アプリと同じ）"""

    def test_cleared(self):
        import json
        import check_app
        c = review.load_criteria(review.HERE / "criteria.json", [])
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.jsonl"
            _voice_mix_record(p, saved_pitch=(150.0, 15.0))
            t0 = review.load(p).t[0]
            for part, want in (("voice", False), ("face", True), (None, False)):
                lines = p.read_text(encoding="utf-8").splitlines()
                e = {"type": "event", "t_ms": int(t0 * 1000) + 21000, "kind": "baseline_restart", "value": None}
                if part:
                    e["part"] = part
                q = Path(d) / f"r_{part}.jsonl"
                q.write_text("\n".join(lines + [json.dumps(e)]) + "\n", encoding="utf-8")
                rec = review.load(q)
                det = review.voice_self_details(rec, c, review.face_valid(rec, c), use_recorded=False)
                pitch = any(det.reason[i] == "pitch" for i in range(len(rec.t)) if 22 <= rec.t[i] - t0 < 32)
                self.assertEqual(pitch, want, part)
                self.assertEqual(check_app.compare_voice(q, check_app.build(), c), [], part)


class PitchRangeAfterRetakeTest(unittest.TestCase):
    """声の普段を集め終えたら（v1.9.4〜）、アプリは voice_pitch_range の event の時刻から、その人の保存した声の普段の範囲を使い始める。
    声だけ取り直して保存し直したとき（新しい範囲）・両方取り直して置き換えなかったとき（前の範囲に戻す）。レポートとリプレイも同じ"""

    def write(self, d, restart_part, event):
        import json
        p = Path(d) / f"retake_{restart_part}_{bool(event)}.jsonl"
        _voice_mix_record(p, saved_pitch=(150.0, 15.0))
        lines = p.read_text(encoding="utf-8").splitlines()
        t0 = json.loads(lines[0])["started_at_ms"]
        e = {"type": "event", "t_ms": t0 + 5000, "kind": "baseline_restart", "value": None}
        if restart_part:
            e["part"] = restart_part
        lines.append(json.dumps(e))
        # 本人の声が10秒たまった（10〜20秒）ところで、今日の声の普段の行と、使い始めた範囲
        lines.append(json.dumps({"type": "baseline", "t_ms": t0 + 20500, "source": "today", "compared": True, "part": "voice",
                                 "metrics": {"f0_hz": {"n": 300, "mean": 152.0, "std": 14.0, "median": 152.0, "iqr": 24.0, "insufficient": False},
                                             "rms_db": {"n": 300, "mean": -45.0, "std": 4.0, "insufficient": False}}}))
        if event:
            lines.append(json.dumps({"type": "event", "t_ms": t0 + 20500, "kind": "voice_pitch_range", "value": None, **event}))
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return p

    def reasons(self, p, a, b):
        c = review.load_criteria(review.HERE / "criteria.json", [])
        rec = review.load(p)
        d = review.voice_self_details(rec, c, review.face_valid(rec, c), use_recorded=False)
        t0 = rec.t[0]
        return {d.reason[i] for i in range(len(rec.t)) if a <= rec.t[i] - t0 < b and d.values[i] == d.values[i]}

    def test_cases(self):
        import check_app
        c = review.load_criteria(review.HERE / "criteria.json", [])
        exe = check_app.build()
        with tempfile.TemporaryDirectory() as d:
            for part, event in (("voice", {"median": 152.0, "iqr": 24.0}),   # 声だけ取り直して保存し直した：新しい範囲
                                (None, {"median": 150.0, "iqr": 20.2}),       # 両方取り直して置き換えなかった：前の範囲に戻す
                                ("voice", None)):                             # v1.9.3 まで（event が無い）：範囲は外れたまま
                p = self.write(d, part, event)
                self.assertNotIn("pitch", self.reasons(p, 10.5, 20))          # 集めている間は範囲を使わない
                self.assertEqual("pitch" in self.reasons(p, 22, 32), event is not None, (part, event))
                self.assertEqual(check_app.compare_voice(p, exe, c), [], (part, event))
                diffs, _ = check_app.compare(p, exe, c)
                self.assertEqual(diffs, [], (part, event))
