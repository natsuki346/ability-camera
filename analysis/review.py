#!/usr/bin/env python3
"""Ability Cam の記録（JSONL）の振り返りレポート。

普段（type:"baseline"）から外れた区間を、数値の事実として出す。状態の名前は付けない。
出力：<記録>.html（画像は埋め込み、1ファイル）と <記録>_segments.csv。外部には何も送らない。

使い方：python review.py 記録.jsonl [--calm] [--criteria criteria.json] [--set brow_down.start_min_s=0.8]
"""
from __future__ import annotations

import argparse
import base64
import copy
import csv
import html
import io
import json
import math
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np

JST = timezone(timedelta(hours=9), "JST")
HERE = Path(__file__).resolve().parent

METRICS = ["mouth_smile", "brow_down", "eye_squint", "jaw_open", "rms_db", "f0_hz"]
FACE_METRICS = {"mouth_smile", "brow_down", "eye_squint", "jaw_open"}
LABEL = {"mouth_smile": "口角を上げる", "brow_down": "眉を寄せる", "eye_squint": "目を細める",
         "jaw_open": "口を開ける", "rms_db": "声の大きさ", "f0_hz": "声の高さ"}
UNIT = {"rms_db": " dB", "f0_hz": " Hz"}
# 向きの言い方（docs/wording-guide.md）
DIRECTION = {"rms_db": ("いつもより大きい", "いつもより小さい"), "f0_hz": ("いつもより高い", "いつもより低い")}


def direction(m: str, sign: int) -> str:
    up, down = DIRECTION.get(m, ("いつもより強い", "いつもより弱い"))
    return up if sign > 0 else down
CRITERIA_KEYS = ["smooth_s", "start_z", "start_min_s", "end_z", "end_min_s"]


# ---------------------------------------------------------------- 読み込み

@dataclass
class Recording:
    path: Path
    header: dict
    t: np.ndarray                    # 撮影時刻（epoch 秒）
    face: np.ndarray                 # 顔が見つかったか
    raw: dict[str, np.ndarray]       # 指標ごとの値（無いコマは NaN）
    yaw: np.ndarray
    lat_ms: np.ndarray
    proc_ms: np.ndarray
    baselines: list[dict]
    events: list[dict]

    @property
    def has_pose(self) -> bool:
        return bool(np.isfinite(self.yaw).any())


def face_values(bs: dict) -> dict[str, float]:
    """アプリと同じ式（左右の平均）"""
    def avg(a, b):
        return ((bs.get(a) or 0) + (bs.get(b) or 0)) / 2
    return {"mouth_smile": avg("mouthSmileLeft", "mouthSmileRight"),
            "brow_down": avg("browDownLeft", "browDownRight"),
            "eye_squint": avg("eyeSquintLeft", "eyeSquintRight"),
            "jaw_open": float(bs.get("jawOpen") or 0)}


def load(path: Path) -> Recording:
    header: dict = {}
    frames, baselines, events = [], [], []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            kind = o.get("type")
            if n == 0 and "schema" in o:
                header = o
            elif kind == "baseline":
                baselines.append(o)
            elif kind == "event":
                events.append(o)
            elif kind == "frame" or (kind is None and "face" in o):
                frames.append(o)
    if not frames:
        sys.exit(f"{path}: コマの行がありません")
    frames.sort(key=lambda o: o["t_ms"])
    baselines.sort(key=lambda o: o["t_ms"])
    events.sort(key=lambda o: o["t_ms"])

    n = len(frames)
    raw = {m: np.full(n, np.nan) for m in METRICS}
    yaw, lat, proc = (np.full(n, np.nan) for _ in range(3))
    face = np.zeros(n, bool)
    for i, o in enumerate(frames):
        if o.get("face") and o.get("bs"):
            face[i] = True
            for m, v in face_values(o["bs"]).items():
                raw[m][i] = v
        if o.get("rms_db") is not None:
            raw["rms_db"][i] = o["rms_db"]
        if o.get("f0_hz") is not None:
            raw["f0_hz"][i] = o["f0_hz"]
        if o.get("yaw_deg") is not None:
            yaw[i] = o["yaw_deg"]
        lat[i] = o.get("lat_ms", np.nan)
        p = o.get("proc_ms", -1)
        proc[i] = p if p is not None and p >= 0 else np.nan
    t = np.array([o["t_ms"] for o in frames], float) / 1000
    return Recording(path, header, t, face, raw, yaw, lat, proc, baselines, events)


# ---------------------------------------------------------------- 基準

def load_criteria(path: Path, overrides: list[str]) -> dict:
    with open(path, encoding="utf-8") as f:
        c = json.load(f)
    for s in overrides:
        key, _, val = s.partition("=")
        target, _, name = key.partition(".")
        if name not in CRITERIA_KEYS or not val:
            sys.exit(f"--set の形が違います: {s}（例 brow_down.start_min_s=0.8 / all.smooth_s=0.5）")
        for m in (METRICS if target == "all" else [target]):
            if m not in c["metrics"]:
                sys.exit(f"--set の指標が違います: {target}")
            c["metrics"][m][name] = float(val)
    c["_overrides"] = overrides
    return c


# ---------------------------------------------------------------- 計算

