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
  python face_check.py 記録.jsonl --auto                                        場面の印が無い記録でも：区間を値から推定する（v1.16〜）
--auto の推定（仮の決まり）：眉を寄せる＝brow_inner_gap（眉頭の間）の z ≤ −2、笑う＝mouth_corner（口角の高さ）の z ≥ 2 が 0.5秒以上続いた間（1秒未満の切れ目はつなぐ）。
落ち着いている＝どちらも |z| < 1 が 5秒以上続いた間。推定した区間は表の前に出す。推定に使った指標は、その区間で z≥2 になるのは当たり前なので、ほかの指標と比べるときに見る
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


def runs(t: np.ndarray, mask: np.ndarray, min_s: float, gap_s: float) -> list[tuple[float, float]]:
    """mask が続いた間（gap_s 未満の切れ目はつなぐ）のうち、min_s 以上のもの。(始まり, 終わり) の epoch 秒"""
    out: list[list[float]] = []
    for i in np.flatnonzero(mask):
        ti = float(t[i])
        if out and ti - out[-1][1] < gap_s:
            out[-1][1] = ti
        else:
            out.append([ti, ti])
    return [(a, b) for a, b in out if b - a >= min_s]


def auto_spans(rec: review.Recording, a: review.Analysis) -> dict[str, list[tuple[float, float]]]:
    """場面の印が無い記録のための区間の推定（v1.16〜）：brow_inner_gap と mouth_corner の z から"""
    t = rec.t
    n = len(t)

    def z(m):
        if m not in a.z:
            return np.full(n, np.nan)
        return np.where(a.judge[m], a.z[m], np.nan)
    zb, zm = z("brow_inner_gap"), z("mouth_corner")
    with np.errstate(invalid="ignore"):
        frown = zb <= -2
        smile = zm >= 2
        calm = (np.abs(zb) < 1) & (np.abs(zm) < 1)
    return {"frown": runs(t, frown, 0.5, 1.0), "smile": runs(t, smile, 0.5, 1.0), "calm": runs(t, calm, 5.0, 0.5)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("record")
    ap.add_argument("--calm", action="append", help="落ち着いている時間（秒-秒 または 時刻-時刻）。何度でも")
    ap.add_argument("--frown", action="append", help="眉を寄せた時間")
    ap.add_argument("--smile", action="append", help="笑った時間")
    ap.add_argument("--auto", action="store_true", help="場面の印が無い記録で、区間を値から推定する（v1.16〜）")
    args = ap.parse_args(argv)
    if not (args.calm or args.frown or args.smile or args.auto):
        print("--calm / --frown / --smile か --auto を渡してください")
        return 2
    c = review.load_criteria(review.HERE / "criteria.json", [])
    rec = review.load(Path(args.record))
    a = review.analyze(rec, c)
    if args.auto:
        t0 = float(rec.t[0])
        est = auto_spans(rec, a)
        names = {"calm": "落ち着いている", "frown": "眉を寄せる", "smile": "笑う"}
        print("推定した区間（記録の始まりからの秒。眉を寄せる＝眉頭の間の z ≤ −2、笑う＝口角の高さの z ≥ 2、落ち着いている＝どちらも |z| < 1 が 5秒以上）")
        for k in ("calm", "frown", "smile"):
            sp = [f"{a_ - t0:.1f}-{b_ - t0:.1f}" for a_, b_ in est[k]]
            print(f"  {names[k]}：" + ("、".join(sp) if sp else "なし"))
            setattr(args, k, (getattr(args, k) or []) + ([",".join(sp)] if sp else []))
    flat = (c.get("geometry") or {}).get("flat_range", 0.01)
    print(f"{rec.path.name}（基準 {c['version']}）。z は眉を寄せる・目を細める・笑う向きがプラス。z≥2 は判定したコマのうちの割合")
    print("指標\t記録の間の値の幅\t落ち着いている\t眉を寄せる\t笑う")
    for r in table(rec, a, args, flat):
        print("\t".join(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
