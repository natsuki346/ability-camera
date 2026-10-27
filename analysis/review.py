#!/usr/bin/env python3
"""Ability Cam の記録（JSONL）の振り返りレポート。

普段（type:"baseline"）から外れた区間を、数値の事実として出す。状態の名前は付けない。
出力：<記録>.html（画像は埋め込み、1ファイル）と <記録>_segments.csv。外部には何も送らない。

使い方：python review.py 記録.jsonl [--calm] [--criteria criteria.json] [--set brow_down.start_min_s=0.8]
        [--baseline-s 30] [--compare-baseline 30,60]
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
    blink: np.ndarray                # まばたき（eyeBlinkLeft/Right の平均、顔が無いコマは NaN）
    lat_ms: np.ndarray
    proc_ms: np.ndarray
    baselines: list[dict]
    events: list[dict]
    baseline_source: str = "記録の baseline 行（アプリが記録したもの）"
    all_baselines: list[dict] = field(default_factory=list)   # 比べるのに使わなかった行（compared: false）も含む
    pairs: dict[str, np.ndarray] = field(default_factory=dict)   # 表情の数値 52種を左右平均したもの（browDown など。顔が無いコマは NaN）

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
    yaw, lat, proc, blink = (np.full(n, np.nan) for _ in range(4))
    face = np.zeros(n, bool)
    pairs: dict[str, np.ndarray] = {}
    for i, o in enumerate(frames):
        if o.get("face") and o.get("bs"):
            face[i] = True
            for m, v in face_values(o["bs"]).items():
                raw[m][i] = v
            bs = o["bs"]
            blink[i] = ((bs.get("eyeBlinkLeft") or 0) + (bs.get("eyeBlinkRight") or 0)) / 2
            for k, v in bs.items():
                if k.endswith("Right") and k[:-5] + "Left" in bs:
                    continue
                if k.endswith("Left"):
                    base = k[:-4]
                    v = ((v or 0) + (bs.get(base + "Right") or 0)) / 2
                else:
                    base = k
                if base not in pairs:
                    pairs[base] = np.full(n, np.nan)
                pairs[base][i] = v or 0
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
    # v1.2〜：保存した普段（source: "saved"）で比べたときは、今日の普段の行も compared: false で書かれる。
    # 区間はアプリと同じく、比べるのに使った行（compared が false でないもの）で判定する
    used = [b for b in baselines if b.get("compared", True) is not False]
    return Recording(path, header, t, face, raw, yaw, blink, lat, proc, used, events, pairs=pairs, all_baselines=baselines)


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


# アプリ（AnalysisModel）が普段に数える条件
BASELINE_YAW_LIMIT, BASELINE_WARMUP_S, BASELINE_MIN_N = 35.0, 5.0, 30


def blink_mask(rec: Recording, c: dict | None) -> np.ndarray:
    """eye_squint を判定対象外にするコマ：まばたき（eyeBlinkLeft/Right の平均）が threshold 以上のコマと、その前後 pad_s 秒。
    criteria.json の metrics.eye_squint.blink_mask。無ければ（または c が None なら）外さない"""
    bm = (c or {}).get("metrics", {}).get("eye_squint", {}).get("blink_mask") if c else None
    out = np.zeros(len(rec.t), bool)
    if not bm:
        return out
    hit = rec.t[np.nan_to_num(rec.blink, nan=0.0) >= bm["threshold"]]
    if not len(hit):
        return out
    pos = np.searchsorted(hit, rec.t)
    left = np.abs(rec.t - hit[np.clip(pos - 1, 0, len(hit) - 1)])
    right = np.abs(hit[np.clip(pos, 0, len(hit) - 1)] - rec.t)
    return np.minimum(left, right) <= bm["pad_s"] + 1e-9


def baseline_candidates(rec: Recording) -> tuple[np.ndarray, np.ndarray, float]:
    """アプリが普段を数えるときの、各コマの状態。
    processed：アプリが数えるコマ（画面の更新に合わせて3コマに1コマ。カメラを止めた後＝1秒より空いた後は数え直す）
    valid：普段に数える条件（直近1秒で顔が映るコマが半分以上・そのコマに顔がある・|yaw|<35°・開いてから5秒より後）
    返り値：(processed, valid, 記録の始まりの時刻)"""
    t = rec.t
    start0 = rec.header.get("started_at_ms")
    start0 = start0 / 1000 if start0 else float(t[0])
    cum = np.concatenate([[0], np.cumsum(rec.face)])
    lo = np.searchsorted(t, t - 1.0, side="left")
    idx = np.arange(len(t))
    readable = (cum[idx + 1] - cum[lo]) * 2 >= (idx + 1 - lo)
    processed = np.zeros(len(t), bool)
    k, prev = 0, None
    for i in range(len(t)):
        k = 1 if prev is None or t[i] - prev > 1.0 else k + 1
        prev = t[i]
        processed[i] = k % 3 == 0
    with np.errstate(invalid="ignore"):
        facing = np.abs(rec.yaw) < BASELINE_YAW_LIMIT
    valid = processed & (t - start0 >= BASELINE_WARMUP_S) & readable & rec.face & facing
    return processed, valid, start0


def baseline_stat(x: np.ndarray) -> dict:
    n = len(x)
    st = {"n": n, "insufficient": n < BASELINE_MIN_N}
    if n:
        st["mean"] = round(float(x.mean()), 4)
        st["std"] = round(float(x.std(ddof=1)) if n > 1 else 0.0, 4)
    return st


def mask_baselines_blink(rec: Recording, c: dict) -> tuple[list[dict], str | None]:
    """アプリが記録した baseline 行の eye_squint は、まばたきのコマも入っている。
    blink_mask があれば、その普段を集めた時間（started_ms〜t_ms）のコマから、まばたきのコマを外して eye_squint だけ数え直す。
    返り値：(baseline 行, 数え直せなかった理由)"""
    if not blink_mask_on(c) or not rec.baselines:
        return rec.baselines, None
    if not rec.has_pose:
        return rec.baselines, "顔の向きが無い記録（v0.3 より前）なので、目を細めるの普段はまばたきを外さずに使っています"
    processed, valid, _ = baseline_candidates(rec)
    keep = valid & ~blink_mask(rec, c) & np.isfinite(rec.raw["eye_squint"])
    out, missing = [], False
    for b in rec.baselines:
        if b.get("blink_masked"):
            out.append(b)
            continue
        if b.get("started_ms") is None:
            out.append(b); missing = True
            continue
        sel = keep & (rec.t >= b["started_ms"] / 1000) & (rec.t <= b["t_ms"] / 1000 + 1e-6)
        nb = copy.deepcopy(b)
        nb["metrics"]["eye_squint"] = baseline_stat(rec.raw["eye_squint"][sel])
        nb["blink_masked"] = True
        nb["eye_squint_app"] = b.get("metrics", {}).get("eye_squint")
        out.append(nb)
    return out, ("記録し始めた時刻が無い baseline 行は、目を細めるの普段をまばたきを外さずに使っています" if missing else None)


def blink_mask_on(c: dict | None) -> bool:
    return bool(c and c.get("metrics", {}).get("eye_squint", {}).get("blink_mask"))


def rebuild_baselines(rec: Recording, target_s: float, c: dict | None = None) -> list[dict]:
    """記録の中の1コマごとの値から、普段を target_s 秒（数えた時間）で作り直す。アプリと同じ条件：
    直近1秒で顔が映るコマが半分以上・そのコマに顔がある・|yaw|<35°・開いてから5秒より後。
    普段は記録の始まりと「普段を取り直す」（baseline_restart）から集め始める。
    アプリは画面の更新に合わせて3コマに1コマで数えるので、ここでも（カメラを止めた後は数え直して）3コマに1コマで数える。
    数えた時間は、前に数えたコマからの幅（0.5秒で切る）を足していく。std は標本標準偏差。
    声は、そのコマに書かれている値を使う（アプリは新しく計算した音だけを数えるので、n は少しずれることがある）"""
    t = rec.t
    processed, valid_arr, start0 = baseline_candidates(rec)
    starts = sorted([start0] + [e["t_ms"] / 1000 for e in rec.events if e.get("kind") == "baseline_restart"])
    blinked = blink_mask(rec, c)

    out: list[dict] = []
    period = -1
    vals: dict[str, list[float]] = {}
    valid_s, last, done = 0.0, None, False
    for i in range(len(t)):
        ti = float(t[i])
        p = int(np.searchsorted(starts, ti, side="right")) - 1
        if p != period:
            period, vals, valid_s, last, done = p, {m: [] for m in METRICS}, 0.0, None, False
        if done or p < 0 or not processed[i]:
            continue
        valid = bool(valid_arr[i])
        if valid and last is not None and ti > last:
            valid_s += min(ti - last, 0.5)
        last = ti
        if valid:
            for m in METRICS:
                v = rec.raw[m][i]
                if v == v and not (m == "eye_squint" and blinked[i]):
                    vals[m].append(float(v))
        if valid_s >= target_s:
            out.append({"type": "baseline", "t_ms": int(round(ti * 1000)), "started_ms": int(round(starts[p] * 1000)),
                        "wall_s": round(ti - starts[p], 1), "valid_s": round(valid_s, 1),
                        "yaw_limit_deg": BASELINE_YAW_LIMIT, "warmup_s": BASELINE_WARMUP_S, "min_n": BASELINE_MIN_N,
                        "target_s": target_s, "rebuilt": True, "blink_masked": blink_mask_on(c),
                        "metrics": {m: baseline_stat(np.array(vals[m])) for m in METRICS}})
            done = True
    return out


def with_baseline(rec: Recording, target_s: float, c: dict | None = None) -> Recording:
    r = copy.copy(rec)
    r.baselines = rebuild_baselines(rec, target_s, c)
    r.baseline_source = f"記録の中の1コマごとの値から {target_s:g}秒で作り直したもの（--baseline-s）"
    return r


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
    weak_segments: list[Segment] = field(default_factory=list)  # 表情の「いつもより弱い」（face_below_counts=false のとき、違いに数えない）
    shorts: dict[str, list[tuple[int, int]]] = field(default_factory=dict)
    usable: dict[str, bool] = field(default_factory=dict)        # 普段にデータがあったか（insufficient でない）
    blinked: np.ndarray | None = None                            # 目を細めるを判定対象外にした、まばたきのコマ
    blink_note: str | None = None


def analyze(rec: Recording, c: dict) -> Analysis:
    # 目を細める：まばたきのコマ（と前後）は値を使わず、判定対象外にする。普段からも外す
    blinked = blink_mask(rec, c)
    note = None
    if blink_mask_on(c):
        rec = copy.copy(rec)
        rec.raw = dict(rec.raw)
        rec.raw["eye_squint"] = np.where(blinked, np.nan, rec.raw["eye_squint"])
        rec.baselines, note = mask_baselines_blink(rec, c)
    a = Analysis(rec, c, baseline_index(rec), face_valid(rec, c))
    a.blinked, a.blink_note = blinked, note
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
        if m == "eye_squint":
            ok &= ~blinked
        a.judge[m] = ok
        segs, shorts = detect(t, a.z[m], ok, mc)
        for s in segs:
            s.metric = m
        if m in FACE_METRICS and not c.get("face_below_counts", False):
            # アプリは表情の「いつもより強い」だけを違いとして出すので、弱い方は参考として別にする
            a.weak_segments += [x for x in segs if x.sign < 0]
            segs = [x for x in segs if x.sign > 0]
        a.segments += segs
        a.shorts[m] = shorts
    a.segments.sort(key=lambda s: (t[s.i0], METRICS.index(s.metric)))
    a.weak_segments.sort(key=lambda s: (t[s.i0], METRICS.index(s.metric)))
    return a


# ---------------------------------------------------------------- 顔の向き（head_turn）

HEAD_SIDE_DEG, HEAD_FRONT_DEG, HEAD_HOLD_S = 35.0, 15.0, 0.5
HEAD_LABEL = {"front": "正面", "right": "右（35°超）", "left": "左（35°超）", "hidden": "見えない",
              "oblique": "斜め（見えるようになったあと 15〜35°）", "unknown": "まだ決まっていない"}
HEAD_ORDER = ["front", "right", "left", "hidden", "oblique", "unknown"]
# 色は見る側の「時間の流れ」と同じ（docs/wording-guide.md：赤と赤・黄・緑の組み合わせは使わない）
HEAD_COLOR = {"front": "#DCE3EA", "right": "#5B7FA6", "left": "#B8A07A", "hidden": "#7D848C",
              "oblique": "#C9C4D9", "unknown": "#ffffff"}


def _head_side(yaw: float) -> str:
    if abs(yaw) < HEAD_FRONT_DEG:
        return "正面"
    return f"{'右' if yaw > 0 else '左'} {int(round(abs(yaw)))}°"


def head_text(to: str, yaw: float | None) -> str:
    """アプリ（HeadTurnTracker.text）と同じ value"""
    if to == "right":
        return "右へ"
    if to == "left":
        return "左へ"
    if to == "front":
        return "正面に戻った"
    if to == "hidden":
        return "見えなくなった" if yaw is None else f"見えなくなった（直前は{_head_side(yaw)}）"
    return f"見えるようになった（{'斜め' if yaw is None else _head_side(yaw)}）"


def head_states(t: np.ndarray, face: np.ndarray, yaw: np.ndarray, gap_s: float = 1.0):
    """アプリの HeadTurnTracker と同じ決まりで、各コマの顔の向きと、向きが変わったところを求める。
    正面は |yaw|<15°、横は |yaw|>35°、その間は今の向きを続ける（見えなかったあとなら「斜め」）。0.5秒続いたら決まり、
    その向きになり始めた時刻に遡って塗る。コマの間が gap_s 秒より空いたら（カメラを止めていた）、決まっていない状態から数え直す。
    返り値：(各コマの向き, 変わったところ [{t, from, to, yaw, value}]（最初に決まったときは含めない）)"""
    starts: list[tuple[float, str]] = []
    changes: list[dict] = []
    state = None
    pending = None          # (向き, 始まりの時刻, yaw)
    last_yaw = None
    prev_t = None
    for i in range(len(t)):
        ti = float(t[i])
        if prev_t is not None and ti - prev_t > gap_s:
            state, pending, last_yaw = None, None, None
            starts.append((prev_t + 1e-6, "unknown"))
        prev_t = ti
        f = bool(face[i])
        y = None if yaw[i] != yaw[i] else float(yaw[i])
        if f and y is None:
            continue
        if not f:
            target = "hidden"
        elif y > HEAD_SIDE_DEG:
            target = "right"
        elif y < -HEAD_SIDE_DEG:
            target = "left"
        elif abs(y) < HEAD_FRONT_DEG:
            target = "front"
        else:
            target = "oblique" if state in (None, "hidden") else state
        before = last_yaw
        if f:
            last_yaw = y
        if target == state:
            pending = None
            continue
        if pending is None or pending[0] != target:
            pending = (target, ti, before if target == "hidden" else y)
        if ti - pending[1] >= HEAD_HOLD_S:
            if state is not None:
                changes.append({"t": pending[1], "from": state, "to": target, "yaw": pending[2],
                                "value": head_text(target, pending[2])})
            starts.append((pending[1], target))
            state, pending = target, None
    out = np.full(len(t), "unknown", dtype=object)
    if starts:
        times = np.array([x[0] for x in starts])
        pos = np.searchsorted(times, t, side="right") - 1
        for i, k in enumerate(pos):
            if k >= 0:
                out[i] = starts[k][1]
    return out, changes


def head_events(rec: Recording) -> list[dict]:
    """記録に書かれた head_turn（v0.8〜）"""
    return [e for e in rec.events if e.get("kind") == "head_turn"]


def camera_label(rec: Recording) -> str:
    """記録のヘッダの camera（v0.8〜）。途中で切り替えたら camera の event"""
    code = rec.header.get("camera")
    names = {"wide": "広角", "ultra_wide": "超広角"}
    first = names.get(code, code) if code else "広角（記録にカメラが書かれていない v0.8 より前の記録）"
    later = [f"{jst(e['t_ms'] / 1000)} に{e.get('value') or names.get(e.get('camera'), '?')}へ"
             for e in rec.events if e.get("kind") == "camera"]
    return first + (f"（{'、'.join(later)}）" if later else "")


def uses_ultra_wide(rec: Recording) -> bool:
    return rec.header.get("camera") == "ultra_wide" or any(
        e.get("kind") == "camera" and e.get("camera") == "ultra_wide" for e in rec.events)


# ---------------------------------------------------------------- 研究用の複合値（PSPI 型）

RC_NAME = "上半分の顔の動きの合計（PSPI 型・研究用）"


def _runs(mask: np.ndarray) -> list[tuple[int, int]]:
    out, start = [], None
    for i, v in enumerate(mask):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start, i - 1)); start = None
    if start is not None:
        out.append((start, len(mask) - 1))
    return out


@dataclass
class Composite:
    value: np.ndarray                 # 1コマごとの合計（判定対象外・普段が無いコマは NaN）
    smooth: np.ndarray                # グラフ用にならしたもの
    means: list[dict]                 # baseline 行ごとの、各値の普段の平均（数え直したもの）
    closed: np.ndarray                # 目を閉じている（eyeBlink ≥ threshold が min_s 秒以上続いた）コマ
    mark_rows: list[dict]             # 家族の印ごとの前後の平均
    no_mark_mean: float | None
    no_mark_n: int
    by_value: dict[str, tuple[int, float | None]]


def research_composite(a: "Analysis") -> Composite | None:
    """上半分の顔の動きの合計（PSPI 型・研究用）。区間の判定や通知候補には使わない。
    1コマごとに、普段からの差（今の値 − 普段の平均、マイナスは 0）で、groups のそれぞれ（中で一番大きいもの）と、
    目を閉じている間の eyeBlink の差を、重みを付けずに足す。eyeSquint はまばたきのコマを除く（blink_mask）。
    普段の平均は、記録の baseline 行の時間（started_ms〜t_ms）のコマから、アプリと同じ条件で数え直す"""
    rec, c, t = a.rec, a.criteria, a.rec.t
    rc = c.get("research_composite")
    if not rc or not rc.get("enabled", True) or not rec.pairs or not rec.has_pose:
        return None
    groups: list[list[str]] = rc["groups"]
    ec = rc["eye_closed"]
    keys = sorted({k for g in groups for k in g} | {"eyeBlink"})
    vals = {k: rec.pairs.get(k, np.full(len(t), np.nan)).copy() for k in keys}
    if "eyeSquint" in vals and a.blinked is not None:
        vals["eyeSquint"][a.blinked] = np.nan        # まばたきのコマは目を細めるに入れない

    _, valid, _ = baseline_candidates(rec)
    mean = {k: np.full(len(t), np.nan) for k in keys}
    means = []
    for bi, b in enumerate(rec.baselines):
        if b.get("started_ms") is None:
            means.append({"t_ms": b["t_ms"], "values": {}})
            continue
        win = valid & (t >= b["started_ms"] / 1000) & (t <= b["t_ms"] / 1000 + 1e-6)
        mv = {}
        for k in keys:
            x = vals[k][win]
            x = x[np.isfinite(x)]
            if len(x) >= BASELINE_MIN_N:
                mv[k] = round(float(x.mean()), 4)
                mean[k][a.bidx == bi] = mv[k]
        means.append({"t_ms": b["t_ms"], "values": mv, "n": int(win.sum())})

    diff = {k: np.clip(vals[k] - mean[k], 0, None) for k in keys}   # NaN は NaN のまま
    total = np.zeros(len(t))
    for g in groups:
        stack = np.vstack([diff[k] for k in g])
        with np.errstate(all="ignore"):
            gv = np.fmax.reduce(stack, axis=0)          # 片方が NaN（まばたき）なら、もう片方
        total = total + gv                              # どれも NaN なら NaN
    blinkv = rec.pairs.get("eyeBlink", np.full(len(t), np.nan))
    closed = np.zeros(len(t), bool)
    for i0, i1 in _runs(np.nan_to_num(blinkv, nan=0.0) >= ec["threshold"]):
        if t[i1] - t[i0] >= ec["min_s"]:
            closed[i0:i1 + 1] = True                    # 短いまばたきは入れない
    total = total + np.where(closed, np.nan_to_num(diff["eyeBlink"], nan=0.0), 0.0)
    ok = a.fvalid & (a.bidx >= 0)
    value = np.where(ok, total, np.nan)
    sm = smooth(t, value, rc["smooth_s"], c["stale_s"])

    # 家族の印との照らし合わせ
    w = rc["mark_window_s"]
    mk = [(e["t_ms"] / 1000, str(e.get("value")), e) for e in rec.events if e.get("kind") == "mark"]
    near_any = np.zeros(len(t), bool)
    rows = []
    for m_t, v, e in mk:
        sel = (t >= m_t - w) & (t <= m_t + w)
        near_any |= sel
        x = value[sel]
        x = x[np.isfinite(x)]
        label = f"{v}（{e.get('by') or '見る側'}で）" if e.get("source") == "viewer" else v
        rows.append({"t": m_t, "value": v, "label": label, "n": len(x), "mean": float(x.mean()) if len(x) else None})
    rest = value[~near_any]
    rest = rest[np.isfinite(rest)]
    by_value = {}
    for v in dict.fromkeys(r["value"] for r in rows):
        xs = [r["mean"] for r in rows if r["value"] == v and r["mean"] is not None]
        by_value[v] = (sum(1 for r in rows if r["value"] == v), float(np.mean(xs)) if xs else None)
    return Composite(value, sm, means, closed, rows, float(rest.mean()) if len(rest) else None, len(rest), by_value)


# 指標に使っている表情の数値（左右平均の名前）
METRIC_PAIRS = {"mouth_smile": "mouthSmile", "brow_down": "browDown", "eye_squint": "eyeSquint", "jaw_open": "jawOpen"}
MISSING_MAX = 0.01   # 記録全体の最大値がこれ未満なら「値が出ていない」


def missing_values(a: "Analysis") -> list[str]:
    """研究用の合計と指標に使っている表情の数値のうち、記録全体でいつも0に近いもの（最大値 < 0.01）。
    MediaPipe が出していない数値に気づけるようにする。顔が映ったコマが無い記録では調べない"""
    rec, c = a.rec, a.criteria
    if not rec.face.any():
        return []
    keys = list(METRIC_PAIRS.values())
    rc = c.get("research_composite")
    if rc and rc.get("enabled", True):
        keys += [k for g in rc["groups"] for k in g] + ["eyeBlink"]
    out = []
    for k in dict.fromkeys(keys):
        x = rec.pairs.get(k)
        x = x[np.isfinite(x)] if x is not None else np.array([])
        if not len(x) or float(x.max()) < MISSING_MAX:
            out.append(k)
    return out


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
    """見る側で押した印は、押した端末の名前を付ける（v0.5〜：source="viewer", by）"""
    def label(e):
        v = str(e.get("value"))
        return f"{v}（{e.get('by') or '見る側'}で）" if e.get("source") == "viewer" else v
    return [(e["t_ms"] / 1000, label(e)) for e in rec.events if e.get("kind") == "mark"]


def frame_dt(t: np.ndarray, cap=1.0) -> np.ndarray:
    """各コマが受け持つ時間（大きな空きは cap で切る）"""
    if len(t) < 2:
        return np.zeros(len(t))
    d = np.diff(t, append=t[-1] + np.median(np.diff(t)))
    return np.clip(d, 0, cap)


def segment_rows(a: Analysis, segs: list[Segment] | None = None, kind: str = "違い") -> list[dict]:
    rec, t = a.rec, a.rec.t
    scenes = scene_intervals(rec, t[-1])
    mk = marks(rec)
    w = a.criteria["mark_window_s"]
    rows = []
    for s in (a.segments if segs is None else segs):
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
            "備考": s.truncated, "区分": kind,
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
    out.append("表情の「いつもより弱い」区間：" + ("区間に数える" if c.get("face_below_counts", False)
               else "区間・通知候補・10分あたりには数えず、「表情の弱い方への変化（参考）」として別に出す（アプリと同じ。face_below_counts=false）"))
    bm = c["metrics"]["eye_squint"].get("blink_mask")
    if bm:
        out.append(f"目を細める（eye_squint）：まばたき（eyeBlinkLeft/Right の平均）が {bm['threshold']:g} 以上のコマと前後 {bm['pad_s']:g}秒は"
                   "判定対象外（普段にも数えない）")
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
    cols = ["区分", "開始", "終了", "長さ_秒", "指標", "指標名", "向き", "ピークのz", "普段の平均", "ピークの値",
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
    if a.blinked is not None and blink_mask_on(c):
        bl = based & a.fvalid & a.blinked
        q["blink_s"] = float(dt[bl].sum())
        q["blink_ratio"] = q["blink_s"] / q["judged_s"] if q["judged_s"] > 0 else None

    q["missing"] = missing_values(a)

    yaw = rec.yaw[np.isfinite(rec.yaw)]
    if len(yaw):
        ay = np.abs(yaw)
        q["yaw"] = {"p5": float(np.percentile(yaw, 5)), "median": float(np.median(yaw)), "p95": float(np.percentile(yaw, 95)),
                    "lt15": float((ay < 15).mean()), "15to35": float(((ay >= 15) & (ay < 35)).mean()),
                    "ge35": float((ay >= 35).mean())}

    # 顔の向き：アプリと同じ決まりで、1コマごとの向きから数え直した時間の割合
    if rec.has_pose:
        states, _ = head_states(t, rec.face, rec.yaw)
        total = float(dt.sum())
        q["head"] = {k: (float(dt[states == k].sum()), float(dt[states == k].sum()) / total if total > 0 else None)
                     for k in HEAD_ORDER}
        q["head_states"] = states

    # 区間の数：普段がある時間（判定した時間）あたり。--calm（何もしていない記録）では10分あたりも出す（比べる目安は置かない）
    minutes = q["judged_s"] / 60
    per = {}
    for m in METRICS:
        n = sum(1 for s in a.segments if s.metric == m)
        ns = len(a.shorts[m])
        per[m] = (n, ns, sum(1 for s in a.weak_segments if s.metric == m))
    total = sum(v[0] for v in per.values())
    q["rates"] = {"minutes": minutes, "per_metric": per, "total": total,
                  "per_min": total / minutes if minutes > 0 else None,
                  "per_10min": total / minutes * 10 if minutes > 0 else None,
                  "calm": calm}

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


def compare_baselines(rec: Recording, c: dict, lengths: list[float]) -> list[dict]:
    """記録の baseline 行と、指定の長さで作り直した普段のそれぞれで、区間を数える"""
    rows = []
    for label, r in [("記録の baseline 行（アプリ）", rec)] + [(f"{L:g}秒で作り直し", with_baseline(rec, L, c)) for L in lengths]:
        a = analyze(r, c)
        dt = frame_dt(r.t)
        judged = float(dt[a.bidx >= 0].sum())
        total = len(a.segments)
        rows.append({"label": label, "length_s": None if r is rec else label,
                     "baselines": "、".join(jst(b["t_ms"] / 1000) for b in r.baselines) or "作れなかった（数えた時間が足りない）",
                     "judged_s": judged, "total": total, "shorts": sum(len(v) for v in a.shorts.values()),
                     "per_metric": {m: sum(1 for x in a.segments if x.metric == m) for m in METRICS},
                     "weak": len(a.weak_segments),
                     "per_10min": total / (judged / 60) * 10 if judged > 0 else None})
    return rows


def baseline_kind(b: dict) -> str:
    """baseline 行がどの普段か（v1.2〜の source。無ければ今日の普段）"""
    return "saved" if b.get("source") == "saved" else "today"


def compare_saved(rec: Recording, c: dict) -> dict:
    """同じ記録を「保存した普段」と「今日の普段」のそれぞれで判定し、指標ごとの平均のずれと区間の数を並べる。
    ずれ =（保存した普段の平均 − 今日の普段の平均）÷ 今日の標準偏差（下限をかけたもの）。どちらも、記録の中の最初の行で比べる"""
    rows = {k: sorted([b for b in rec.all_baselines if baseline_kind(b) == k], key=lambda b: b["t_ms"]) for k in ("saved", "today")}
    out: dict = {"saved_rows": rows["saved"], "today_rows": rows["today"], "shift": {}, "runs": {}}
    if not rows["saved"] or not rows["today"]:
        out["missing"] = ("保存した普段の行がありません（人を選んでいない・その人の保存した普段が無い・カメラが違う、または v1.2.1 より前で設定がオフの記録）" if not rows["saved"]
                          else "今日の普段の行がありません（今日の普段を記録し終える前に閉じた記録）")
    sv, td = (rows["saved"][0] if rows["saved"] else None), (rows["today"][0] if rows["today"] else None)
    for m in METRICS:
        a_ = (sv or {}).get("metrics", {}).get(m, {})
        b_ = (td or {}).get("metrics", {}).get(m, {})
        shift = None
        if a_.get("mean") is not None and b_.get("mean") is not None and not a_.get("insufficient") and not b_.get("insufficient"):
            shift = (a_["mean"] - b_["mean"]) / max(b_.get("std") or 0, c["std_floor"][m])
        out["shift"][m] = {"saved_mean": a_.get("mean"), "today_mean": b_.get("mean"), "today_std": b_.get("std"), "shift": shift}
    for k in ("saved", "today"):
        if not rows[k]:
            continue
        r = copy.copy(rec)
        r.baselines = rows[k]
        an = analyze(r, c)
        judged = float(frame_dt(r.t)[an.bidx >= 0].sum())
        out["runs"][k] = {"total": len(an.segments), "judged_s": judged,
                          "per_metric": {m: sum(1 for x in an.segments if x.metric == m) for m in METRICS},
                          "from": rows[k][0]["t_ms"] / 1000}
    return out


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
            excl = (a.bidx >= 0) & ~a.fvalid
            if m == "eye_squint" and a.blinked is not None:
                excl = excl | ((a.bidx >= 0) & a.blinked)   # まばたきのコマも判定対象外
            for t0, t1 in spans(excl, t):
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


def head_track(a: Analysis, states: np.ndarray) -> Track:
    t = a.rec.t

    def draw(ax):
        for k in HEAD_ORDER:
            if k == "unknown":
                continue
            for t0, t1 in spans(states == k, t):
                ax.axvspan(to_num(t0), to_num(t1), color=HEAD_COLOR[k], lw=0)
        ax.set_yticks([])
        ax.set_title("顔の向き（正面・右・左・見えない）", loc="left", fontsize=10)

    return Track("顔の向き", draw, height=0.7)


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


def figure_composite(a: "Analysis", comp: Composite, scene_color: dict) -> str:
    plt = setup_matplotlib()
    import matplotlib.dates as mdates
    rec, t = a.rec, a.rec.t
    fig, ax = plt.subplots(figsize=(12, 2.8))
    for t0, t1 in spans(~np.isfinite(comp.value), t):
        ax.axvspan(to_num(t0), to_num(t1), color="#e6e6e6", lw=0)
    for t0, t1, name in scene_intervals(rec, t[-1]):
        ax.axvspan(to_num(t0), to_num(t1), ymin=0.93, ymax=1.0, color=scene_color.get(name, "#c9c9c9"), lw=0)
        ax.axvline(to_num(t0), color="#999999", lw=0.8, ls=":")
    step = max(1, len(t) // 20000)
    ax.plot(to_num(t)[::step], comp.smooth[::step], lw=0.9, color=LINE)
    for k, (m_t, v) in enumerate(marks(rec)):
        ax.axvline(to_num(m_t), color="#7570b3", lw=1)
        ax.annotate(v, (to_num(m_t), 1.0), xycoords=("data", "axes fraction"), xytext=(2, 2 + 9 * (k % 2)),
                    textcoords="offset points", fontsize=8, color="#7570b3")
    ax.set_ylim(bottom=0)
    ax.set_ylabel("普段からの差の合計")
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S", tz=JST))
    ax.set_xlim(to_num(t[0]), to_num(t[-1]))
    ax.set_xlabel("日本時間（紫の縦線＝家族の印、点線＝場面の始まり、灰色＝判定対象外・普段が無い時間）")
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


def baseline_time_row(b: dict) -> list:
    """普段を集めた時間。古い記録（v0.3 まで）は duration_s だけで、時計の時間で数えていた"""
    started = jst(b["started_ms"] / 1000) if b.get("started_ms") else "–"
    wall = b.get("wall_s", b.get("duration_s"))
    valid = b.get("valid_s")
    if baseline_kind(b) == "saved":
        cond = "保存した普段" + (f"（{jst(b['saved_ms'] / 1000)} に保存）" if b.get("saved_ms") else "")
    elif valid is None:
        cond = "時計の時間で数えた（v0.3 までの記録）"
    else:
        cond = f"顔が読めていて |yaw| < {b.get('yaw_limit_deg', 35):g}°、開いてから {b.get('warmup_s', 5):g}秒より後"
    target = b.get("target_s")
    target = f"{target:g}秒" if target is not None else ("60秒（書かれていない v0.9 より前の記録）" if valid is not None else "–")
    return [started, jst(b["t_ms"] / 1000), target, "–" if wall is None else f"{wall:g}秒",
            "–" if valid is None else f"{valid:g}秒", cond]


def write_html(path: Path, a: Analysis, q: dict, rows: list[dict], csv_name: str) -> None:
    rec, c, e = a.rec, a.criteria, html.escape
    parts = []
    parts.append(f"<h1>振り返りレポート</h1><p class=sub>{e(rec.path.name)}（{e(rec.header.get('schema', '?'))}）"
                 f" / {jst(rec.t[0])} 〜 {jst(rec.t[-1])}（日本時間） / カメラ：{e(camera_label(rec))}</p>")
    if uses_ultra_wide(rec):
        parts.append("<p class=note>超広角で記録しています。画角の端では顔が歪み、表情の数値が変わることがあります"
                     "（顔が画面の端にあった時間の区間は、特に参考程度に見てください）。</p>")
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
             *([["そのほか、目を細めるだけ判定対象外だった時間（まばたき）", f"{fmt_s(q['blink_s'])}（{pc(q['blink_ratio'])}）"]]
               if "blink_s" in q else []),
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
    if q.get("missing"):
        parts.append("<p class=note>この記録では値が出ていません（MediaPipe が出していない可能性）："
                     + "、".join(e(k) for k in q["missing"])
                     + f"。記録全体で最大値が {MISSING_MAX} 未満の、研究用の合計と指標に使っている表情の数値です。</p>")
    yimg = figure_yaw(a)
    if yimg:
        parts.append(f"<img class=small src='{yimg}' alt='yaw の分布'>")

    # 顔の向き
    parts.append("<h2>顔の向き</h2>")
    if "head" in q:
        hrows = [[HEAD_LABEL[k], fmt_s(sec), pc(r)] for k, (sec, r) in q["head"].items() if sec > 0 or k != "unknown"]
        parts.append("<p class=note>正面は |yaw| < 15°、右・左は 35° を超えたとき。15〜35° の間は前の向きを続けます。"
                     "どれも 0.5秒以上続いたときだけ向きが変わったとし、変わり始めた時刻から数えます（アプリと同じ決まりで、1コマごとの向きから数え直したもの）。"
                     "「斜め」は、見えなくなったあと 15〜35° で見えるようになった時間です。</p>"
                     + table(["顔の向き", "時間", "割合"], hrows))
    else:
        parts.append("<p>記録に顔の向きがありません（v0.3 より前）。</p>")
    hev = head_events(rec)
    if hev:
        parts.append(f"<h3>顔を向けた・そむけた記録（head_turn、{len(hev)}件）</h3>"
                     + table(["時刻", "記録", "前の向き"],
                             [[jst(x["t_ms"] / 1000, ms=True), x.get("value", ""),
                               HEAD_LABEL.get(x.get("from"), x.get("from") or "")] for x in hev]))
    else:
        parts.append("<p>head_turn の記録はありません（v0.8 より前の記録、または向きが変わらなかった）。</p>")

    # 普段
    if rec.baselines:
        brows = []
        for b in rec.baselines:
            for m in METRICS:
                st = b.get("metrics", {}).get(m, {})
                f = lambda v: "" if v is None else f"{v:g}"
                app = b.get("eye_squint_app") if m == "eye_squint" else None
                brows.append([jst(b["t_ms"] / 1000), m, LABEL[m], st.get("n", ""), f(st.get("mean")), f(st.get("std")),
                              "　".join(filter(None, ["データ不足（計算しない）" if st.get("insufficient") else "",
                                                     f"まばたきを外して数え直し（アプリの値 n={app.get('n')} mean={f(app.get('mean'))} std={f(app.get('std'))}）"
                                                     if app else ""]))])
        parts.append("<h2>普段（baseline）</h2>"
                     "<p class=note>v0.4 からは、顔が読めていて横を向きすぎていない（|yaw| が yaw_limit_deg 未満）コマだけを、"
                     "開いてから warmup_s 秒より後に数えています（声も同じ間だけ）。"
                     "「数えた時間」が60秒になるまでにかかった実際の時間が「かかった時間」です。</p>"
                     + f"<p>普段：{e(rec.baseline_source)}</p>"
                     + ("<p class=note>目を細める（eye_squint）の普段は、まばたきのコマ（と前後）を外して数えています。"
                        "記録の baseline 行（アプリ）から使うときは、その普段を集めた時間のコマから、アプリと同じ条件で eye_squint だけ数え直しています"
                        "（アプリの値は下の表の「アプリの値」）。</p>" if blink_mask_on(c) else "")
                     + (f"<p class=note>{e(a.blink_note)}</p>" if a.blink_note else "")
                     + table(["記録し始めた時刻", "記録し終えた時刻", "普段の長さ", "かかった時間", "数えた時間", "数えた条件"],
                             [baseline_time_row(b) for b in rec.baselines])
                     + (table(["時刻", "どの普段", "比べるのに使った"],
                              [[jst(b["t_ms"] / 1000), "保存した普段" + (f"（{jst(b['saved_ms'] / 1000)} に保存）" if b.get("saved_ms") else "")
                                if baseline_kind(b) == "saved" else "今日の普段",
                                "はい" if b.get("compared", True) is not False else "いいえ（記録しただけ）"] for b in rec.all_baselines])
                        if any("source" in b for b in rec.all_baselines) else "")
                     + table(["記録し終えた時刻", "指標", "", "n", "mean", "std", ""], brows))
    else:
        parts.append("<h2>普段（baseline）</h2><p>普段（" + e(rec.baseline_source) + "）が無いため、区間は判定できません。</p>")

    # 区間の数（--calm では、何もしていない記録として10分あたりも出す）
    r = q["rates"]
    weak_on = not c.get("face_below_counts", False)
    rrows = [[m, LABEL[m], r["per_metric"][m][0], r["per_metric"][m][1]]
             + ([r["per_metric"][m][2] if m in FACE_METRICS else "–"] if weak_on else []) for m in METRICS]
    rrows.append(["合計", "", r["total"], sum(v[1] for v in r["per_metric"].values())]
                 + ([sum(v[2] for v in r["per_metric"].values())] if weak_on else []))
    head = "<h2>区間の数" + ("（何もしていない記録）" if r["calm"] else "") + "</h2>"
    rate = ("–" if r["per_min"] is None else
            f"判定した {r['minutes']:.1f}分 で {r['total']}件 = 1分あたり {r['per_min']:.2f}件 / 10分あたり {r['per_10min']:.1f}件")
    parts.append(head + f"<p>{e(rate)}</p>"
                 + table(["指標", "", "区間", "短い動き"] + (["表情の弱い方への変化（参考）"] if weak_on else []), rrows))

    # 普段の長さの比べ
    if q.get("compare"):
        calm = r["calm"]
        crow = []
        for x in q["compare"]:
            crow.append([x["label"], x["baselines"], fmt_s(x["judged_s"]), x["total"], x["shorts"]]
                        + [x["per_metric"][m] for m in METRICS]
                        + ([x["weak"]] if weak_on else [])
                        + (["–" if x["per_10min"] is None else f"{x['per_10min']:.1f}"] if calm else []))
        parts.append("<h2>普段の長さの比べ（--compare-baseline）</h2>"
                     "<p class=note>同じ記録について、普段を記録の中の1コマごとの値から指定の長さで作り直し、区間を数え直したものです"
                     "（普段に数えるコマの条件はアプリと同じ）。普段が短いほど早く判定を始めるので、判定した時間も変わります。"
                     "基準（criteria.json）はどれも同じです。</p>"
                     + table(["普段", "普段を記録し終えた時刻", "判定した時間", "区間", "短い動き"] + [LABEL[m] for m in METRICS]
                             + (["表情の弱い方への変化（参考）"] if weak_on else [])
                             + (["10分あたりの区間"] if calm else []), crow))

    # 保存した普段と今日の普段（--compare-saved）
    if q.get("compare_saved"):
        cs = q["compare_saved"]
        f2 = lambda v: "–" if v is None else f"{v:g}"
        srows = [[LABEL[m], f2(x["saved_mean"]), f2(x["today_mean"]), f2(x["today_std"]),
                  "–" if x["shift"] is None else f"{x['shift']:+.2f}"] for m, x in cs["shift"].items()]
        rr = cs["runs"]
        cnt = lambda k, m=None: "–" if k not in rr else (rr[k]["total"] if m is None else rr[k]["per_metric"][m])
        crows = [[LABEL[m], cnt("saved", m), cnt("today", m)] for m in METRICS] + [["合計", cnt("saved"), cnt("today")]]
        saved_at = "、".join(jst(b["saved_ms"] / 1000) for b in cs["saved_rows"] if b.get("saved_ms")) or "–"
        parts.append("<h2>保存した普段と今日の普段（--compare-saved）</h2>"
                     + (f"<p>{e(cs['missing'])}</p>" if cs.get("missing") else "")
                     + f"<p class=note>保存した普段を保存した日時：{e(saved_at)}。ずれ ＝（保存した普段の平均 − 今日の普段の平均）÷ 今日の標準偏差（下限をかけたもの）。"
                       "±2 を超えると、保存した普段では、今日のいつもの範囲から外れた所を「普段」として比べていることになります。"
                       "区間は、同じ記録をそれぞれの普段だけで判定し直して数えたものです（保存した普段は記録の始めから、今日の普段は記録し終えた時刻から判定します）。</p>"
                     + table(["指標", "保存した普段の平均", "今日の普段の平均", "今日の標準偏差", "ずれ"], srows)
                     + table(["指標", "保存した普段で比べた区間", "今日の普段で比べた区間"], crows))

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
    tracks = ([head_track(a, q["head_states"])] if "head_states" in q else []) + [metric_track(a, m, scene_color) for m in METRICS]
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
    if weak_on:
        wrows = segment_rows(a, a.weak_segments, "参考（表情の弱い方）")
        wbody = [[rw[k] if k != "普段の平均" else f"{rw['普段の平均']:g} → {rw['ピークの値']:g}"
                  for k in cols if k != "ピークの値"] for rw in wrows]
        parts.append(f"<h2>表情の弱い方への変化（参考）（{len(wrows)}件）</h2>"
                     "<p class=note>表情の指標が、いつもより弱い方へ外れた区間です。アプリは表情の「いつもより強い」だけを違いとして出すので、"
                     "揃えて区間・通知候補・10分あたりの数には入れていません（criteria.json の face_below_counts で変えられます）。"
                     "CSV には「区分」が「参考（表情の弱い方）」の行として入っています。</p>"
                     + (table([k if k != "普段の平均" else "普段の平均 → ピークの値" for k in cols if k != "ピークの値"], wbody)
                        if wrows else "<p>ありません。</p>"))

    # 研究用の複合値（区間の判定・通知候補には使わない）
    comp = research_composite(a)
    if comp is not None:
        rc = c["research_composite"]
        f3 = lambda v: "–" if v is None else f"{v:.3f}"
        groups = "＋".join(g[0] if len(g) == 1 else f"max({', '.join(g)})" for g in rc["groups"])
        parts.append(f"<h2>研究用：{e(RC_NAME)}</h2>"
                     "<p class=note>研究のための値です。区間の判定・通知候補には使っていません。アプリ・見る側の画面には出しません。"
                     "状態の名前を表すものではなく、家族の印と照らし合わせて意味があるかを確かめるために出しています。</p>"
                     f"<p class=note>1コマごとに、普段からの差（今の値 − 普段の平均。マイナスは 0）で "
                     f"{e(groups)}（左右平均。eyeSquint はまばたきのコマを除く）"
                     f"＋ 目を閉じている間の eyeBlink（左右平均が {rc['eye_closed']['threshold']:g} 以上の状態が {rc['eye_closed']['min_s']:g}秒以上続いている間だけ。短いまばたきは入れない）"
                     "を、重みを付けずに足しています。普段の平均は、記録の baseline 行の時間のコマから、アプリと同じ条件で数え直しています。"
                     f"グラフは {rc['smooth_s']:g}秒でならしたものです。表情の判定対象外の時間と普段が無い時間は計算していません。</p>"
                     f"<img src='{figure_composite(a, comp, scene_color)}' alt='{e(RC_NAME)}の時系列'>")
        mrows = [[jst(r["t"]), r["label"], f3(r["mean"]), r["n"]] for r in comp.mark_rows]
        n_marks = len(comp.mark_rows)
        if n_marks:
            few = n_marks < rc["min_marks"]
            parts.append(f"<h3>家族の印の前後 {rc['mark_window_s']:g}秒の平均（印 {n_marks}件）</h3>"
                         + (f"<p><b>数が少ない</b>（印が {rc['min_marks']}件たまるまでは、比べられるほどの数ではありません）。</p>" if few else "")
                         + table(["", "件数", "平均"],
                                 [[f"家族の印：{v}", k, f3(m)] for v, (k, m) in comp.by_value.items()]
                                 + [["印のない時間", f"{comp.no_mark_n}コマ", f3(comp.no_mark_mean)]])
                         + table(["時刻", "家族の印", f"前後 {rc['mark_window_s']:g}秒の平均", "使ったコマ"], mrows))
        else:
            parts.append(f"<p>家族の印が無いため、印の前後との比べはありません（全体の平均 {f3(comp.no_mark_mean)}）。</p>")

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
    p.add_argument("--calm", action="store_true", help="「何もしていない記録」として、区間の数を10分あたりでも出す")
    p.add_argument("--criteria", type=Path, default=HERE / "criteria.json")
    p.add_argument("--set", action="append", default=[], metavar="指標.項目=値",
                   help="基準を変える（例 brow_down.start_min_s=0.8、all.smooth_s=0.5）。項目：" + ", ".join(CRITERIA_KEYS))
    for k in CRITERIA_KEYS:
        p.add_argument("--" + k.replace("_", "-"), type=float, help=f"すべての指標の {k} を変える")
    p.add_argument("--baseline-s", type=float, metavar="秒",
                   help="普段を、記録の中の1コマごとの値からこの長さ（数えた時間）で作り直して区間を数える（例 30）")
    p.add_argument("--compare-baseline", metavar="秒,秒",
                   help="同じ記録を、普段の長さを変えて数えた区間の数を並べる（例 30,60）")
    p.add_argument("--compare-saved", action="store_true",
                   help="保存した普段（source: saved）と今日の普段（source: today）のずれと、それぞれで判定した区間の数を並べる（v1.2〜の記録）")
    p.add_argument("--out-dir", type=Path, help="出力先（省略時は記録と同じ場所）")
    args = p.parse_args(argv)

    with open(args.jsonl, encoding="utf-8") as f:
        if '"session_summary"' in f.readline():
            print("これは要約の一覧（sessions.jsonl）です。一覧は sessions.py で、1回分のレポートは ability-cam-*.jsonl を渡してください",
                  file=sys.stderr)
            return 2

    overrides = list(args.set) + [f"all.{k}={getattr(args, k)}" for k in CRITERIA_KEYS if getattr(args, k) is not None]
    c = load_criteria(args.criteria, overrides)
    rec = load(args.jsonl)
    lengths: list[float] = []
    if args.compare_baseline:
        try:
            lengths = [float(x) for x in args.compare_baseline.split(",") if x.strip()]
        except ValueError:
            sys.exit(f"--compare-baseline の形が違います: {args.compare_baseline}（例 30,60）")
    if (args.baseline_s or lengths) and not rec.has_pose:
        sys.exit("この記録には顔の向きが無い（v0.3 より前）ため、アプリと同じ条件で普段を作り直せません")
    compare_rows = compare_baselines(rec, c, lengths) if lengths else None
    if args.baseline_s:
        rec = with_baseline(rec, args.baseline_s, c)
    a = analyze(rec, c)
    rows = segment_rows(a)
    weak_rows = segment_rows(a, a.weak_segments, "参考（表情の弱い方）")
    q = quality(a, args.calm)
    if compare_rows:
        q["compare"] = compare_rows
        for x in compare_rows:
            per = "" if not args.calm or x["per_10min"] is None else f" / 10分あたり {x['per_10min']:.1f}件"
            print(f"{x['label']}: 区間 {x['total']}件（判定した {x['judged_s'] / 60:.1f}分）{per}")

    if args.compare_saved:
        cs = compare_saved(rec, c)
        q["compare_saved"] = cs
        if cs.get("missing"):
            print(cs["missing"])
        for k, label in (("saved", "保存した普段"), ("today", "今日の普段")):
            if k in cs["runs"]:
                print(f"{label}で比べた区間: {cs['runs'][k]['total']}件")
        for m, x in cs["shift"].items():
            if x["shift"] is not None:
                print(f"  {LABEL[m]}: ずれ {x['shift']:+.2f}（保存 {x['saved_mean']:g} / 今日 {x['today_mean']:g}）")

    out = args.out_dir or args.jsonl.parent
    out.mkdir(parents=True, exist_ok=True)
    csv_path = out / f"{args.jsonl.stem}_segments.csv"
    html_path = out / f"{args.jsonl.stem}.html"
    write_csv(csv_path, rows + weak_rows, c)
    write_html(html_path, a, q, rows, csv_path.name)
    print(f"区間 {len(rows)}件" + (f"（ほかに表情の弱い方への変化 {len(weak_rows)}件、参考）" if weak_rows else "")
          + f" → {html_path} / {csv_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
