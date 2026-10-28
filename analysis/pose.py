"""顔の向きの普段と特徴（v1.8〜、振り返りレポートだけ。アプリの画面には出さない）。

カメラは介助する人の胸にあるので、介助する人が動くと本人の顔の向きも変わって見える。そのため、まず記録とレポートだけで見て、画面に出すかを決める。
右・左は本人から見た向き（direction_version 2。それより前の記録は review.load が入れ替える）。言い方は向きと秒数の事実だけ
（「そむけた」「嫌がった」「疲れている」のような意味は付けない。docs/wording-guide.md）。

基準は criteria.json の pose（すべて仮の値）。
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

import review

# (baseline 行の pose のキー, 記録の値, いつもより + / − のときの言い方, 右・左があるか)
AXES = [
    ("yaw_deg", "yaw", ("右を向いていた", "左を向いていた"), True),
    ("pitch_deg", "pitch", ("上を向いていた", "下を向いていた"), False),
    ("roll_deg", "roll", ("右に傾いていた", "左に傾いていた"), True),
]
AXIS_LABEL = {"yaw_deg": "左右の向き（yaw）", "pitch_deg": "上下の向き（pitch）", "roll_deg": "傾き（roll）"}


def values(rec: review.Recording, key: str) -> np.ndarray:
    arr = {"yaw_deg": rec.yaw, "pitch_deg": rec.pitch, "roll_deg": rec.roll}[key]
    return arr if arr is not None else np.full(len(rec.t), np.nan)


def pose_baselines(rec: review.Recording) -> list[tuple[dict | None, str]]:
    """rec.baselines の行ごとの、顔の向きの普段と、どこから取ったか。
    v1.8〜の行は pose をそのまま使う。無い行（v1.7 まで）の今日の普段は、アプリと同じ条件で普段に数えたコマ（started_ms〜t_ms）から数え直す。
    保存した普段で pose が無いもの（v1.7 までに保存）は無し"""
    out: list[tuple[dict | None, str]] = []
    processed = valid = None
    for b in rec.baselines:
        if not review.covers(b, "face"):
            out.append((None, ""))
            continue
        if b.get("pose"):
            out.append((b["pose"], "記録の baseline 行"))
            continue
        if review.baseline_kind(b) == "saved" or not b.get("started_ms"):
            out.append((None, "保存した普段に顔の向きが無い（v1.7 までに保存したもの）"))
            continue
        if processed is None:
            processed, valid, _ = review.baseline_candidates(rec)
        t = rec.t
        sel = processed & valid & (t >= b["started_ms"] / 1000 - 1e-9) & (t <= b["t_ms"] / 1000 + 1e-9)
        st = {k: review.baseline_stat(values(rec, k)[sel & np.isfinite(values(rec, k))]) for k, *_ in AXES}
        out.append((st, "普段を集めた時間のコマから数え直したもの（v1.7 までの記録）"))
    return out


@dataclass
class Deviation:
    key: str
    sign: int
    t0: float
    t1: float
    peak: float        # いつもの平均からいちばん離れた度数（ならした値）
    mean: float

    @property
    def seconds(self) -> float:
        return self.t1 - self.t0

    def text(self) -> str:
        """「いつもより右に傾いていた 13:42:05〜、12秒（本人から見て）」"""
        _, _, words, sided = next(a for a in AXES if a[0] == self.key)
        return (f"いつもより{words[0] if self.sign > 0 else words[1]} {review.jst(self.t0)}〜、{self.seconds:.0f}秒"
                + ("（本人から見て）" if sided else ""))


def axis_stats(a: review.Analysis, pb: list[tuple[dict | None, str]], key: str, floor: float) -> tuple[np.ndarray, np.ndarray]:
    """各コマで使う、顔の向きの普段の平均と標準偏差（下限 floor をかけたもの）。表情の普段の行（a.bidx）に合わせる"""
    n = len(a.rec.t)
    mean, sd = np.full(n, np.nan), np.full(n, np.nan)
    for bi, (st, _) in enumerate(pb):
        x = (st or {}).get(key)
        if not x or x.get("insufficient") or x.get("mean") is None:
            continue
        sel = a.bidx == bi
        mean[sel] = x["mean"]
        sd[sel] = max(x.get("std") or 0, floor)
    return mean, sd


def deviations(a: review.Analysis, pb, pc: dict) -> list[Deviation]:
    """いつもの範囲（普段の平均 ± range_z × 標準偏差、標準偏差の下限 std_floor_deg）から、同じ向きに min_s 秒以上外れていた時間。
    値は smooth_s 秒でならす（stale_s より空いたら切る）。普段が無い時間・顔の向きが無い時間で切れる"""
    rec, t, c = a.rec, a.rec.t, a.criteria
    out: list[Deviation] = []
    for key, *_ in AXES:
        mean, sd = axis_stats(a, pb, key, pc["std_floor_deg"])
        sm = review.smooth(t, values(rec, key), pc["smooth_s"], c["stale_s"])
        z = (sm - mean) / sd
        sign = np.where(z >= pc["range_z"], 1, np.where(z <= -pc["range_z"], -1, 0))
        i = 0
        while i < len(t):
            if sign[i] == 0 or not np.isfinite(z[i]):
                i += 1
                continue
            j = i
            while j + 1 < len(t) and sign[j + 1] == sign[i] and np.isfinite(z[j + 1]):
                j += 1
            if t[j] - t[i] >= pc["min_s"] - 1e-9:
                dev = sm[i:j + 1] - mean[i:j + 1]
                k = int(np.nanargmax(np.abs(dev)))
                out.append(Deviation(key, int(sign[i]), float(t[i]), float(t[j]), float(dev[k]), float(mean[i])))
            i = j + 1
    out.sort(key=lambda d: d.t0)
    return out


def state_runs(t: np.ndarray, states: np.ndarray) -> list[tuple[str, float, float]]:
    """顔の向きの段（review.head_states）を、(向き, 始まり, 終わり) の並びにする。まだ決まっていない時間は入れない。
    終わりは次の向きの始まり（最後は記録の終わり）"""
    runs: list[tuple[str, float, float]] = []
    cur, start = None, None
    for i, s in enumerate(states):
        s = None if s in (None, "unknown") else s
        if s != cur:
            if cur is not None:
                runs.append((cur, start, float(t[i])))
            cur, start = s, float(t[i])
    if cur is not None:
        runs.append((cur, start, float(t[-1])))
    return runs


def quick_changes(rec: review.Recording, pc: dict) -> list[tuple[float, float, str]]:
    """急な向きの変化：quick_window_s 秒前のコマから、yaw・pitch・roll のどれかが quick_deg 以上変わった（顔のあるコマどうし）。
    条件を満たし始めたコマで1回と数え、満たさなくなるまでと、数えてから quick_window_s 秒の間は数えない（1つの動きを何度も数えない）。
    返り値：(時刻, 変わった度数, どの向き)"""
    t, w, thr = rec.t, pc["quick_window_s"], pc["quick_deg"]
    arrs = {k: values(rec, k) for k, *_ in AXES}
    out: list[tuple[float, float, str]] = []
    on, last = False, -np.inf
    for i in range(len(t)):
        j = int(np.searchsorted(t, t[i] - w - 1e-9))
        best, which = 0.0, ""
        if j < i and t[i] - t[j] <= w * 1.5 and rec.face[i] and rec.face[j]:
            for k, x in arrs.items():
                d = abs(x[i] - x[j])
                if d == d and d > best:
                    best, which = float(d), k
        hit = best >= thr - 1e-9
        if hit and not on and t[i] - last >= w - 1e-9:
            out.append((float(t[i]), best, which))
            last = float(t[i])
        on = hit
    return out


def distribution(rec: review.Recording, states: np.ndarray, mask: np.ndarray) -> dict:
    """その時間の向きの分布：顔の向きの段ごとの時間の割合と、yaw・pitch・roll の平均"""
    dt = review.frame_dt(rec.t)
    total = float(dt[mask].sum())
    ratio = {k: (float(dt[mask & (states == k)].sum()) / total if total > 0 else None) for k in review.HEAD_ORDER if k != "unknown"}
    means = {}
    for key, *_ in AXES:
        x = values(rec, key)[mask]
        x = x[np.isfinite(x)]
        means[key] = float(x.mean()) if len(x) else None
    return {"seconds": total, "ratio": ratio, "mean": means}


def analyze_pose(a: review.Analysis) -> dict | None:
    """レポートに出すものをまとめる。顔の向きが記録されていない（v0.3 より前）か、criteria.json に pose が無ければ None"""
    rec, c = a.rec, a.criteria
    pc = c.get("pose")
    if not pc or not rec.has_pose:
        return None
    t = rec.t
    pb = pose_baselines(rec)
    states, changes = review.head_states(t, rec.face, rec.yaw)
    minutes = float(review.frame_dt(t).sum()) / 60
    runs = state_runs(t, states)
    lens = np.array([r[2] - r[1] for r in runs])
    bins = pc["dwell_bins_s"]
    edges = [0.0] + list(bins) + [float("inf")]
    hist = [int(((lens >= lo) & (lens < hi)).sum()) for lo, hi in zip(edges, edges[1:])]
    out = {
        "baselines": [(b, st, src) for b, (st, src) in zip(rec.baselines, pb) if review.covers(b, "face")],
        "deviations": deviations(a, pb, pc),
        "changes": len(changes), "minutes": minutes,
        "changes_per_min": len(changes) / minutes if minutes > 0 else None,
        "dwell": {"n": len(lens), "p": tuple(float(np.percentile(lens, q)) for q in (10, 50, 90)) if len(lens) else None,
                  "edges": edges, "hist": hist},
        "quick": quick_changes(rec, pc),
    }
    # 場面ごと・家族の印の前後ごとの向きの分布
    scenes: dict[str, np.ndarray] = {}
    for s0, s1, name in review.scene_intervals(rec, t[-1]):
        m = scenes.setdefault(name, np.zeros(len(t), bool))
        m |= (t >= s0) & (t < s1)
    out["by_scene"] = [(name, distribution(rec, states, m)) for name, m in scenes.items()]
    out["by_scene"].append(("場面なし", distribution(rec, states, ~np.any(list(scenes.values()), axis=0) if scenes else np.ones(len(t), bool))))
    w = pc["mark_window_s"]
    out["mark_window_s"] = w
    out["by_mark"] = [(m_t, v, distribution(rec, states, (t >= m_t - w) & (t < m_t)), distribution(rec, states, (t >= m_t) & (t <= m_t + w)))
                      for m_t, v in review.marks(rec)]
    return out


def html_section(a: review.Analysis, e) -> str:
    """振り返りレポートの「顔の向きの普段と特徴」の節"""
    p = analyze_pose(a)
    if p is None:
        return ""
    pc = a.criteria["pose"]
    f1 = lambda v: "–" if v is None else f"{v:+.1f}°"
    pct = lambda v: "–" if v is None else f"{v:.0%}"
    parts = ["<h2>顔の向きの普段と特徴（記録とレポートだけ）</h2>",
             "<p class=note>アプリの画面にはまだ出していません。カメラは介助する人の胸にあるので、介助する人が動くと本人の顔の向きも変わって見えます。"
             "右・左は本人から見た向きです。向きと秒数の事実だけを出し、意味は付けていません。基準はすべて仮の値です（criteria.json の pose）。</p>"]
    # いつもの向き
    rows = []
    for b, st, src in p["baselines"]:
        for key, *_ in AXES:
            x = (st or {}).get(key) or {}
            rng = ("–" if x.get("mean") is None else
                   f"{x['mean'] - pc['range_z'] * max(x.get('std') or 0, pc['std_floor_deg']):+.1f}° 〜 {x['mean'] + pc['range_z'] * max(x.get('std') or 0, pc['std_floor_deg']):+.1f}°")
            rows.append([review.jst(b["t_ms"] / 1000), AXIS_LABEL[key], f1(x.get("mean")),
                         "–" if x.get("std") is None else f"{x['std']:.1f}°", rng, x.get("n", "–"), src or "–"])
    parts.append("<h3>いつもの向き</h3>"
                 f"<p class=note>普段の間の平均とばらつき（標準偏差）。いつもの範囲は 平均 ± {pc['range_z']:g} × 標準偏差（標準偏差の下限 {pc['std_floor_deg']:g}°）。"
                 "左右の向きと傾きは本人から見て右が +、上下は上が +。</p>"
                 + review.table(["普段を記録し終えた時刻", "向き", "平均", "ばらつき", "いつもの範囲", "n", "どこから"], rows))
    # いつもの範囲から外れていた時間
    devs = p["deviations"]
    parts.append(f"<h3>いつもの範囲から外れて {pc['min_s']:g}秒以上続いた時間（{len(devs)}件）</h3>"
                 + (review.table(["", "開始", "終了", "長さ", "いつもの平均", "いちばん離れた所"],
                                 [[d.text(), review.jst(d.t0), review.jst(d.t1), f"{d.seconds:.0f}秒", f1(d.mean), f1(d.mean + d.peak)] for d in devs])
                    if devs else "<p>ありません。</p>"))
    # 向きを変えた回数・とどまった長さ・急な変化
    d = p["dwell"]
    edges = d["edges"]
    labels = [f"{hi:g}秒未満" if lo == 0 else (f"{lo:g}秒以上" if hi == float("inf") else f"{lo:g}〜{hi:g}秒") for lo, hi in zip(edges, edges[1:])]
    rate = "–" if p["changes_per_min"] is None else f"{p['changes']}回（1分あたり {p['changes_per_min']:.2f}回）"
    pt = "–" if d["p"] is None else f"{d['p'][0]:.1f}秒 / {d['p'][1]:.1f}秒 / {d['p'][2]:.1f}秒（{d['n']}回）"
    q = p["quick"]
    parts.append("<h3>向きの変わり方</h3>"
                 + review.table(["", "値"], [
                     ["向きを変えた回数（顔の向きの段：正面・右・左・見えない・斜め。0.5秒続いたもの）", rate],
                     ["ひとつの向きにとどまった長さ（10% / 中央値 / 90%）", pt],
                     [f"急な向きの変化（{pc['quick_window_s']:g}秒で {pc['quick_deg']:g}°以上、左右・上下・傾きのどれか）",
                      f"{len(q)}回" + (f"（1分あたり {len(q) / p['minutes']:.2f}回）" if p["minutes"] > 0 else "")]])
                 + review.table(["とどまった長さ"] + labels, [["回数"] + d["hist"]])
                 + (review.table(["時刻", "変わった度数", "どの向き"],
                                 [[review.jst(t0, ms=True), f"{deg:.0f}°", AXIS_LABEL[k]] for t0, deg, k in q]) if q else ""))
    # 場面ごと・家族の印の前後
    order = [k for k in review.HEAD_ORDER if k != "unknown"]
    head = [review.HEAD_LABEL[k] for k in order] + ["左右の平均", "上下の平均", "傾きの平均"]
    row = lambda dist: [pct(dist["ratio"][k]) for k in order] + [f1(dist["mean"][k]) for k, *_ in AXES]
    parts.append("<h3>場面ごとの向き</h3>"
                 + review.table(["場面", "時間"] + head, [[name, review.fmt_s(dist["seconds"])] + row(dist) for name, dist in p["by_scene"]]))
    w = p["mark_window_s"]
    if p["by_mark"]:
        mrows = []
        for m_t, v, before, after in p["by_mark"]:
            mrows.append([review.jst(m_t), v, f"前 {w:g}秒"] + row(before))
            mrows.append(["", "", f"後 {w:g}秒"] + row(after))
        parts.append(f"<h3>家族の印の前後 {w:g}秒の向き</h3>" + review.table(["時刻", "家族の印", ""] + head, mrows))
    return "".join(parts)