def smooth(t: np.ndarray, x: np.ndarray, tau: float, stale: float) -> np.ndarray:
    """時間で重みを決める EMA（アプリと同じ）。stale 秒以上更新がなければ NaN、その後は今の値から"""
    out = np.full(len(t), np.nan)
    v, last = None, -math.inf
    for i in range(len(t)):
        xi = x[i]
        if xi == xi:   # NaN でない
            if v is None or t[i] - last > stale:
                v = xi
            else:
                v += (1 - math.exp(-max(t[i] - last, 0) / tau)) * (xi - v)
            last = t[i]
        if v is not None and t[i] - last <= stale:
            out[i] = v
    return out


def face_valid(rec: Recording, c: dict) -> np.ndarray:
    """直近 window_s 秒で顔が映っているコマが半分以上、かつ |yaw| < 上限（向きの記録があるとき）"""
    fv = c["face_valid"]
    t = rec.t
    cum = np.concatenate([[0], np.cumsum(rec.face)])
    lo = np.searchsorted(t, t - fv["window_s"], side="right")
    idx = np.arange(len(t))
    ratio = (cum[idx + 1] - cum[lo]) / (idx + 1 - lo)
    ok = ratio >= fv["min_face_ratio"]
    if rec.has_pose:
        # 顔が無いコマは、直近 stale_s 秒の向きを使う
        yaw_ff = np.full(len(t), np.nan)
        last_v, last_t = np.nan, -math.inf
        for i in range(len(t)):
            if rec.yaw[i] == rec.yaw[i]:
                last_v, last_t = rec.yaw[i], t[i]
            if t[i] - last_t <= c["stale_s"]:
                yaw_ff[i] = last_v
        ok &= ~(np.abs(yaw_ff) >= fv["max_abs_yaw_deg"])
    return ok


def baseline_index(rec: Recording) -> np.ndarray:
    """各コマで使う普段（直前の baseline）。「普段を取り直す」から次の baseline までは無し（アプリと同じ）"""
    marks = [(b["t_ms"] / 1000, i) for i, b in enumerate(rec.baselines)]
    marks += [(e["t_ms"] / 1000, -1) for e in rec.events if e.get("kind") == "baseline_restart"]
    marks.sort()
    out = np.full(len(rec.t), -1)
    times = np.array([m[0] for m in marks]) if marks else np.zeros(0)
    pos = np.searchsorted(times, rec.t, side="right") - 1
    for i, p in enumerate(pos):
        if p >= 0:
            out[i] = marks[p][1]
    return out


@dataclass
class Segment:
    metric: str
    sign: int
    i0: int
    i1: int
    peak_i: int
    peak_z: float
    truncated: str = ""


def detect(t: np.ndarray, z: np.ndarray, ok: np.ndarray, c: dict) -> tuple[list[Segment], list[tuple[int, int]]]:
    """|z| ≥ start_z が start_min_s 以上続いたら開始、z が end_z 未満（同じ向きで）に end_min_s 続いたら終了。
    start_min_s に届かずに start_z を下回ったものは「短い動き」（開始・終了のコマ）として返す。
    判定できないコマ（ok=False / z=NaN）が来たら、走っているものはそこで打ち切る。
    判定できない時間の直後から始まったものは、始まりが見えていないので「短い動き」には数えない"""
    segs: list[Segment] = []
    shorts: list[tuple[int, int]] = []
    run0, run_sign = None, 0
    seg: Segment | None = None
    calm0 = None
    run_after_gap = False
    prev_good = True
    for i in range(len(t)):
        zi = z[i]
        good = bool(ok[i]) and zi == zi
        if seg is None:
            if good and abs(zi) >= c["start_z"]:
                s = 1 if zi > 0 else -1
                if run0 is not None and s != run_sign:
                    if t[i] - t[run0] < c["start_min_s"] and not run_after_gap:
                        shorts.append((run0, i))
                    run0 = None
                if run0 is None:
                    run0, run_sign, run_after_gap = i, s, not prev_good
                if t[i] - t[run0] >= c["start_min_s"]:
                    zz = z[run0:i + 1] * run_sign
                    k = int(np.nanargmax(zz))
                    seg = Segment("", run_sign, run0, i, run0 + k, float(z[run0 + k]),
                                  "始まりは判定できない時間の中" if run_after_gap else "")
                    run0, calm0 = None, None
            elif run0 is not None:
                if good and not run_after_gap:   # start_z を下回った（判定できないコマでの途切れは数えない）
                    shorts.append((run0, i))
                run0 = None
        else:
            if not good:
                seg.i1 = max(i - 1, seg.i0)
                seg.truncated = "・".join(filter(None, [seg.truncated, "判定できない時間で打ち切り"]))
                segs.append(seg); seg = None
                prev_good = good
                continue
            if zi * seg.sign < c["end_z"]:
                if calm0 is None:
                    calm0 = i
                if t[i] - t[calm0] >= c["end_min_s"]:
                    seg.i1 = calm0
                    segs.append(seg); seg = None
            else:
                calm0 = None
                seg.i1 = i
                if zi * seg.sign > seg.peak_z * seg.sign:
                    seg.peak_i, seg.peak_z = i, float(zi)
        prev_good = good
    if seg is not None:
        seg.i1 = len(t) - 1
        seg.truncated = "・".join(filter(None, [seg.truncated, "記録の終わりで打ち切り"]))
        segs.append(seg)
    return segs, shorts


