#!/usr/bin/env python3
"""テスト用の小さな JSONL（作り物の数値。人の記録ではない）を作る。

時間割（開始からの秒）：
  0–10   普段の記録。10秒の時点で baseline 行（f0_hz は insufficient）
  20–21  brow_down を高く（z≈5）           → 区間 1件（上）
  30–30.3 brow_down を高く                  → 短い動き 1件
  40–42  brow_down を高く、41–41.3 だけ z≈1.7 に下げる → ヒステリシスで 区間 1件のまま
  50–52  brow_down を高く、ただし yaw 50°   → 判定対象外（区間なし）
  60–62  顔が映らない                        → 判定対象外（区間なし）
  70–71.5 rms_db を大きく（f0 も高く）、口が動く → rms_db 区間（上）、f0 は insufficient なので無し
  80–81.5 rms_db を小さく（声あり）、口が動く   → rms_db 区間（下）
  （v1.6〜：声は本人の声のコマだけで判定する。口が動いていない声（ほかの時間の f0）は本人の声と言えないので判定しない）
  90     普段を取り直す。90–95 brow_down を高くしても普段が無いので区間なし。100 で baseline 行
  105–106 jaw_open を高く                   → 区間 1件（上）
  （50–52 の直後に z が2を超えて残るが、始まりが見えていないので短い動きには数えない）
場面：15 食事 → 25 なし。印：20.8 不快（区間の中）、21.5 分からない（区間の終わりの直後）、75 快
顔の向き（head_turn、アプリが書くのと同じもの）：50 右へ → 52 正面に戻った → 60 見えなくなった（直前は正面） → 62 正面に戻った

fixture_eyes.jsonl（目を閉じている、v1.4〜）：同じ普段（10秒）で、eyeBlink だけを変える
  15–15.3 閉じる（0.9）                      → まばたき（区間なし）
  20–24  閉じる                              → 区間 1件（20〜24、4秒）
  30–34  閉じる（ちょうど 0.5）、32–32.1 だけ開く → 0.2秒より短いので 区間 1件のまま（30〜34）
  40–42  閉じる、41–41.5 だけ yaw 50°         → 41 の手前で打ち切り（区間 1件）、41.5–42 は 0.5秒に届かず区間なし
  50–51  閉じる、50.4–50.5 は顔が映らない      → 顔の無いコマは何も変えない（区間 1件、50〜51）
  60–60.45 閉じる                            → 0.5秒に届かず区間なし
  70     普段を取り直す。72–75 閉じても普段が無いので区間なし。80 で baseline 行
  85–90  閉じたまま記録の終わり               → 区間 1件（記録の終わりで打ち切り）

fixture_voice.jsonl（本人の声、v1.6〜の形：voice_self を書き、表情と声の普段を別の行にする）：声が出ているのは下の時間だけ
  10     表情の普段（part: "face"）
  12–20  本人以外の声（大きく高い声、口は動かない） → voice_self: false、区間なし
  25–37  本人の声（口が動く）                    → 本人の声が10秒たまった所で声の普段（part: "voice"）
  50–52  本人の声で高い声                         → 声の高さ 区間 1件（上）
  60–62  本人以外の声で高い声                     → 区間なし
  70–72  本人の声だが横を向いている（yaw 50°）     → voice_self: false、区間なし
  80–82  本人の声で大きな声                       → 声の大きさ 区間 1件（上）
"""
import json
import math

import numpy as np
from pathlib import Path

T0_MS = 1_790_000_000_000   # 2026-09 ごろの適当な時刻
FPS = 30
END = 110.0

BASE = {"mouth_smile": (0.10, 0.05), "brow_down": (0.05, 0.02), "eye_squint": (0.10, 0.05),
        "jaw_open": (0.05, 0.05), "rms_db": (-50.0, 3.0)}


