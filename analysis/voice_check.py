#!/usr/bin/env python3
"""本人の声の見分け（voice_self、v1.9〜）のしきい値を、記録で確かめる。

本人が話していた時間・ほかの人が話していた時間を渡すと、声が出ていたコマについて
  本人の声を本人と言えた割合（本人の時間の声のコマのうち、voice_self が本人になったもの）
  ほかの人の声を本人と言ってしまった割合（ほかの人の時間の声のコマのうち、本人になったもの）
を、決まりの組み合わせ（口の動きだけ＝v1.8 まで／＋タイミング／＋声の高さの範囲／両方）と、タイミングのしきい値（min_corr）ごとに出す。
記録に書いてある voice_self は使わず、criteria.json の決まりで決め直す。声紋（声の特徴で人を特定するもの）は作らない。

使い方：
  python voice_check.py 記録.jsonl --self 25-37 --self 50-52 --other 42-51        記録の始まりからの秒（13:42:05-13:42:20 のような時刻も可）
  python voice_check.py 記録.jsonl --self-hz 100-200 --other-hz 250-400            時間が分からないときは、声の高さで分けて代わりにする
                                                                                   （声の高さの範囲の決まりはこの分け方と重なるので、タイミングの決まりだけを見る）
  --other 35-38,42-51              カンマでつないだ時間も渡せる
  --pitch-median 150 --pitch-spread 15   保存した声の普段の代わり（記録に保存した声の普段の行が無いとき、声の高さの範囲の決まりを試す）
  --self-baseline                  本人の時間の声の高さから、アプリと同じ求め方（中央値・四分位範囲）で声の普段を作って試す
タイミングの決まりは v1.9.1 から判定に使っていない（criteria.json の voice_self.sync.enabled: false）が、ここでは試すために入れる
"""
from __future__ import annotations

import argparse
import copy
import sys
from datetime import datetime
from pathlib import Path

import numpy as np

import review

SWEEP = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6]


def parse_span(s: str, t0: float) -> tuple[float, float]:
    a, _, b = s.partition("-")

    def one(x: str) -> float:
        x = x.strip()
        if ":" in x:
            day = datetime.fromtimestamp(t0, review.JST)
            hms = [int(v) for v in x.split(":")]
            while len(hms) < 3:
                hms.append(0)
            return day.replace(hour=hms[0], minute=hms[1], second=hms[2], microsecond=0).timestamp()
        return t0 + float(x)
    return one(a), one(b)


def spans(values) -> list[str]:
    """--self 4-16 --other 35-38,42-51 のように、何度でも・カンマでつないで渡せる"""
    return [p.strip() for v in (values or []) for p in v.split(",") if p.strip()]


def labels(rec: review.Recording, args) -> np.ndarray:
    """各コマ：1＝本人の時間、0＝ほかの人の時間、NaN＝どちらでもない（声が出ていないコマも NaN）"""
    t, t0 = rec.t, float(rec.t[0])
    out = np.full(len(t), np.nan)
    for s in spans(args.self):
        a, b = parse_span(s, t0)
        out[(t >= a) & (t < b)] = 1
    for s in spans(args.other):
        a, b = parse_span(s, t0)
        out[(t >= a) & (t < b)] = 0
    f0 = rec.raw["f0_hz"]
    for hz, v in ((args.self_hz, 1), (args.other_hz, 0)):
        if hz:
            lo, hi = (float(x) for x in hz.split("-"))
            out[(f0 >= lo) & (f0 <= hi)] = v
    out[~np.isfinite(f0)] = np.nan
    return out


def variant(c: dict, sync: bool, pitch: bool, min_corr: float | None = None) -> dict:
    c = copy.deepcopy(c)
    vc = c["voice_self"]
    vc["sync"]["enabled"] = sync   # 判定には使っていない（v1.9.1〜）が、ここでは試すために入れる
    if min_corr is not None:
        vc["sync"]["min_corr"] = min_corr
    if not pitch:
        vc.pop("pitch_range", None)
    return c