@dataclass
class Analysis:
    rec: Recording
    criteria: dict
    bidx: np.ndarray
    fvalid: np.ndarray
    sm: dict[str, np.ndarray] = field(default_factory=dict)
    z: dict[str, np.ndarray] = field(default_factory=dict)
    judge: dict[str, np.ndarray] = field(default_factory=dict)   # 判定したコマ
    segments: list[Segment] = field(default_factory=list)
    shorts: dict[str, list[tuple[int, int]]] = field(default_factory=dict)
    usable: dict[str, bool] = field(default_factory=dict)        # 普段にデータがあったか（insufficient でない）


def analyze(rec: Recording, c: dict) -> Analysis:
    a = Analysis(rec, c, baseline_index(rec), face_valid(rec, c))
    t = rec.t
    for m in METRICS:
        mc = c["metrics"][m]
        a.sm[m] = smooth(t, rec.raw[m], mc["smooth_s"], c["stale_s"])
        mean = np.full(len(t), np.nan)
        sd = np.full(len(t), np.nan)
        for bi, b in enumerate(rec.baselines):
            st = b.get("metrics", {}).get(m)
            if not st or st.get("insufficient") or st.get("mean") is None:
                continue
            sel = a.bidx == bi
            mean[sel] = st["mean"]
            sd[sel] = max(st.get("std") or 0, c["std_floor"][m])
        a.usable[m] = bool(np.isfinite(mean).any())
        a.z[m] = (a.sm[m] - mean) / sd
        ok = np.isfinite(mean)
        if m in FACE_METRICS:
            ok &= a.fvalid
        a.judge[m] = ok
        segs, shorts = detect(t, a.z[m], ok, mc)
        for s in segs:
            s.metric = m
        a.segments += segs
        a.shorts[m] = shorts
    a.segments.sort(key=lambda s: (t[s.i0], METRICS.index(s.metric)))
    return a


# ---------------------------------------------------------------- 区間の数字

def jst(ts: float, ms=False) -> str:
    d = datetime.fromtimestamp(ts, JST)
    return d.strftime("%Y-%m-%d %H:%M:%S") + (f".{int(d.microsecond / 1000):03d}" if ms else "")


def scene_intervals(rec: Recording, t_end: float) -> list[tuple[float, float, str]]:
    out, cur, cur_t = [], None, None
    for e in rec.events:
        if e.get("kind") != "scene":
            continue
        ts, v = e["t_ms"] / 1000, e.get("value")
        if cur is not None:
            out.append((cur_t, ts, cur))
        cur, cur_t = (None if v in (None, "なし") else v), ts
    if cur is not None:
        out.append((cur_t, t_end, cur))
    return out


def marks(rec: Recording) -> list[tuple[float, str]]:
    return [(e["t_ms"] / 1000, str(e.get("value"))) for e in rec.events if e.get("kind") == "mark"]


def frame_dt(t: np.ndarray, cap=1.0) -> np.ndarray:
    """各コマが受け持つ時間（大きな空きは cap で切る）"""
    if len(t) < 2:
        return np.zeros(len(t))
    d = np.diff(t, append=t[-1] + np.median(np.diff(t)))
    return np.clip(d, 0, cap)


def segment_rows(a: Analysis) -> list[dict]:
    rec, t = a.rec, a.rec.t
    scenes = scene_intervals(rec, t[-1])
    mk = marks(rec)
    w = a.criteria["mark_window_s"]
    rows = []
    for s in a.segments:
        t0, t1 = t[s.i0], t[s.i1]
        b = rec.baselines[a.bidx[s.i0]]["metrics"][s.metric]
        sl = slice(s.i0, s.i1 + 1)
        sc = [name for (a0, a1, name) in scenes if a0 <= t1 and a1 >= t0]
        near = [f"{v}（{m_t - t0:+.1f}秒）" for (m_t, v) in mk if t0 - w <= m_t <= t1 + w]
        yaw = rec.yaw[sl]
        rows.append({
            "開始": jst(t0, ms=True), "終了": jst(t1, ms=True), "長さ_秒": round(t1 - t0, 2),
            "指標": s.metric, "指標名": LABEL[s.metric], "向き": direction(s.metric, s.sign),
            "ピークのz": round(s.peak_z, 2),
            "普段の平均": round(b["mean"], 4), "ピークの値": round(float(a.sm[s.metric][s.peak_i]), 4),
            "場面": "→".join(dict.fromkeys(sc)) or "なし",
            "前後の家族の印": "、".join(near) or "なし",
            "顔が映っていた割合": round(float(rec.face[sl].mean()), 2),
            "yawの平均": round(float(np.nanmean(yaw)), 1) if np.isfinite(yaw).any() else "",
            "備考": s.truncated,
        })
    return rows