def bs_from(v):
    return {"mouthSmileLeft": v["mouth_smile"], "mouthSmileRight": v["mouth_smile"],
            "browDownLeft": v["brow_down"], "browDownRight": v["brow_down"],
            "eyeSquintLeft": v["eye_squint"], "eyeSquintRight": v["eye_squint"],
            "jawOpen": v["jaw_open"], "eyeBlinkLeft": 0.05, "eyeBlinkRight": 0.05,
            "cheekSquintLeft": 0.05, "cheekSquintRight": 0.05, "noseSneerLeft": 0.02, "noseSneerRight": 0.02,
            "mouthUpperUpLeft": 0.03, "mouthUpperUpRight": 0.03}


def baseline_line(t):
    m = {k: {"n": 300, "mean": mu, "std": sd, "insufficient": False} for k, (mu, sd) in BASE.items()}
    m["f0_hz"] = {"n": 10, "mean": 200.0, "std": 5.0, "insufficient": True}
    return {"type": "baseline", "t_ms": T0_MS + int(t * 1000), "started_ms": T0_MS + int((t - 10) * 1000),
            "duration_s": 10.0, "min_n": 30, "metrics": m}


def eyes_blink(t):
    """fixture_eyes の eyeBlink（左右とも同じ値）と、yaw・顔を変える時間"""
    closed = (15 <= t < 15.3 or 20 <= t < 24 or (30 <= t < 34 and not 32 <= t < 32.1) or 40 <= t < 42
              or 50 <= t < 51 or 60 <= t < 60.45 or 72 <= t < 75 or t >= 85)
    blink = 0.5 if 30 <= t < 34 else 0.9
    return (blink if closed else 0.05), (50.0 if 41 <= t < 41.5 else 2.0), not (50.4 <= t < 50.5)


def speak(t):
    """話している間の口の開きと声の大きさの揺れ（4Hz）。本人の声では jawOpen と rms_db が同じ向きに動く（v1.9〜、口と声のタイミング）"""
    return math.sin(2 * math.pi * 4 * t)


def frame(t):
    v = {k: mu for k, (mu, _) in BASE.items()}
    face, yaw, f0 = True, 2.0, (200.0 if int(t) % 3 == 0 else None)
    high_brow = 0.05 + 5 * 0.03   # std 0.02 → 下限 0.03 で z≈5
    if 20 <= t < 21 or 30 <= t < 30.3 or 40 <= t < 42 or 50 <= t < 52 or 90 <= t < 95:
        v["brow_down"] = high_brow
    if 41 <= t < 41.3:
        v["brow_down"] = 0.05 + 1.7 * 0.03
    if 50 <= t < 52:
        yaw = 50.0
    if 60 <= t < 62:
        face = False
    mouth = 0.0
    if 70 <= t < 71.5:
        v["rms_db"], f0 = -30.0, 320.0
    if 80 <= t < 81.5:
        v["rms_db"], f0 = -65.0, 190.0
    if 70 <= t < 71.5 or 80 <= t < 81.5:
        mouth = round(0.1 + 0.1 * math.sin(2 * math.pi * 4 * t), 3)   # 話している口の動き（mouthFunnel、指標には使わない）
        v["jaw_open"] = round(0.08 + 0.02 * speak(t), 3)                # 口の開きと声の大きさが同じ向きに揺れる（本人の声）
        v["rms_db"] = round(v["rms_db"] + 3 * speak(t), 1)
    elif 81.5 <= t < 82:
        f0 = None             # 話し終えた直後は声なし（話し終えてすぐ別の声が入ると、ならした値が残って短い区間になるため）
    elif 65 <= t < 90 and f0 is None:
        v["rms_db"] = -75.0   # 話していない間は静か（v1.9〜：話し始めの口の開きと声の大きさが同じ向きに変わるように）
    if 105 <= t < 106:
        v["jaw_open"] = 0.5
    return frame_obj(t, v, face, yaw, f0, mouth=mouth)


