#!/usr/bin/env python3
"""記録ごとの速さ（解析コマ/秒・撮影→結果・解析時間）と、話者の区別の計算時間を並べる（v1.10〜）。
話者の区別のオン／オフで同じ場面を記録し、両方を渡して比べる（ヘッダの speaker_on で見分ける）。

v1.17〜：顔の点の距離（v1.15〜の frame の geo）があるコマと無いコマの解析時間・撮影→結果、10秒ごとの解析コマ/秒の最小と、
前半・後半の解析コマ/秒、コマの来ない間（0.3秒以上、v1.19〜はアプリが書いた frame_gap の理由も）、端末の熱の状態（v1.18〜の event kind: "thermal"、記録の始まりからの秒）、探す顔の数の変更（faces_limit）も出す（点の距離を足したことで遅くなったか、時間がたって遅くなったか（熱など）を見分ける）。
点の距離は |yaw| > 25° と顔の無いコマで求めないので、無いコマは横を向いた・顔の無いコマでもあることに気をつける。

使い方：python perf_check.py 記録.jsonl ...
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

import review


GAP_S = 0.3   # アプリの FrameGap.minMs と同じ


def frame_gaps(t: np.ndarray, gap_s: float = GAP_S) -> list[tuple[float, float]]:
    """コマの間が gap_s 以上空いたところ：(前のコマの時刻, 空いた秒)"""
    if len(t) < 2:
        return []
    d = np.diff(t)
    return [(float(t[i]), float(d[i])) for i in np.flatnonzero(d >= gap_s - 1e-9)]


def summary(path: Path) -> dict:
    rec = review.load(path)
    t = rec.t
    dur = float(t[-1] - t[0]) if len(t) > 1 else 0.0
    lat = rec.lat_ms[np.isfinite(rec.lat_ms)]
    proc = rec.proc_ms[np.isfinite(rec.proc_ms)]
    calc = np.array([r.get("calc_ms", np.nan) for r in rec.speaker], float)
    calc = calc[np.isfinite(calc)]
    win = np.array([r.get("window_ms", 0) for r in rec.speaker], float)
    pct = lambda x, q: float(np.percentile(x, q)) if len(x) else None
    # 顔の点の距離があるコマ（v1.15〜）と無いコマ
    geo = np.zeros(len(t), bool)
    for m in review.GEO_METRICS:
        if m in rec.raw:
            geo |= np.isfinite(rec.raw[m])
    face = np.asarray(rec.face, bool)
    pm, lm = np.isfinite(rec.proc_ms), np.isfinite(rec.lat_ms)
    # 10秒ごとの解析コマ/秒（最後の半端な分は入れない）と、前半・後半
    win_fps = [float(((t >= a) & (t < a + 10)).sum()) / 10 for a in np.arange(t[0], t[-1] - 10 + 1e-9, 10)] if dur >= 10 else []
    half = t[0] + dur / 2 if dur > 0 else 0
    fps_of = lambda sel, d: (int(sel.sum()) / d) if d > 0 else None
    # 端末の熱の状態（v1.18〜、event kind: "thermal"）と、探す顔の数（faces_limit）
    th = [e for e in rec.events if e.get("kind") == "thermal"]
    thermal = " → ".join(f"{e.get('value')}@{(e['t_ms'] / 1000 - t[0]):.0f}s" for e in th) if th else None
    fl = [e.get("count") for e in rec.events if e.get("kind") == "faces_limit" and e.get("count") is not None]
    faces_limit = " → ".join(str(x) for x in fl) if fl else None
    # コマが来なかった間（v1.19〜）：コマの間が gap_s 以上のもの（記録の始まりからの秒と長さ）と、アプリが書いた frame_gap の理由
    gaps = frame_gaps(t)
    gap_text = "、".join(f"{a - t[0]:.1f}s {d:.1f}秒" for a, d in gaps[:8]) + ("…" if len(gaps) > 8 else "") if gaps else None
    fg = [e for e in rec.events if e.get("kind") == "frame_gap"]
    reasons: dict[str, int] = {}
    for e in fg:
        for r in (e.get("reason") or "unknown").split(","):
            reasons[r] = reasons.get(r, 0) + 1
    # 重い処理をしていた間（v1.20〜、event kind: "work"）
    wk = [e for e in rec.events if e.get("kind") == "work" and e.get("start_ms") and e.get("end_ms")]
    work = "、".join(f"{e.get('value')} {e['start_ms'] / 1000 - t[0]:.1f}〜{e['end_ms'] / 1000 - t[0]:.1f}s" for e in wk) if wk else None
    gap_reasons = "、".join(f"{k} {v}" for k, v in sorted(reasons.items(), key=lambda kv: -kv[1])) if fg else None
    f0r = np.array([r["f0_ratio"] for r in rec.speaker if r.get("f0_ratio") is not None], float)   # v1.10.2〜
    part = {k: np.array([r[k] for r in rec.speaker if r.get(k) is not None], float) for k in ("fbank_ms", "predict_ms", "wait_ms")}   # v1.10.3〜
    m = next((e for e in rec.events if e.get("kind") == "speaker_model"), None)                     # v1.10.2〜
    plan = " ".join(f"{k}={v}" for k, v in sorted((m.get("plan") or {}).items())) if m else None
    return {"file": path.name, "speaker_on": bool(rec.header.get("speaker_on")), "duration_s": dur,
            "model": rec.header.get("speaker_model"), "plan": plan, "load_ms": m.get("load_ms") if m else None,
            "f0_ratio_p50": pct(f0r, 50),
            "fbank_p50": pct(part["fbank_ms"], 50), "predict_p50": pct(part["predict_ms"], 50), "predict_p95": pct(part["predict_ms"], 95),
            "wait_p50": pct(part["wait_ms"], 50), "wait_p95": pct(part["wait_ms"], 95),
            "qos": rec.header.get("speaker_qos"), "units": rec.header.get("speaker_compute_units"), "cached": m.get("cached") if m else None,
            "fps": (len(t) - 1) / dur if dur > 0 else None,
            "lat_p50": pct(lat, 50), "lat_p95": pct(lat, 95), "proc_p50": pct(proc, 50), "proc_p95": pct(proc, 95),
            "speaker_rows": len(rec.speaker), "speaker_per_s": len(rec.speaker) / dur if dur > 0 else None,
            "calc_p50": pct(calc, 50), "calc_p95": pct(calc, 95), "short_rows": int((win < 1500).sum()),
            "geo_ratio": float(geo[face].mean()) if face.any() else None,
            "proc_geo_p50": pct(rec.proc_ms[pm & geo], 50), "proc_nogeo_p50": pct(rec.proc_ms[pm & face & ~geo], 50),
            "lat_geo_p50": pct(rec.lat_ms[lm & geo], 50), "lat_nogeo_p50": pct(rec.lat_ms[lm & face & ~geo], 50),
            "fps_win_min": min(win_fps) if win_fps else None,
            "fps_first": fps_of(t < half, dur / 2), "fps_second": fps_of(t >= half, dur / 2),
            "thermal": thermal, "faces_limit": faces_limit,
            "gap_n": len(gaps), "gap_s": float(sum(d for _, d in gaps)), "gaps": gap_text, "gap_reasons": gap_reasons, "work": work}


COLS = [("file", "記録", "{}"), ("speaker_on", "話者の区別", "{}"), ("duration_s", "長さ 秒", "{:.0f}"), ("fps", "解析コマ/秒", "{:.1f}"),
        ("lat_p50", "撮影→結果 ms 中央値", "{:.0f}"), ("lat_p95", "撮影→結果 ms 95%", "{:.0f}"),
        ("proc_p50", "解析時間 ms 中央値", "{:.1f}"), ("speaker_rows", "話者の行", "{}"), ("speaker_per_s", "話者の行/秒", "{:.2f}"),
        ("calc_p50", "話者の計算 ms 中央値", "{:.1f}"), ("calc_p95", "話者の計算 ms 95%", "{:.1f}"), ("short_rows", "1.5秒未満の声の行", "{}"),
        ("f0_ratio_p50", "f0 が取れていた割合 中央値", "{:.2f}"), ("model", "モデル", "{}"), ("plan", "計算の場所（ne＝Neural Engine）", "{}"),
        ("geo_ratio", "顔のコマのうち点の距離がある割合", "{:.2f}"),
        ("proc_geo_p50", "解析時間 ms 中央値（点の距離あり）", "{:.1f}"), ("proc_nogeo_p50", "解析時間 ms 中央値（顔はあるが点の距離なし）", "{:.1f}"),
        ("lat_geo_p50", "撮影→結果 ms 中央値（点の距離あり）", "{:.0f}"), ("lat_nogeo_p50", "撮影→結果 ms 中央値（顔はあるが点の距離なし）", "{:.0f}"),
        ("fps_win_min", "10秒ごとの解析コマ/秒 最小", "{:.1f}"), ("fps_first", "解析コマ/秒 前半", "{:.1f}"), ("fps_second", "解析コマ/秒 後半", "{:.1f}"),
        ("gap_n", "コマの来ない間 0.3秒以上 回", "{}"), ("gap_s", "その合計 秒", "{:.1f}"), ("gaps", "コマの来ない間（始まりからの秒 長さ）", "{}"),
        ("gap_reasons", "frame_gap の理由（v1.19〜）", "{}"), ("work", "重い処理をしていた間（v1.20〜）", "{}"),
        ("thermal", "端末の熱（v1.18〜）", "{}"), ("faces_limit", "探す顔の数の変更", "{}"),
        ("load_ms", "読み込み ms", "{:.0f}"), ("cached", "前に読み込んだもの", "{}"),
        ("fbank_p50", "fbank ms 中央値", "{:.1f}"), ("predict_p50", "predict ms 中央値", "{:.1f}"), ("predict_p95", "predict ms 95%", "{:.1f}"),
        ("wait_p50", "待ち ms 中央値", "{:.1f}"), ("wait_p95", "待ち ms 95%", "{:.1f}"), ("qos", "優先度", "{}"), ("units", "computeUnits", "{}")]


def table(rows: list[dict]) -> str:
    out = ["\t".join(c[1] for c in COLS)]
    for r in rows:
        out.append("\t".join("–" if r[k] is None else (("オン" if r[k] else "オフ") if k == "speaker_on" else f.format(r[k])) for k, _, f in COLS))
    return "\n".join(out)


def main(argv=None) -> int:
    args = [Path(a) for a in (argv if argv is not None else sys.argv[1:])]
    if not args:
        print(__doc__)
        return 2
    print(table([summary(p) for p in args]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
