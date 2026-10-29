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
  python face_check.py 記録.jsonl --cues [--json]                               試すモード（v1.18〜）の結果：アプリの画面と同じ表（--json はアプリの DiffCheck --cues と同じ形）
--cues：記録の event kind "cue"（最後の試すモード）から、指示ごとに「いつもとの違い」が出た回数・出るまでの秒数、何もしない・横を向く・戻す間の違いと重なりの数（1分あたり）、
指標ごとの眉を寄せる・笑う間の z の中央値と z ≥ 2 が出た回数を、今の下限（before）と、その記録の「いちばん強く・大きく」から求めたその人の最大で決めた下限（after）で並べる
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

import review
from voice_check import parse_span, spans

# z の向き：眉を寄せる・目を細める・笑うときにプラスになるように（criteria.json の co_change.groups の "-" と同じ）
METRICS = [("brow_down", 1), ("brow_eye_gap", -1), ("brow_inner_gap", -1), ("brow_inner_eye", -1), ("brow_inner_gap2", -1),   # 後ろの2つは v1.18〜
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


# 試すモード（v1.18〜、アプリの Cues.swift の CueReport・CueTrial と同じ決まり）
def sign_list(names: list[str]) -> list[tuple[str, int]]:
    return [(m.lstrip("-"), -1 if m.startswith("-") else 1) for m in names]


def cue_list(rec: review.Recording) -> list[tuple[str, float, float]]:
    out = [(e["value"], e["start_ms"] / 1000, e["end_ms"] / 1000) for e in rec.events
           if e.get("kind") == "cue" and e.get("start_ms") is not None and e.get("end_ms") is not None]
    return sorted(out, key=lambda x: x[1])


def last_run(cues: list[tuple[str, float, float]]) -> list[tuple[str, float, float]]:
    """最後の試すモード（指示の間が 10秒より空いたら別のまとまり）"""
    out: list = []
    for cu in cues:
        if out and cu[1] - out[-1][2] > 10:
            out = []
        out.append(cu)
    return out


def maxima(rec: review.Recording, cues, c: dict) -> dict[str, float]:
    """その人の最大：frown_max・smile_max の間の顔のあるコマの生の値の、動く向きの q 分位（アプリの Calibration.maxima）"""
    cal = c["calibration"]
    out = {}
    for kind, names in (("frown_max", cal["frown"]), ("smile_max", cal["smile"])):
        ws = [(a_, b_) for k, a_, b_ in cues if k == kind]
        if not ws:
            continue
        sel = np.zeros(len(rec.t), bool)
        for a_, b_ in ws:
            sel |= (rec.t >= a_ - 1e-9) & (rec.t <= b_ + 1e-9)
        sel &= rec.face
        for m, sign in sign_list(names):
            x = rec.raw[m][sel]
            x = x[np.isfinite(x)]
            if len(x) < cal["min_n"]:
                continue
            out[m] = review.swift_round(float(np.percentile(x, 100 * (cal["q"] if sign > 0 else 1 - cal["q"]))), 4)
    return out


def cue_report(a: review.Analysis, cues, c: dict) -> dict:
    cc = c["cues"]
    t = a.rec.t
    eps = 1e-9
    segs = [(s.metric, s.sign > 0, float(t[s.i0])) for s in a.segments if s.metric != review.VOICE_ON]
    cos = [float(t[e["i0"]]) for e in a.co_changes]
    r = {"hits": [], "quiet": [], "rows": []}
    for kind in ("frown", "smile"):
        cs = [x for x in cues if x[0] == kind]
        m = cc["target"][kind]
        lat = []
        for _, s0, s1 in cs:
            st = [ts for mm, up, ts in segs if mm == m and up and s0 - eps <= ts <= s1 + cc["grace_s"] + eps]
            if st:
                lat.append(review.swift_round(min(st) - s0, 3))
        r["hits"].append({"kind": kind, "n": len(cs), "hit": len(lat), "latencyS": lat})
    for kind in ("calm", "turn", "rest"):
        cs = [x for x in cues if x[0] == kind]

        def inside(ts, cs=cs):
            return any(s0 - eps <= ts < s1 - eps for _, s0, s1 in cs)
        r["quiet"].append({"kind": kind, "seconds": review.swift_round(sum(s1 - s0 for _, s0, s1 in cs), 3),
                           "diffs": sum(1 for _, _, ts in segs if inside(ts)), "co": sum(1 for ts in cos if inside(ts))})
    for kind in ("frown", "smile"):
        cs = [x for x in cues if x[0] == kind]
        for m, sign in sign_list(cc["metrics"]):
            z = np.where(a.judge[m], a.z[m], np.nan) if m in a.z else np.full(len(t), np.nan)
            zs, hit = [], 0
            for _, s0, s1 in cs:
                w = (t >= s0 - eps) & (t <= s1 + cc["grace_s"] + eps) & np.isfinite(z)
                inn = w & (t <= s1 + eps)
                zs += list(z[inn] * sign)
                if (z[w] * sign >= cc["hit_z"] - eps).any():
                    hit += 1
            med = review.swift_round(float(np.percentile(np.array(zs), 50)), 3) if zs else None
            r["rows"].append({"metric": m, "kind": kind, "n": len(cs), "hit": hit, "zMedian": med})
    return r


def cue_trial(rec: review.Recording, c: dict) -> dict | None:
    cues = last_run(cue_list(rec))
    if not cues:
        return None
    mx = maxima(rec, cues, c)
    before = cue_report(review.analyze(review.with_floors(rec, c, "defaults"), c), cues, c)
    after = cue_report(review.analyze(review.with_floors(rec, c, "calibrated", mx), c), cues, c) if mx else None
    return {"max": mx, "before": before, "after": after}


CUE_NAMES = {"frown": "眉を寄せる", "smile": "笑う", "calm": "何もしない", "turn": "顔を横に向ける", "rest": "戻す"}


def cue_text(tr: dict) -> list[str]:
    """アプリの試すモードの結果と同じ並び（人が読む用）"""
    out = []
    for label, rep in (("今の下限", tr["before"]), ("その人の最大から決めた下限", tr["after"])):
        if rep is None:
            out.append(f"■ {label}：その人の最大が求まらなかった")
            continue
        out.append(f"■ {label}")
        for h in rep["hits"]:
            lat = f"・出るまで 中央値 {np.median(h['latencyS']):.1f}秒" if h["latencyS"] else ""
            out.append(f"  {CUE_NAMES[h['kind']]}：いつもとの違いが出た {h['hit']}／{h['n']}回{lat}")
        for q in rep["quiet"]:
            def pm(k, q=q):
                return f"{q[k] / q['seconds'] * 60:.1f}" if q["seconds"] > 0 else "–"
            out.append(f"  {CUE_NAMES[q['kind']]}の間（{q['seconds']:.0f}秒）：いつもとの違い {q['diffs']}件（{pm('diffs')}/分）・重なり {q['co']}件（{pm('co')}/分）")
        out.append("  指標\t眉を寄せる：z 中央値・z≥2 の回数\t笑う：z 中央値・z≥2 の回数")
        for m in dict.fromkeys(r["metric"] for r in rep["rows"]):
            cells = []
            for kind in ("frown", "smile"):
                r = next(x for x in rep["rows"] if x["metric"] == m and x["kind"] == kind)
                cells.append(("–" if r["zMedian"] is None else f"{r['zMedian']:+.1f}") + f"・{r['hit']}／{r['n']}")
            out.append(f"  {review.LABEL.get(m, m)}\t" + "\t".join(cells))
    if tr["max"]:
        out.append("その人の最大：" + "、".join(f"{review.LABEL.get(k, k)} {v:.3f}" for k, v in tr["max"].items()))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("record")
    ap.add_argument("--calm", action="append", help="落ち着いている時間（秒-秒 または 時刻-時刻）。何度でも")
    ap.add_argument("--frown", action="append", help="眉を寄せた時間")
    ap.add_argument("--smile", action="append", help="笑った時間")
    ap.add_argument("--auto", action="store_true", help="場面の印が無い記録で、区間を値から推定する（v1.16〜）")
    ap.add_argument("--cues", action="store_true", help="試すモード（v1.18〜）の結果")
    ap.add_argument("--json", action="store_true", help="--cues の結果を JSON で（アプリの DiffCheck --cues と同じ形）")
    args = ap.parse_args(argv)
    if args.cues:
        import json
        c = review.load_criteria(review.HERE / "criteria.json", [])
        tr = cue_trial(review.load(Path(args.record)), c)
        if args.json:
            print(json.dumps(tr, ensure_ascii=False, sort_keys=True))
            return 0
        if tr is None:
            print("この記録には試すモードの指示（event kind \"cue\"）がありません")
            return 1
        print("\n".join(cue_text(tr)))
        return 0
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