def criteria_lines(c: dict) -> list[str]:
    out = [f"基準 version {c['version']}（criteria.json）"]
    if c.get("_overrides"):
        out.append("引数で変えた値: " + ", ".join(c["_overrides"]))
    for m in METRICS:
        mc = c["metrics"][m]
        out.append(f"{m}: ならし {mc['smooth_s']}秒 / 開始 |z|≥{mc['start_z']} が {mc['start_min_s']}秒以上 / "
                   f"終了 |z|<{mc['end_z']} が {mc['end_min_s']}秒 / std下限 {c['std_floor'][m]}")
    fv = c["face_valid"]
    out.append(f"表情の判定条件: 直近{fv['window_s']}秒で顔が映るコマ≥{fv['min_face_ratio']:.0%}、|yaw|<{fv['max_abs_yaw_deg']}°")
    out.append(f"{a_short(c)}秒未満で |z|≥開始値 になったものは「短い動き」として区間とは別に数える")
    n = c["notify"]
    out.append(f"通知候補（{'仮の値' if n.get('provisional') else ''}・実際には通知しない）: "
               f"A 表情と声が同時に区間に入って {n['cross_modal_s']:g}秒以上 / B 同じ指標の区間が {n['long_s']:g}秒以上 / "
               f"C {n['repeat_window_min']:g}分以内に同じ指標の区間が {n['repeat_count']}回以上 / "
               f"場面「{'・'.join(n['scene_separate'])}」の間は別に数える")
    return out


def a_short(c: dict) -> str:
    vals = sorted({c["metrics"][m]["start_min_s"] for m in METRICS})
    return "/".join(f"{v:g}" for v in vals)


def write_csv(path: Path, rows: list[dict], c: dict) -> None:
    cols = ["開始", "終了", "長さ_秒", "指標", "指標名", "向き", "ピークのz", "普段の平均", "ピークの値",
            "場面", "前後の家族の印", "顔が映っていた割合", "yawの平均", "備考"]
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        for line in criteria_lines(c):
            f.write(f"# {line}\n")
        wr = csv.DictWriter(f, fieldnames=cols)
        wr.writeheader()
        wr.writerows(rows)


# ---------------------------------------------------------------- 通知候補（実際には通知しない）

@dataclass
class Candidate:
    t: float            # 条件を満たした時刻
    rule: str           # A / B / C
    detail: str
    scene: str
    in_scene: bool      # 場面（食事・姿勢を変える・入浴・着替え）の最中


def candidates(a: Analysis) -> list[Candidate]:
    """A：表情と声が同時に区間に入って cross_modal_s 秒以上（同時の間をひとまとまりで1件）
    B：同じ指標の区間が long_s 秒以上（区間ごとに1件）
    C：repeat_window_min 分以内に同じ指標の区間が repeat_count 回（満たしたら数え直す）"""
    n, t = a.criteria["notify"], a.rec.t
    scenes = scene_intervals(a.rec, t[-1])

    def make(ts, rule, detail):
        sc = next((name for (s0, s1, name) in scenes if s0 <= ts < s1), None)
        return Candidate(ts, rule, detail, sc or "なし", sc in n["scene_separate"])

    out = []
    face_on, voice_on = np.zeros(len(t), bool), np.zeros(len(t), bool)
    for s in a.segments:
        (face_on if s.metric in FACE_METRICS else voice_on)[s.i0:s.i1 + 1] = True
    for t0, t1 in spans(face_on & voice_on, t):
        if t1 - t0 >= n["cross_modal_s"]:
            which = [f"{LABEL[s.metric]}が{direction(s.metric, s.sign)}" for s in a.segments
                     if t[s.i0] <= t1 and t[s.i1] >= t0]
            out.append(make(t0 + n["cross_modal_s"], "A",
                            f"表情と声の変化が同時に {t1 - t0:.0f}秒（{'、'.join(dict.fromkeys(which))}）"))
    for s in a.segments:
        dur = t[s.i1] - t[s.i0]
        if dur >= n["long_s"]:
            out.append(make(t[s.i0] + n["long_s"], "B",
                            f"{LABEL[s.metric]}が{direction(s.metric, s.sign)}区間が {dur:.0f}秒"))
    win = n["repeat_window_min"] * 60
    for m in METRICS:
        recent: list[float] = []
        for ts in sorted(t[s.i0] for s in a.segments if s.metric == m):
            recent = [x for x in recent if ts - x <= win] + [ts]
            if len(recent) >= n["repeat_count"]:
                out.append(make(ts, "C", f"{LABEL[m]}の区間が {(ts - recent[0]) / 60:.0f}分の間に {len(recent)}回"))
                recent = []
    out.sort(key=lambda x: x.t)
    return out


# ---------------------------------------------------------------- 記録の質