def rates(rec, c, lab) -> tuple[float | None, float | None, int, int]:
    fv = review.face_valid(rec, c)
    vs = review.voice_self_details(rec, c, fv, use_recorded=False).values
    s, o = lab == 1, lab == 0
    ns, no = int(s.sum()), int(o.sum())
    return (float((vs[s] == 1).mean()) if ns else None, float((vs[o] == 1).mean()) if no else None, ns, no)


def with_pitch(rec: review.Recording, median: float, spread: float) -> review.Recording:
    """保存した声の普段の行を、記録の始まりに足したもの（試すだけ）。spread はばらつき（四分位範囲÷1.349）"""
    r = copy.copy(rec)
    row = {"type": "baseline", "t_ms": int(rec.t[0] * 1000), "source": "saved", "compared": True, "part": "voice",
           "metrics": {"f0_hz": {"n": 300, "mean": median, "std": spread, "median": median, "iqr": round(spread * 1.349, 1),
                                 "insufficient": False}}}
    r.all_baselines = [row] + list(rec.all_baselines)
    return r


def report(rec, c, lab) -> list[list[str]]:
    pct = lambda v: "–" if v is None else f"{v:.0%}"
    rows = []
    for name, sync, pitch in (("口の動きだけ（v1.8 まで）", False, False), ("＋タイミング", True, False),
                              ("＋声の高さの範囲", False, True), ("両方（v1.9）", True, True)):
        a, b, ns, no = rates(rec, variant(c, sync, pitch), lab)
        rows.append([name, pct(a), pct(b), f"{ns} / {no}"])
    for mc in SWEEP:
        a, b, ns, no = rates(rec, variant(c, True, False, mc), lab)
        rows.append([f"タイミングだけ min_corr={mc:g}", pct(a), pct(b), f"{ns} / {no}"])
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("record")
    ap.add_argument("--self", action="append", help="本人が話していた時間（秒-秒 または 時刻-時刻）。何度でも")
    ap.add_argument("--other", action="append", help="ほかの人が話していた時間")
    ap.add_argument("--self-hz", help="本人の声の高さの範囲（例 100-200）で分けて代わりにする")
    ap.add_argument("--other-hz", help="ほかの人の声の高さの範囲（例 250-400）")
    ap.add_argument("--pitch-median", type=float, help="保存した声の普段の代わり：声の高さの中央値（Hz）")
    ap.add_argument("--pitch-spread", type=float, default=15.0, help="そのばらつき（Hz、四分位範囲÷1.349）")
    ap.add_argument("--self-baseline", action="store_true",
                    help="本人の時間の声の高さから、アプリと同じ求め方（中央値・四分位範囲）で声の普段を作って試す")
    args = ap.parse_args(argv)
    rec = review.load(Path(args.record))
    c = review.load_criteria(review.HERE / "criteria.json", [])
    lab = labels(rec, args)
    if not np.isfinite(lab).any():
        print("本人の時間・ほかの人の時間に、声が出ていたコマがありません（--self / --other か --self-hz / --other-hz を渡してください）")
        return 2
    if args.self_baseline:
        rp = review.robust_pitch(rec.raw["f0_hz"][lab == 1])
        if rp:
            print(f"本人の時間の声の高さ：中央値 {rp[0]:g}Hz・ばらつき {review.spread_of(rp[1]):.1f}Hz（四分位範囲 {rp[1]:g}Hz）")
            rec = with_pitch(rec, rp[0], review.spread_of(rp[1]))
    elif args.pitch_median is not None:
        rec = with_pitch(rec, args.pitch_median, args.pitch_spread)
    print(f"{rec.path.name}（基準 {c['version']}）")
    print("決まり\t本人を本人と言えた\tほかの人を本人と言ってしまった\t声のコマ（本人 / ほかの人）")
    for r in report(rec, c, lab):
        print("\t".join(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