def frame_obj(t, v, face, yaw, f0, blink=0.05, mouth=0.0):
    o = {"type": "frame", "t_ms": T0_MS + int(round(t * 1000)), "face": face,
         "rms_db": v["rms_db"], "proc_ms": 12.0, "lat_ms": 60.0 + 10 * math.sin(t)}
    if face:
        o["bs"] = bs_from(v)
        o["bs"]["eyeBlinkLeft"] = o["bs"]["eyeBlinkRight"] = blink
        o["bs"]["mouthFunnel"] = mouth
        o["pts"] = []
        o["yaw_deg"], o["pitch_deg"], o["roll_deg"] = yaw, -3.0, 1.0
    if f0 is not None:
        o["f0_hz"] = f0
    return o


def event(t, kind, value=None):
    o = {"type": "event", "t_ms": T0_MS + int(t * 1000), "kind": kind}
    if value is not None:
        o["value"] = value
    return o


def head(t, value, frm, to, yaw):
    o = event(t, "head_turn", value)
    o.update({"head": to, "from": frm, "yaw_deg": yaw})
    return o


def build():
    lines = [{"schema": "ability-cam.ios.v0.2", "started_at_ms": T0_MS, "camera": "wide", "camera_label": "広角",
              "note": "テスト用の作り物"}]
    extra = [(10.0, baseline_line(10.0)), (15.0, event(15.0, "scene", "食事")), (25.0, event(25.0, "scene", "なし")),
             (20.8, event(20.8, "mark", "不快")), (21.5, event(21.5, "mark", "分からない")), (75.0, event(75.0, "mark", "快")),
             (90.0, event(90.0, "baseline_restart")), (100.0, baseline_line(100.0)),
             (50.0, head(50.0, "右へ", "front", "right", 50.0)), (52.0, head(52.0, "正面に戻った", "right", "front", 2.0)),
             (60.0, head(60.0, "見えなくなった（直前は正面）", "front", "hidden", 2.0)),
             (62.0, head(62.0, "正面に戻った", "hidden", "front", 2.0))]
    rows = [(i / FPS, frame(i / FPS)) for i in range(int(END * FPS))]
    rows += extra
    rows.sort(key=lambda r: r[0])
    return lines + [r[1] for r in rows]


EYES_END = 90.0


def build_eyes():
    lines = [{"schema": "ability-cam.ios.v0.2", "started_at_ms": T0_MS, "camera": "wide", "camera_label": "広角",
              "note": "テスト用の作り物（目を閉じている）"}]
    extra = [(10.0, baseline_line(10.0)), (70.0, event(70.0, "baseline_restart")), (80.0, baseline_line(80.0))]
    rows = []
    for i in range(int(EYES_END * FPS)):
        t = i / FPS
        blink, yaw, face = eyes_blink(t)
        v = {k: mu for k, (mu, _) in BASE.items()}
        rows.append((t, frame_obj(t, v, face, yaw, 200.0 if int(t) % 3 == 0 else None, blink)))
    rows += extra
    rows.sort(key=lambda r: r[0])
    return lines + [r[1] for r in rows]


VOICE_END = 90.0
SELF = [(25, 37), (50, 52), (70, 72), (80, 82)]
OTHER = [(12, 20), (60, 62)]


def voice_at(t):
    """(f0, rms, 口の動き, yaw, 記録に書く voice_self)"""
    inside = lambda spans: any(a <= t < b for a, b in spans)
    if inside(SELF):
        f0 = 260.0 if 50 <= t < 52 else 200.0 + 5 * math.sin(2 * math.pi * 1.3 * t)
        rms = (-20.0 if 80 <= t < 82 else -50.0 + 3 * math.sin(2 * math.pi * 0.7 * t)) + 3 * speak(t)
        yaw = 50.0 if 70 <= t < 72 else 2.0
        return round(f0, 1), round(rms, 1), round(0.1 + 0.1 * math.sin(2 * math.pi * 4 * t), 3), yaw, yaw < 35
    if inside(OTHER):
        return (250.0 if t < 20 else 260.0), -30.0, 0.0, 2.0, False
    return None, -60.0, 0.0, 2.0, None


