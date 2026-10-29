#!/usr/bin/env python3
"""本人の声の登録（collect: voice_self）で、声のまとまりを数えたかを、記録の voice_self と speaker 行から決め直す（v1.10.3〜）。
前の決まり（v1.10.1〜v1.10.2、gate 1）と今の決まり（v1.10.3〜、gate 2。アプリの SpeakerSelfGate.decide と同じ）で、何個・何秒になるかを並べる。

  gate 1：まとまり全体（最大3秒）に voice_self: false が1つでもあれば数えない。数える分（終わりから min(長さ, 0.5秒)）に null があれば数えない（no_f0）。
          数える分がすべて true（1コマ以上）なら数える
  gate 2：数える分だけを見る。pitch 以外の理由の false があれば数えない（not_self）。true が1つ以上あれば数える。
          true が無く null があれば no_f0、pitch の false だけなら not_self
  参考（gate 2 で、数える分に null があれば数えない）も出す

アプリは映像のコマが届くのを待って決めるが（3秒待って来なければ no_frames）、ここでは記録にあるコマで決める。
登録の区間：speaker_enroll（collect: voice_self、無い記録では選んでいる人＝ヘッダの person_id の登録）から、次の speaker_enroll・final の行・記録の終わりまで。
数えた声が30秒たまって登録し終えたあとのまとまりも数える（決まりの違いを見るため）。

使い方：python enroll_check.py 記録.jsonl ...
"""
from __future__ import annotations

import bisect
import json
import sys
from collections import Counter
from pathlib import Path

HOP_S = 0.5


def load(path: Path) -> dict:
    header, frames, speaker, events = {}, [], [], []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            if n == 0 and "schema" in o:
                header = o
            elif o.get("type") == "speaker":
                speaker.append(o)
            elif o.get("type") == "event":
                events.append(o)
            elif o.get("type") == "frame" and "voice_self" in o:
                frames.append((int(o["t_ms"]), o["voice_self"], o.get("voice_self_reason")))
    frames.sort()
    return {"header": header, "frames": frames, "speaker": sorted(speaker, key=lambda o: o["t_ms"]),
            "events": sorted(events, key=lambda o: o["t_ms"])}


def _slice(frames: list, t0: int, t1: int) -> list:
    ts = [f[0] for f in frames]
    return frames[bisect.bisect_left(ts, t0):bisect.bisect_right(ts, t1)]


def gate1(frames: list, end: int, span_s: float) -> str:
    start = end - round(span_s * 1000)
    counted = end - round(min(span_s, HOP_S) * 1000)
    n, null = 0, False
    for t, v, _ in _slice(frames, start, end):
        if v is False:
            return "not_self"
        if t >= counted:
            if v is None:
                null = True
            else:
                n += 1
    return "no_f0" if null else "counted" if n else "no_frames"


def gate2(frames: list, end: int, span_s: float, null_blocks: bool = False) -> str:
    counted = end - round(min(span_s, HOP_S) * 1000)
    trues, null, any_ = 0, False, False
    for _, v, reason in _slice(frames, counted, end):
        any_ = True
        if v is True:
            trues += 1
        elif v is False:
            if reason != "pitch":
                return "not_self"
        else:
            null = True
    if null_blocks and null:
        return "no_f0"
    if trues:
        return "counted"
    return "no_f0" if null else "not_self" if any_ else "no_frames"


def windows(rec: dict) -> list[tuple[int, int, str | None]]:
    """本人の声の登録の区間 (始め, 終わり, person_id)"""
    end_all = max([f[0] for f in rec["frames"][-1:]] + [s["t_ms"] for s in rec["speaker"]] + [0])
    starts = [e for e in rec["events"] if e.get("kind") == "speaker_enroll"]
    out = []
    for i, e in enumerate(starts):
        self_ = e.get("collect") == "voice_self" or (e.get("collect") is None and e.get("person_id") == rec["header"].get("person_id"))
        if not self_:
            continue
        stop = starts[i + 1]["t_ms"] if i + 1 < len(starts) else end_all
        fin = [x["t_ms"] for x in rec["events"] if x.get("kind") == "speaker_enroll_progress" and x.get("final")
               and x.get("person_id") == e.get("person_id") and e["t_ms"] <= x["t_ms"] <= stop]
        out.append((e["t_ms"], min([stop] + fin), e.get("person_id")))
    return out


def check(rec: dict) -> list[dict]:
    rows = []
    for t0, t1, pid in windows(rec):
        sp = [s for s in rec["speaker"] if t0 <= s["t_ms"] <= t1]
        res = {"start_s": (t0 - rec["header"].get("started_at_ms", t0)) / 1000, "length_s": (t1 - t0) / 1000, "person_id": pid, "chunks": len(sp)}
        for name, fn in (("gate1", gate1), ("gate2", gate2), ("gate2_null_blocks", lambda f, e, s: gate2(f, e, s, True))):
            c, sec = Counter(), Counter()
            for s in sp:
                span = s.get("window_ms", 0) / 1000
                o = fn(rec["frames"], int(s["t_ms"]), span)
                c[o] += 1
                sec[o] += min(span, HOP_S)
            res[name] = {"count": dict(c), "seconds": {k: round(v, 1) for k, v in sec.items()}}
        rows.append(res)
    return rows


def main(argv=None) -> int:
    args = [Path(a) for a in (argv if argv is not None else sys.argv[1:])]
    if not args:
        print(__doc__)
        return 2
    for p in args:
        rows = check(load(p))
        if not rows:
            print(f"{p.name}：本人の声の登録の区間がありません")
        for r in rows:
            print(f"{p.name}：{r['start_s']:.0f}秒から {r['length_s']:.0f}秒、計算した声のまとまり {r['chunks']}個（{(r['person_id'] or '')[:8]}）")
            for name, label in (("gate1", "前の決まり（v1.10.1〜v1.10.2）"), ("gate2", "今の決まり（v1.10.3〜）"), ("gate2_null_blocks", "参考：今の決まりで null があれば数えない")):
                g = r[name]
                print(f"  {label}：数えた {g['count'].get('counted', 0)}個（{g['seconds'].get('counted', 0):.1f}秒）"
                      f"・not_self {g['count'].get('not_self', 0)}・no_f0 {g['count'].get('no_f0', 0)}・no_frames {g['count'].get('no_frames', 0)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