def quality(a: Analysis, calm: bool) -> dict:
    rec, t, c = a.rec, a.rec.t, a.criteria
    dt = frame_dt(t)
    q: dict = {"length_s": float(t[-1] - t[0]), "frames": len(t),
               "face_ratio": float(rec.face.mean()),
               "fps": (len(t) - 1) / max(t[-1] - t[0], 1e-9)}
    lat = rec.lat_ms[np.isfinite(rec.lat_ms)]
    proc = rec.proc_ms[np.isfinite(rec.proc_ms)]
    q["lat"] = (float(np.median(lat)), float(np.percentile(lat, 95))) if len(lat) else None
    q["proc"] = (float(np.median(proc)), float(np.percentile(proc, 95))) if len(proc) else None

    based = a.bidx >= 0
    q["judged_s"] = float(dt[based].sum())
    q["excluded_s"] = float(dt[based & ~a.fvalid].sum())
    q["excluded_ratio"] = q["excluded_s"] / q["judged_s"] if q["judged_s"] > 0 else None

    yaw = rec.yaw[np.isfinite(rec.yaw)]
    if len(yaw):
        ay = np.abs(yaw)
        q["yaw"] = {"p5": float(np.percentile(yaw, 5)), "median": float(np.median(yaw)), "p95": float(np.percentile(yaw, 95)),
                    "lt15": float((ay < 15).mean()), "15to35": float(((ay >= 15) & (ay < 35)).mean()),
                    "ge35": float((ay >= 35).mean())}

    # 何もしていない記録での区間の数（多すぎないかの目安）：普段がある時間の区間数
    minutes = q["judged_s"] / 60
    per = {}
    for m in METRICS:
        n = sum(1 for s in a.segments if s.metric == m)
        ns = len(a.shorts[m])
        per[m] = (n, ns)
    total = sum(v[0] for v in per.values())
    q["rates"] = {"minutes": minutes, "per_metric": per, "total": total,
                  "per_min": total / minutes if minutes > 0 else None,
                  "per_10min": total / minutes * 10 if minutes > 0 else None,
                  "target": c["calm_target_per_10min"], "calm": calm}

    # 印との対応：一番近い区間までの時間差（区間の中なら 0、区間より前なら −）
    rows = []
    for m_t, v in marks(rec):
        best = None
        for s in a.segments:
            t0, t1 = t[s.i0], t[s.i1]
            d = 0.0 if t0 <= m_t <= t1 else (m_t - t1 if m_t > t1 else m_t - t0)
            if best is None or abs(d) < abs(best[0]):
                best = (d, s)
        rows.append((m_t, v, best))
    q["mark_rows"] = rows

    cands = candidates(a)
    hours = q["judged_s"] / 3600
    q["candidates"] = cands
    q["cand_rate"] = {k: (len(v), len(v) / hours if hours > 0 else None) for k, v in
                      {"all": cands, "other": [x for x in cands if not x.in_scene],
                       "scene": [x for x in cands if x.in_scene]}.items()}
    return q


# ---------------------------------------------------------------- グラフ

def setup_matplotlib():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    names = {f.name for f in font_manager.fontManager.ttflist}
    for fam in ["Hiragino Sans", "Hiragino Kaku Gothic ProN", "Hiragino Maru Gothic Pro", "Yu Gothic", "Meiryo",
                "Noto Sans CJK JP", "Noto Sans JP", "IPAexGothic", "Hiragino Sans GB"]:
        if fam in names:
            plt.rcParams["font.family"] = [fam, "DejaVu Sans"]
            break
    plt.rcParams["axes.unicode_minus"] = False
    return plt


EPOCH_NUM = None


def to_num(ts):
    """epoch 秒 → matplotlib の日付の数値（横軸は日本時間で表示）"""
    global EPOCH_NUM
    import matplotlib.dates as mdates
    if EPOCH_NUM is None:
        EPOCH_NUM = mdates.date2num(datetime(1970, 1, 1, tzinfo=timezone.utc))
    return np.asarray(ts) / 86400.0 + EPOCH_NUM


def spans(mask: np.ndarray, t: np.ndarray) -> list[tuple[float, float]]:
    out, start = [], None
    for i, v in enumerate(mask):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((t[start], t[i])); start = None
    if start is not None:
        out.append((t[start], t[-1]))
    return out


# 場面の帯は、区間の色（橙・青）と紛れない落ち着いた色
# 色は docs/wording-guide.md に従う：赤と赤・黄・緑の組み合わせは使わない。
# いつもの範囲＝薄い青灰の帯、今の値＝濃紺の線、区間＝いつもより上はアンバー・下は青灰
SCENE_COLORS = ["#c2a5cf", "#b0bfd4", "#d6c2a3", "#c9c9c9", "#a7a3c9", "#d4b8c9"]
UP, DOWN = "#E69F00", "#5B7FA6"
RANGE, LINE = "#DCE3EA", "#1F3A5F"


@dataclass
class Track:
    """同じ時間軸に並べる1段。手首の記録（ability-lab.raw.v1）は、あとで Track を足して並べる（今は未実装）"""
    title: str
    draw: object        # (ax) -> None
    height: float = 1.6