def build_voice():
    lines = [{"schema": "ability-cam.ios.v0.2", "started_at_ms": T0_MS, "camera": "wide", "camera_label": "広角",
              "note": "テスト用の作り物（本人の声）"}]
    face_m = {k: {"n": 300, "mean": mu, "std": sd, "insufficient": False} for k, (mu, sd) in BASE.items() if k != "rms_db"}
    face_row = {"type": "baseline", "t_ms": T0_MS + 10_000, "started_ms": T0_MS, "valid_s": 10.0, "min_n": 30, "target_s": 10.0,
                "blink_masked": True, "source": "today", "compared": True, "part": "face", "metrics": face_m}
    rows, frames = [], []
    valid, last, vals, voice_row = 0.0, None, {"rms_db": [], "f0_hz": []}, None
    for i in range(int(VOICE_END * FPS)):
        t = i / FPS
        f0, rms, mouth, yaw, vs = voice_at(t)
        v = {k: mu for k, (mu, _) in BASE.items()}
        if mouth:   # 本人が話している：口の開きが声の大きさと同じ向きに揺れる
            v["jaw_open"] = round(0.08 + 0.02 * speak(t), 3)
        o = frame_obj(t, v, True, yaw, f0, mouth=mouth)
        o["rms_db"] = rms
        o["voice_self"] = vs
        frames.append((t, o))
        # 撮る側と同じ数え方で、声の普段（本人の声が10秒たまった所）
        if voice_row is None:
            counted = vs is True and t >= 5
            if counted and last is not None and t > last:
                valid += min(t - last, 0.5)
            last = t
            if counted:
                vals["rms_db"].append(rms); vals["f0_hz"].append(f0)
            if valid >= 10.0:
                def stat(x):
                    import statistics
                    return {"n": len(x), "mean": round(statistics.fmean(x), 4), "std": round(statistics.stdev(x), 4),
                            "insufficient": len(x) < 30}
                voice_row = {"type": "baseline", "t_ms": T0_MS + int(round(t * 1000)), "started_ms": T0_MS,
                             "voice_valid_s": round(valid, 1), "min_n": 30, "target_s": 10.0, "blink_masked": True,
                             "source": "today", "compared": True, "part": "voice",
                             "metrics": {k: stat(x) for k, x in vals.items()}}
                # 声の高さは中央値と四分位範囲も（v1.9.1〜、アプリと同じ：numpy の linear、0.1 に丸める）
                q1, med, q3 = np.percentile(np.array(vals["f0_hz"]), [25, 50, 75])
                voice_row["metrics"]["f0_hz"].update(median=round(float(med), 1), iqr=round(float(q3 - q1), 1))
                rows.append((t, voice_row))
    rows += [(10.0, face_row)] + frames
    rows.sort(key=lambda r: r[0])
    return lines + [r[1] for r in rows]


# fixture_cues.jsonl（試すモード、v1.18〜）：10秒で表情の普段（中央値つき）。10秒から CuePlan と同じ指示を記録に書き、指示どおりに値を動かす。
# 眉を寄せる（3秒）×5：browDown 0.01 → 0.06（3回目だけ 0.012）。今の下限 0.03 では z≈1.7 で出ず、いちばん強く寄せた 0.15 から決めた下限 0.014 では z≈3.6 で出る。
# 点の距離は brow_inner_eye（眉頭と目頭の間）だけが大きく動き、brow_inner_gap はほとんど動かない。笑う ×5：mouthSmile 0.5・mouth_corner 0.05。
# 横を向く：yaw 30°（点の距離は書かない）
CUE_STEPS = ([("calm", 30)] + [("frown", 3), ("rest", 3)] * 5 + [("smile", 3), ("rest", 3)] * 5
             + [("turn", 20), ("calm", 30), ("frown_max", 3), ("rest", 3), ("smile_max", 3), ("rest", 3)])
