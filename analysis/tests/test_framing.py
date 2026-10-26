"""映り方チェックのレポートを確かめる。python -m unittest discover -s tests（analysis/ で）"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import framing  # noqa: E402

T0 = 1_790_000_000_000


def check(i, minutes, face_ratio, facing_ratio, **kw):
    d = minutes * 60
    r = {"type": "framing_check", "schema": "ability-cam.framing.v1", "id": f"c{i}",
         "t_ms": T0 + i * 3_600_000 + d * 1000, "started_ms": T0 + i * 3_600_000, "ended_ms": T0 + i * 3_600_000 + d * 1000,
         "duration_s": d, "face_s": d * face_ratio, "face_ratio": face_ratio,
         "facing_s": d * facing_ratio, "facing_ratio": facing_ratio, "yaw_limit_deg": 35,
         "longest_no_face_s": 12.3, "bin_s": 10, "bin_face_ratio": [1.0, 0.5, None, 0.0],
         "fps_mean": 29.5, "mesh_lag_ms_median": 80, "ended_by": "button", "device": "iPhone", "ios": "18.0"}
    r.update(kw)
    return r


def note(i, t, text):
    return {"type": "framing_note", "id": f"c{i}", "t_ms": T0 + t, "note": text}


class FramingTest(unittest.TestCase):
    def write(self, rows):
        d = Path(tempfile.mkdtemp())
        p = d / "framing-checks.jsonl"
        p.write_text("\n".join(json.dumps(r, ensure_ascii=False) if isinstance(r, dict) else r for r in rows) + "\n",
                     encoding="utf-8")
        return p

    def test_latest_note_wins_and_duplicates_dropped(self):
        p = self.write([check(1, 2, 0.5, 0.4), note(1, 5, "胸ポケット"), note(1, 9, "胸ポケット・姉"),
                        check(1, 2, 0.5, 0.4), "壊れた行"])
        cs = framing.load([p])
        self.assertEqual(len(cs), 1)
        self.assertEqual(cs[0].note, "胸ポケット・姉")

    def test_groups_weight_by_time(self):
        # 同じメモ：1分で 100% と 3分で 0% → 時間で重み付けして 25%
        p = self.write([check(1, 1, 1.0, 1.0), check(2, 3, 0.0, 0.0), check(3, 2, 0.6, 0.5),
                        note(1, 1, "首から下げる"), note(2, 1, "首から下げる")])
        g = {x["note"]: x for x in framing.groups(framing.load([p]))}
        self.assertAlmostEqual(g["首から下げる"]["face_ratio"], 0.25)
        self.assertEqual(g["首から下げる"]["n"], 2)
        self.assertAlmostEqual(g[""]["face_ratio"], 0.6)

    def test_html(self):
        p = self.write([check(1, 2, 0.75, 0.5), note(1, 1, "<b>食事</b>"), {"type": "frame", "t_ms": T0}])
        out = p.with_suffix(".html")
        self.assertEqual(framing.main([str(p)]), 0)
        doc = out.read_text(encoding="utf-8")
        self.assertIn("&lt;b&gt;食事&lt;/b&gt;", doc)          # メモはエスケープする
        self.assertIn("75%", doc)
        self.assertIn("<svg", doc)
        for word in ["不快", "痛み", "異常", "検知", "緊急", "危険", "監視", "見守り", "患者"]:
            self.assertNotIn(word, doc)
        for red in ["#f00", "#ff0000", "red"]:
            self.assertNotIn(f":{red}", doc.lower())

    def test_empty(self):
        p = self.write([])
        self.assertEqual(framing.main([str(p)]), 0)
        self.assertIn("ありません", p.with_suffix(".html").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