def metric_track(a: Analysis, m: str, scene_color: dict) -> Track:
    rec, t, c = a.rec, a.rec.t, a.criteria

    def draw(ax):
        x = to_num(t)
        # 判定対象外（表情：顔が読めない・横向き）は灰色、普段が無い時間は薄い灰色
        for t0, t1 in spans(a.bidx < 0, t):
            ax.axvspan(to_num(t0), to_num(t1), color="#e6e6e6", lw=0)
        if m in FACE_METRICS:
            for t0, t1 in spans((a.bidx >= 0) & ~a.fvalid, t):
                ax.axvspan(to_num(t0), to_num(t1), color="#9e9e9e", alpha=0.45, lw=0)
        for s in a.segments:
            if s.metric == m:
                ax.axvspan(to_num(t[s.i0]), to_num(t[s.i1]), color=UP if s.sign > 0 else DOWN, alpha=0.3, lw=0)
        for t0, t1, name in scene_intervals(rec, t[-1]):
            ax.axvspan(to_num(t0), to_num(t1), ymin=0.93, ymax=1.0, color=scene_color[name], lw=0)
        mc = c["metrics"][m]
        ax.axhspan(-mc["start_z"], mc["start_z"], color=RANGE, lw=0, zorder=0)   # いつもの範囲
        ax.axhline(0, lw=0.5, color="#b8c2cc")
        z = np.where(a.judge[m], a.z[m], np.nan)
        step = max(1, len(t) // 20000)   # 長い記録は点を間引いて描く
        ax.plot(x[::step], z[::step], lw=0.9, color=LINE)
        for m_t, v in marks(rec):
            ax.axvline(to_num(m_t), color="#7570b3", lw=1)
        ax.set_ylabel("z")
        finite = z[np.isfinite(z)]
        lim = max(4.0, float(np.percentile(np.abs(finite), 99.5)) * 1.1) if len(finite) else 4.0
        ax.set_ylim(-lim, lim)
        ax.set_title(f"{LABEL[m]}（{m}）" + ("" if a.usable[m] else "：普段のデータ不足のため判定なし"),
                     loc="left", fontsize=10)

    return Track(LABEL[m], draw)


def figure_tracks(a: Analysis, tracks: list[Track]) -> str:
    plt = setup_matplotlib()
    import matplotlib.dates as mdates
    from matplotlib.patches import Patch
    from matplotlib.lines import Line2D
    t = a.rec.t
    fig, axes = plt.subplots(len(tracks), 1, figsize=(12, sum(tr.height for tr in tracks) + 0.8), sharex=True,
                             squeeze=False)
    axes = axes[:, 0]
    for ax, tr in zip(axes, tracks):
        tr.draw(ax)
    top = axes[0]
    for k, (m_t, v) in enumerate(marks(a.rec)):
        top.annotate(v, (to_num(m_t), 1.0), xycoords=("data", "axes fraction"), xytext=(2, 2 + 9 * (k % 2)),
                     textcoords="offset points", fontsize=8, color="#7570b3")
    axes[-1].xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S", tz=JST))
    axes[-1].set_xlim(to_num(t[0]), to_num(t[-1]))
    axes[-1].set_xlabel("日本時間")
    handles = [Patch(color=RANGE, label="いつもの範囲（|z|<開始値）"),
               Patch(color=UP, alpha=0.3, label="区間（いつもより上）"),
               Patch(color=DOWN, alpha=0.3, label="区間（いつもより下）"),
               Patch(color="#9e9e9e", alpha=0.45, label="判定対象外（表情）"),
               Patch(color="#e6e6e6", label="普段が無い時間"),
               Line2D([], [], color="#7570b3", label="家族の印"),
               Line2D([], [], color=LINE, label="z（ならした今の値）")]
    fig.legend(handles=handles, loc="lower center", ncol=7, fontsize=8, frameon=False)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    return fig_to_data(fig, plt)


def figure_yaw(a: Analysis) -> str | None:
    yaw = a.rec.yaw[np.isfinite(a.rec.yaw)]
    if not len(yaw):
        return None
    plt = setup_matplotlib()
    fig, ax = plt.subplots(figsize=(5, 2.2))
    ax.hist(yaw, bins=np.arange(-90, 91, 5), color="#666666")
    lim = a.criteria["face_valid"]["max_abs_yaw_deg"]
    for x in (-lim, lim):
        ax.axvline(x, ls="--", color=UP, lw=1)
    ax.set_xlabel("yaw（度、映像で見て右が +）")
    ax.set_ylabel("コマ数")
    fig.tight_layout()
    return fig_to_data(fig, plt)


def fig_to_data(fig, plt) -> str:
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=110)
    plt.close(fig)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


# ---------------------------------------------------------------- HTML

def table(head: list[str], rows: list[list]) -> str:
    e = html.escape
    h = "".join(f"<th>{e(str(x))}</th>" for x in head)
    b = "".join("<tr>" + "".join(f"<td>{e(str(x))}</td>" for x in r) + "</tr>" for r in rows)
    return f"<table><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table>"


def fmt_s(s: float) -> str:
    s = int(round(s))
    return f"{s // 3600}時間{s // 60 % 60}分{s % 60}秒" if s >= 3600 else f"{s // 60}分{s % 60}秒"