CUE_GEO = {"brow_eye_gap": 0.2, "brow_inner_gap": 0.2, "eye_open": 0.1, "mouth_corner": 0.02, "brow_inner_eye": 0.22, "brow_inner_gap2": 0.24}
CUE_BASE = {"mouth_smile": (0.10, 0.02), "brow_down": (0.01, 0.002), "eye_squint": (0.10, 0.02), "jaw_open": (0.05, 0.02)}


def cue_at(t):
    """その時刻の指示と、何回目か"""
    s, count = 10.0, {}
    for k, d in CUE_STEPS:
        if s <= t < s + d:
            return k, count.get(k, 0), s
        count[k] = count.get(k, 0) + 1
        s += d
    return None, 0, s


def build_cues():
    lines = [{"schema": "ability-cam.ios.v0.2", "started_at_ms": T0_MS, "camera": "front", "camera_label": "前面", "direction_version": 2,
              "note": "テスト用の作り物（試すモード）"}]
    m = {k: {"n": 300, "mean": mu, "std": sd, "median": mu, "insufficient": False} for k, (mu, sd) in CUE_BASE.items()}
    for k, v in CUE_GEO.items():
        m[k] = {"n": 300, "mean": v, "std": 0.003, "median": v, "insufficient": False}
    for k in ("orbit", "nose_lip", "mouth_tense", "cheek_raise"):
        m[k] = {"n": 300, "mean": 0.05, "std": 0.02, "median": 0.05, "insufficient": False}
    lines.append({"type": "baseline", "t_ms": T0_MS + 10_000, "started_ms": T0_MS, "valid_s": 10.0, "min_n": 30, "target_s": 10.0,
                  "blink_masked": True, "source": "today", "compared": True, "part": "face", "metrics": m,
                  "pose": {"yaw_deg": {"n": 300, "mean": 2.0, "std": 1.0, "median": 2.0, "insufficient": False}}})
    rows = []
    s = 10.0
    for k, d in CUE_STEPS:
        e = event(s + d, "cue", k)
        e["start_ms"], e["end_ms"] = T0_MS + int(round(s * 1000)), T0_MS + int(round((s + d) * 1000))
        rows.append((s + d, e))
        s += d
    end = s + 3
    for i in range(int(end * FPS)):
        t = i / FPS
        kind, rep, _ = cue_at(t)
        v = {k: mu for k, (mu, _) in CUE_BASE.items()}
        v["rms_db"] = -50.0
        v["brow_down"] = round(0.01 + 0.001 * math.sin(t * 1.3), 4)
        geo = dict(CUE_GEO)
        yaw = 2.0
        if kind == "frown":
            v["brow_down"] = 0.012 if rep == 2 else 0.06
            geo["brow_inner_eye"] = 0.22 if rep == 2 else 0.195
            geo["brow_inner_gap"] = 0.198
        if kind == "smile":
            v["mouth_smile"] = 0.5
            geo["mouth_corner"] = 0.05
        if kind == "frown_max":
            v["brow_down"] = 0.15
            geo.update(brow_inner_eye=0.18, brow_eye_gap=0.19, brow_inner_gap=0.195, brow_inner_gap2=0.22)
        if kind == "smile_max":
            v["mouth_smile"] = 0.9
            geo["mouth_corner"] = 0.08
        if kind == "turn":
            yaw = 30.0
        o = frame_obj(t, v, True, yaw, None)
        if abs(yaw) <= 25:
            o["geo"] = geo
        rows.append((t, o))
    rows.sort(key=lambda r: r[0])
    return lines + [r[1] for r in rows]


def write(name, objs):
    out = Path(__file__).with_name(name)
    out.write_text("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in objs), encoding="utf-8")
    print(out)


if __name__ == "__main__":
    write("fixture_basic.jsonl", build())
    write("fixture_eyes.jsonl", build_eyes())
    write("fixture_voice.jsonl", build_voice())
    write("fixture_cues.jsonl", build_cues())
