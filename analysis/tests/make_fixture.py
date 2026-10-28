#!/usr/bin/env python3
"""テスト用の小さな JSONL（作り物の数値。人の記録ではない）を作る。

時間割（開始からの秒）：
  0–10   普段の記録。10秒の時点で baseline 行（f0_hz は insufficient）
  20–21  brow_down を高く（z≈5）           → 区間 1件（上）
  30–30.3 brow_down を高く                  → 短い動き 1件
  40–42  brow_down を高く、41–41.3 だけ z≈1.7 に下げる → ヒステリシスで 区間 1件のまま
  50–52  brow_down を高く、ただし yaw 50°   → 判定対象外（区間なし）
  60–62  顔が映らない                        → 判定対象外（区間なし）
  70–71.5 rms_db を大きく（f0 も高く）       → rms_db 区間（上）、f0 は insufficient なので無し
  80–81.5 rms_db を小さく                   → rms_db 区間（下）
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
"""
import json
import math
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
    if 70 <= t < 71.5:
        v["rms_db"], f0 = -30.0, 320.0
    if 80 <= t < 81.5:
        v["rms_db"] = -65.0
    if 105 <= t < 106:
        v["jaw_open"] = 0.5
    return frame_obj(t, v, face, yaw, f0)


def frame_obj(t, v, face, yaw, f0, blink=0.05):
    o = {"type": "frame", "t_ms": T0_MS + int(round(t * 1000)), "face": face,
         "rms_db": v["rms_db"], "proc_ms": 12.0, "lat_ms": 60.0 + 10 * math.sin(t)}
    if face:
        o["bs"] = bs_from(v)
        o["bs"]["eyeBlinkLeft"] = o["bs"]["eyeBlinkRight"] = blink
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


def write(name, objs):
    out = Path(__file__).with_name(name)
    out.write_text("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in objs), encoding="utf-8")
    print(out)


if __name__ == "__main__":
    write("fixture_basic.jsonl", build())
    write("fixture_eyes.jsonl", build_eyes())