def write_html(path: Path, a: Analysis, q: dict, rows: list[dict], csv_name: str) -> None:
    rec, c, e = a.rec, a.criteria, html.escape
    parts = []
    parts.append(f"<h1>振り返りレポート</h1><p class=sub>{e(rec.path.name)}（{e(rec.header.get('schema', '?'))}）"
                 f" / {jst(rec.t[0])} 〜 {jst(rec.t[-1])}（日本時間）</p>")
    parts.append("<p class=note>記録から、観測された変化（いつもの範囲から数値が外れた区間）を確認するための手がかりです。"
                 "本人の気持ちや状態は判断していません。文言と色は docs/wording-guide.md に従っています。</p>")

    parts.append("<h2>使った基準</h2><ul>" + "".join(f"<li>{e(x)}</li>" for x in criteria_lines(c)) + "</ul>")
    if c.get("changelog"):
        parts.append(table(["日付", "変更の理由"], [[x.get("date", ""), x.get("reason", "")] for x in c["changelog"]]))

    # 記録の質
    pc = lambda x: "–" if x is None else f"{x:.0%}"
    ms = lambda v: "–" if v is None else f"{v[0]:.0f} / {v[1]:.0f}"
    qrows = [["記録の長さ", fmt_s(q["length_s"])], ["コマ数", q["frames"]],
             ["顔が映っていた割合", pc(q["face_ratio"])],
             ["普段がある時間（判定した時間）", fmt_s(q["judged_s"])],
             ["そのうち表情の判定対象外だった時間", f"{fmt_s(q['excluded_s'])}（{pc(q['excluded_ratio'])}）"],
             ["解析コマ/秒", f"{q['fps']:.1f}"],
             ["撮影→結果の遅れ ms（中央値 / 95%）", ms(q["lat"])],
             ["解析時間 ms（中央値 / 95%）", ms(q["proc"])]]
    if "yaw" in q:
        y = q["yaw"]
        qrows.append(["yaw の分布（5% / 中央値 / 95%）", f"{y['p5']:.0f}° / {y['median']:.0f}° / {y['p95']:.0f}°"])
        qrows.append(["|yaw| <15° / 15〜35° / ≥35°", f"{pc(y['lt15'])} / {pc(y['15to35'])} / {pc(y['ge35'])}"])
    else:
        qrows.append(["yaw", "記録に顔の向きがありません（v0.3 より前）"])
    parts.append("<h2>記録の質</h2>" + table(["項目", "値"], qrows))
    yimg = figure_yaw(a)
    if yimg:
        parts.append(f"<img class=small src='{yimg}' alt='yaw の分布'>")

    # 普段
    if rec.baselines:
        brows = []
        for b in rec.baselines:
            for m in METRICS:
                st = b.get("metrics", {}).get(m, {})
                f = lambda v: "" if v is None else f"{v:g}"
                brows.append([jst(b["t_ms"] / 1000), m, LABEL[m], st.get("n", ""), f(st.get("mean")), f(st.get("std")),
                              "データ不足（計算しない）" if st.get("insufficient") else ""])
        parts.append("<h2>普段（baseline）</h2>" + table(["記録し終えた時刻", "指標", "", "n", "mean", "std", ""], brows))
    else:
        parts.append("<h2>普段（baseline）</h2><p>普段の記録（type:\"baseline\"）が無いため、区間は判定できません。</p>")

    # 区間の数（--calm では、何もしていない記録で区間が多すぎないかの目安）
    r = q["rates"]
    rrows = [[m, LABEL[m], r["per_metric"][m][0], r["per_metric"][m][1]] for m in METRICS]
    rrows.append(["合計", "", r["total"], sum(v[1] for v in r["per_metric"].values())])
    head = "<h2>区間の数" + ("（何もしていない記録：多すぎないかの目安）" if r["calm"] else "") + "</h2>"
    rate = ("–" if r["per_min"] is None else
            f"判定した {r['minutes']:.1f}分 で {r['total']}件 = 1分あたり {r['per_min']:.2f}件 / 10分あたり {r['per_10min']:.1f}件")
    if r["calm"] and r["per_10min"] is not None:
        verdict = "目安以内" if r["per_10min"] <= r["target"] else "目安を超えています"
        rate += f"（目安：10分に{r['target']:g}回以下 → {verdict}）"
    parts.append(head + f"<p>{e(rate)}</p>" + table(["指標", "", "区間", "短い動き"], rrows))

    # 印との対応
    if q["mark_rows"]:
        mrows = []
        for m_t, v, best in q["mark_rows"]:
            if best is None:
                mrows.append([jst(m_t), v, "区間なし", ""])
            else:
                d, s = best
                where = "区間の中" if d == 0 else (f"区間の終わりの {d:.1f}秒後" if d > 0 else f"区間の始まりの {-d:.1f}秒前")
                mrows.append([jst(m_t), v, f"{LABEL[s.metric]}が{direction(s.metric, s.sign)}（{jst(rec.t[s.i0])}〜）", where])
        parts.append("<h2>家族の印と区間（一番近い区間）</h2>" + table(["時刻", "家族の印", "区間", "時間差"], mrows))

    # 通知候補
    n = c["notify"]
    cr = q["cand_rate"]
    per_h = lambda k: "–" if cr[k][1] is None else f"{cr[k][0]}件（1時間あたり {cr[k][1]:.1f}件）"
    parts.append("<h2>通知候補（実際には通知しません）</h2>"
                 f"<p class=note>{'基準はすべて仮の値です（criteria.json で変えられます）。' if n.get('provisional') else ''}"
                 "通知の条件を決める前に、候補がどれくらい出るか（多すぎないか）を見るためのものです。</p>"
                 f"<ul><li>A：表情と声の変化が同時に区間に入って {n['cross_modal_s']:g}秒以上続いた</li>"
                 f"<li>B：同じ指標の区間が {n['long_s']:g}秒以上続いた</li>"
                 f"<li>C：{n['repeat_window_min']:g}分以内に同じ指標の区間が {n['repeat_count']}回以上</li></ul>"
                 + table(["", "件数"], [["すべて", per_h("all")], ["場面の外", per_h("other")],
                                        [f"場面の最中（{'・'.join(n['scene_separate'])}）", per_h("scene")]]))
    for title, group in [("場面の外", [x for x in q["candidates"] if not x.in_scene]),
                         (f"場面の最中（{'・'.join(n['scene_separate'])}）", [x for x in q["candidates"] if x.in_scene])]:
        parts.append(f"<h3>{e(title)}（{len(group)}件）</h3>"
                     + (table(["時刻", "条件", "内容", "場面"], [[jst(x.t), x.rule, x.detail, x.scene] for x in group])
                        if group else "<p>ありません。</p>"))

    # グラフ
    scene_names = list(dict.fromkeys(n for _, _, n in scene_intervals(rec, rec.t[-1])))
    scene_color = {n: SCENE_COLORS[i % len(SCENE_COLORS)] for i, n in enumerate(scene_names)}
    tracks = [metric_track(a, m, scene_color) for m in METRICS]
    # ここに手首の記録の Track を足せば、同じ時間軸に並ぶ（今は未実装）
    img = figure_tracks(a, tracks)
    legend = "".join(f"<span class=chip style='background:{col}'>{e(n)}</span>" for n, col in scene_color.items())
    parts.append("<h2>z の時系列</h2>" + (f"<p>場面（各段の上の帯）：{legend}</p>" if legend else "")
                 + f"<img src='{img}' alt='指標ごとの z の時系列'>")

    # 区間の表
    cols = ["開始", "終了", "長さ_秒", "指標名", "向き", "ピークのz", "普段の平均", "ピークの値", "場面", "前後の家族の印",
            "顔が映っていた割合", "yawの平均", "備考"]
    body = [[rw[k] if k != "普段の平均" else f"{rw['普段の平均']:g}{UNIT.get(rw['指標'], '')} → {rw['ピークの値']:g}{UNIT.get(rw['指標'], '')}"
             for k in cols if k != "ピークの値"] for rw in rows]
    parts.append(f"<h2>区間の一覧（{len(rows)}件）</h2><p class=sub>CSV：{e(csv_name)}</p>"
                 + (table([k if k != "普段の平均" else "普段の平均 → ピークの値" for k in cols if k != "ピークの値"], body)
                    if rows else "<p>区間はありません。</p>"))

    css = """
    :root{--fg:#1a1a1a;--sub:#666;--bg:#fff;--line:#ddd}
    @media (prefers-color-scheme: dark){:root{--fg:#eee;--sub:#aaa;--bg:#161616;--line:#333} img{background:#fff}}
    body{font-family:-apple-system,"Hiragino Sans","Yu Gothic",sans-serif;color:var(--fg);background:var(--bg);
         max-width:1200px;margin:24px auto;padding:0 16px;line-height:1.6}
    h1{font-size:1.5em;margin-bottom:0} h3{font-size:1em;margin-top:1.2em} h2{font-size:1.15em;margin-top:2em;border-bottom:1px solid var(--line)}
    .sub{color:var(--sub);font-size:.9em;margin-top:4px} .note{color:var(--sub)}
    table{border-collapse:collapse;font-size:.85em;margin:8px 0;display:block;overflow-x:auto}
    th,td{border:1px solid var(--line);padding:4px 8px;text-align:left;white-space:nowrap}
    img{max-width:100%} img.small{max-width:480px}
    .chip{display:inline-block;padding:0 8px;margin-right:6px;border-radius:4px;color:#000}
    """
    doc = (f"<!doctype html><html lang=ja><head><meta charset=utf-8>"
           f"<meta name=viewport content='width=device-width,initial-scale=1'><title>振り返りレポート</title>"
           f"<style>{css}</style></head><body>{''.join(parts)}</body></html>")
    path.write_text(doc, encoding="utf-8")


