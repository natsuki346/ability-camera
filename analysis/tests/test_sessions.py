"""これまでの記録（sessions.jsonl）と、記録のファイルからの要約を確かめる。python -m unittest discover -s tests（analysis/ で）"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import review  # noqa: E402
import sessions  # noqa: E402

T0 = 1_790_000_000_000


def make_record(path: Path, broken_tail=False):
    """10秒：最初の4秒は正面の顔、次の2秒は横向き（yaw 50°）、次の2秒は顔なし、3秒空いて、最後の2秒は正面"""
    rows = [{"schema": "ability-cam.ios.v0.2", "started_at_ms": T0}]
    def frames(t0, t1, face, yaw):
        t = t0
        while t < t1:
            r = {"type": "frame", "t_ms": T0 + t, "face": face, "bs": {} if face else None}
            if face:
                r["yaw_deg"] = yaw
            rows.append(r)
            t += 100
    frames(0, 4000, True, 5.0)
    frames(4000, 6000, True, 50.0)
    frames(6000, 8000, False, None)
    frames(11000, 13000, True, -10.0)
    ev = lambda t, kind, value: {"type": "event", "t_ms": T0 + t, "kind": kind, "value": value}
    rows += [ev(1000, "scene", "食事"), ev(2000, "scene", "なし"), ev(2500, "mark", "分からない"),
             ev(3000, "change", ["brow_down_up"]), ev(3500, "change", ["brow_down_up", "rms_db_up"]),
             ev(3600, "change", []), ev(3700, "change", ["brow_down_up"]),
             ev(3800, "baseline_restart", None), ev(3900, "change", ["brow_down_up"])]
    rows.sort(key=lambda r: r.get("t_ms", -1))
    text = "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n"
    if broken_tail:
        text += '{"type": "frame", "t_ms": 17900'   # 途中で終了された最後の行
    path.write_text(text, encoding="utf-8")


class SummarizeTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())

    def test_counts_like_the_app(self):
        p = self.dir / "ability-cam-20260101-000000.jsonl"
        make_record(p, broken_tail=True)
        s = sessions.summarize_record(p)
        # 0〜4秒の正面＋4〜6秒の横向き＋6〜8秒の顔なし（最後のコマ 7.9 まで）＋空き3秒は1秒に切る＋最後の1.9秒
        self.assertAlmostEqual(s["duration_s"], 7.9 + 1.0 + 1.9, places=1)
        self.assertAlmostEqual(s["face_s"], 6.0 + 1.9, places=1)
        self.assertAlmostEqual(s["facing_s"], 4.0 + 1.9, places=1)
        self.assertEqual(s["segments"], 4)   # brow / rms / （消えて）brow / （取り直し後）brow
        self.assertEqual(s["marks"], 1)
        self.assertEqual(s["scenes"], 1)     # 「なし」に戻したのは数えない
        self.assertEqual(s["started_ms"], T0)
        self.assertEqual(s["frames"], 100)

    def test_report_lists_sessions_and_unsummarized(self):
        done = self.dir / "ability-cam-20260101-000000.jsonl"
        left = self.dir / "ability-cam-20260102-000000.jsonl"
        make_record(done)
        make_record(left, broken_tail=True)
        s = sessions.summarize_record(done)
        s.update({"recovered": True, "schema": "ability-cam.session.v1"})
        (self.dir / "sessions.jsonl").write_text(json.dumps(s, ensure_ascii=False) + "\n壊れた行\n", encoding="utf-8")

        self.assertEqual(sessions.main([str(self.dir)]), 0)
        doc = (self.dir / "sessions.html").read_text(encoding="utf-8")
        self.assertIn(done.name, doc)
        self.assertIn("要約のない記録", doc)
        self.assertIn(left.name, doc)
        self.assertIn("次に開いたときに整理", doc)
        for word in ["不快", "痛み", "異常", "検知", "緊急", "危険", "監視", "見守り", "患者"]:
            self.assertNotIn(word, doc)

    def test_newest_first_and_last_summary_wins(self):
        p = self.dir / "sessions.jsonl"
        rows = [{"type": "session_summary", "file": "a.jsonl", "started_ms": 1, "segments": 1},
                {"type": "session_summary", "file": "b.jsonl", "started_ms": 2},
                {"type": "session_summary", "file": "a.jsonl", "started_ms": 1, "segments": 5}]
        p.write_text("\n".join(json.dumps(r) for r in rows), encoding="utf-8")
        got = sessions.load_sessions(p)
        self.assertEqual([r["file"] for r in got], ["b.jsonl", "a.jsonl"])
        self.assertEqual(got[1]["segments"], 5)

    def test_review_refuses_sessions_file(self):
        p = self.dir / "sessions.jsonl"
        p.write_text(json.dumps({"type": "session_summary", "file": "a.jsonl"}) + "\n", encoding="utf-8")
        self.assertEqual(review.main([str(p)]), 2)


if __name__ == "__main__":
    unittest.main()
