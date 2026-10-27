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
