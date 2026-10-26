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
        self.assertIn("不快", first["前後の印"])
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
            for word in ["笑顔", "痛み", "怒り"]:
                self.assertNotIn(word, html_text)


if __name__ == "__main__":
    unittest.main()
