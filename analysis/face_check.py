#!/usr/bin/env python3
"""表情の指標（blendshape と、顔の点の距離 v1.15〜）を、区間ごとに比べる（voice_check.py の顔の版）。

blendshape の眉（brow_down）と、点の眉（brow_eye_gap・brow_inner_gap）のどちらを判定に使うかを決めるためのもの。
落ち着いている時間・眉を寄せた時間・笑った時間を渡すと、指標ごとに
  値の中央値、z の中央値（記録の普段と比べたもの。z は「寄せる・細める・笑う」向きがプラスになるように向きをそろえる）、
  向きをそろえた z が 2 以上だったコマの割合（判定したコマのうち）
を並べる。ほとんど動かない指標（記録の間の値の幅が flat_range 未満）には印を付ける。

使い方：
  python face_check.py 記録.jsonl --calm 10-40 --frown 50-60 --smile 70-80     記録の始まりからの秒（13:42:05-13:42:20 のような時刻も可）
  --frown 50-60,90-95     カンマでつないだ時間も、何度でも渡せる
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

import review
from voice_check import parse_span, spans

# z の向き：眉を寄せる・目を細める・笑うときにプラスになるように（criteria.json の co_change.groups の "-" と同じ）
METRICS = [("brow_down", 1), ("brow_eye_gap", -1), ("brow_inner_gap", -1),
           ("eye_squint", 1), ("orbit", 1), ("eye_open", -1),
           ("mouth_smile", 1), ("cheek_raise", 1), ("mouth_corner", 1),
           ("nose_lip", 1), ("mouth_tense", 1), ("jaw_open", 1)]


def table(rec: review.Recording, a: review.Analysis, args, flat_range: float) -> list[list[str]]:
    t0 = float(rec.t[0])
    kinds = [("落ち着いている", args.calm), ("眉を寄せる", args.frown), ("笑う", args.smile)]
    rows = []
    for m, sign in METRICS:
        x = rec.raw.get(m)
        if x is None or not np.isfinite(x).any():
            rows.append([review.LABEL.get(m, m), "記録に無い（v1.15 より前の記録・|yaw| > 25° だけ）"] + [""] * len(kinds))
            continue
        flat = (np.nanmax(x) - np.nanmin(x)) < flat_range
        cells = []
        for _, values in kinds:
            sel = np.zeros(len(rec.t), bool)
            for s in spans(values):
                lo, hi = parse_span(s, t0)
                sel |= (rec.t >= lo) & (rec.t < hi)
            if not sel.any():
                cells.append("–")
                continue
            v = x[sel]
            z = a.z.get(m)
            judged = sel & a.judge.get(m, np.zeros(len(rec.t), bool)) & np.isfinite(z) if z is not None else np.zeros(len(rec.t), bool)
            if judged.any():
                zz = z[judged] * sign
                cells.append(f"値 {np.nanmedian(v):.3f}・z {np.median(zz):+.1f}・z≥2 {np.mean(zz >= 2):.0%}（{judged.sum()}コマ）")
            else:
                cells.append(f"値 {np.nanmedian(v):.3f}・普段が無い")
        rows.append([review.LABEL.get(m, m) + ("（ほとんど動かない）" if flat else ""),
                     f"{np.nanmin(x):.3f}〜{np.nanmax(x):.3f}"] + cells)
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("record")
    ap.add_argument("--calm", action="append", help="落ち着いている時間（秒-秒 または 時刻-時刻）。何度でも")
    ap.add_argument("--frown", action="append", help="眉を寄せた時間")
    ap.add_argument("--smile", action="append", help="笑った時間")
    args = ap.parse_args(argv)
    if not (args.calm or args.frown or args.smile):
        print("--calm / --frown / --smile のどれかを渡してください")
        return 2
    c = review.load_criteria(review.HERE / "criteria.json", [])
    rec = review.load(Path(args.record))
    a = review.analyze(rec, c)
    flat = (c.get("geometry") or {}).get("flat_range", 0.01)
    print(f"{rec.path.name}（基準 {c['version']}）。z は眉を寄せる・目を細める・笑う向きがプラス。z≥2 は判定したコマのうちの割合")
    print("指標\t記録の間の値の幅\t落ち着いている\t眉を寄せる\t笑う")
    for r in table(rec, a, args, flat):
        print("\t".join(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