# ---------------------------------------------------------------- main

def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Ability Cam の記録の振り返りレポート（普段から外れた区間）")
    p.add_argument("jsonl", type=Path)
    p.add_argument("--calm", action="store_true", help="「何もしていない記録」として、区間が多すぎないかの目安を出す")
    p.add_argument("--criteria", type=Path, default=HERE / "criteria.json")
    p.add_argument("--set", action="append", default=[], metavar="指標.項目=値",
                   help="基準を変える（例 brow_down.start_min_s=0.8、all.smooth_s=0.5）。項目：" + ", ".join(CRITERIA_KEYS))
    for k in CRITERIA_KEYS:
        p.add_argument("--" + k.replace("_", "-"), type=float, help=f"すべての指標の {k} を変える")
    p.add_argument("--out-dir", type=Path, help="出力先（省略時は記録と同じ場所）")
    args = p.parse_args(argv)

    overrides = list(args.set) + [f"all.{k}={getattr(args, k)}" for k in CRITERIA_KEYS if getattr(args, k) is not None]
    c = load_criteria(args.criteria, overrides)
    rec = load(args.jsonl)
    a = analyze(rec, c)
    rows = segment_rows(a)
    q = quality(a, args.calm)

    out = args.out_dir or args.jsonl.parent
    out.mkdir(parents=True, exist_ok=True)
    csv_path = out / f"{args.jsonl.stem}_segments.csv"
    html_path = out / f"{args.jsonl.stem}.html"
    write_csv(csv_path, rows, c)
    write_html(html_path, a, q, rows, csv_path.name)
    print(f"区間 {len(rows)}件 → {html_path} / {csv_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
