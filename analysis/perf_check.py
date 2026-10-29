#!/usr/bin/env python3
"""記録ごとの速さ（解析コマ/秒・撮影→結果・解析時間）と、話者の区別の計算時間を並べる（v1.10〜）。
話者の区別のオン／オフで同じ場面を記録し、両方を渡して比べる（ヘッダの speaker_on で見分ける）。

使い方：python perf_check.py 記録.jsonl ...
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

import review


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
            "calc_p50": pct(calc, 50), "calc_p95": pct(calc, 95), "short_rows": int((win < 1500).sum())}


COLS = [("file", "記録", "{}"), ("speaker_on", "話者の区別", "{}"), ("duration_s", "長さ 秒", "{:.0f}"), ("fps", "解析コマ/秒", "{:.1f}"),
        ("lat_p50", "撮影→結果 ms 中央値", "{:.0f}"), ("lat_p95", "撮影→結果 ms 95%", "{:.0f}"),
        ("proc_p50", "解析時間 ms 中央値", "{:.1f}"), ("speaker_rows", "話者の行", "{}"), ("speaker_per_s", "話者の行/秒", "{:.2f}"),
        ("calc_p50", "話者の計算 ms 中央値", "{:.1f}"), ("calc_p95", "話者の計算 ms 95%", "{:.1f}"), ("short_rows", "1.5秒未満の声の行", "{}"),
        ("f0_ratio_p50", "f0 が取れていた割合 中央値", "{:.2f}"), ("model", "モデル", "{}"), ("plan", "計算の場所（ne＝Neural Engine）", "{}"),
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
