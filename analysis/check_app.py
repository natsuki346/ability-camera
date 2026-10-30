#!/usr/bin/env python3
"""アプリ（撮る側・リプレイの DiffEngine）と振り返りレポート（review.py）で、同じ記録の区間が一致するかを確かめる（Mac のみ）。

ios/Tools/DiffCheck と、アプリのファイル（Replay.swift など）を swiftc でビルドし、記録を両方に流して比べる。
比べるもの：区間の数・種類（指標と向き / 目を閉じている）・開始の時刻・終了の時刻・ピークの z。重なりのできごと（v1.12〜）の数・時刻・向き・指標。試すモード（v1.18〜）の結果（DiffCheck --cues と face_check.py --cues）。
記録の終わりで打ち切った区間の終了の時刻は比べない（アプリは最後に続いていたコマ、レポートは最後のコマにするため）。

使い方：python check_app.py 記録.jsonl ...      一致すれば 0、違えば 1 を返す
"""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import review

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "ios" / "AbilityCam"
SOURCES = [APP / n for n in ("Replay.swift", "FaceSketch.swift", "HeadTurn.swift", "Baseline.swift", "DiffEngine.swift", "Pitch.swift", "MarkDetail.swift", "Cues.swift", "FrameGap.swift")] \
    + [ROOT / "ios" / "Tools" / "DiffCheck" / "main.swift"]
TOL_S = 0.0015      # 時刻は ms で書かれているので、1.5ms までの差は同じとみなす
TOL_Z = 1e-6


def build() -> Path:
    """ソースが変わったときだけビルドし直す"""
    if not shutil.which("swiftc"):
        raise RuntimeError("swiftc がありません（Xcode の入った Mac で動かしてください）")
    h = hashlib.sha1(b"".join(p.read_bytes() for p in SOURCES)).hexdigest()[:12]
    out = Path(tempfile.gettempdir()) / f"ability-diffcheck-{h}"
    if not out.exists():
        subprocess.run(["swiftc", "-O", "-o", str(out), *map(str, SOURCES)], check=True)
    return out


def app_segments(exe: Path, path: Path) -> list[dict]:
    p = subprocess.run([str(exe), str(path)], check=True, capture_output=True, text=True)
    return [json.loads(x) for x in p.stdout.splitlines() if x.strip()]


def report_segments(path: Path, c: dict) -> list[dict]:
    a = review.analyze(review.load(path), c)
    t = a.rec.t
    return [{"kind": s.metric, "above": s.sign > 0, "start": float(t[s.i0]), "end": float(t[s.i1]),
             "peak_z": None if s.metric == review.EYES else s.peak_z, "at_end": "記録の終わり" in s.truncated}
            for s in a.segments]


def key(s: dict) -> tuple:
    return (round(s["start"], 3), review.SEG_KINDS.index(s["kind"]))


def compare(path: Path, exe: Path, c: dict) -> tuple[list[str], int]:
    """返り値：(違い, 区間の数)"""
    app = sorted(app_segments(exe, path), key=key)
    rep = sorted(report_segments(path, c), key=key)
    diffs = []
    if len(app) != len(rep):
        diffs.append(f"区間の数が違います：アプリ {len(app)}件 / レポート {len(rep)}件")
    for x, y in zip(app, rep):
        where = f"{review.jst(y['start'], ms=True)} {review.LABEL[y['kind']]}"
        if x["kind"] != y["kind"] or x["above"] != y["above"]:
            diffs.append(f"{where}：種類が違います（アプリ {x['kind']} {x['above']}）")
        if abs(x["start"] - y["start"]) > TOL_S:
            diffs.append(f"{where}：開始が違います（アプリ {review.jst(x['start'], ms=True)}）")
        if not y["at_end"] and abs(x["end"] - y["end"]) > TOL_S:
            diffs.append(f"{where}：終了が違います（アプリ {review.jst(x['end'], ms=True)} / レポート {review.jst(y['end'], ms=True)}）")
        if y["peak_z"] is not None and abs(x.get("peak_z", float("nan")) - y["peak_z"]) > TOL_Z:
            diffs.append(f"{where}：ピークの z が違います（アプリ {x.get('peak_z')} / レポート {y['peak_z']}）")
    return diffs, len(rep)


def compare_voice(path: Path, exe: Path, c: dict) -> list[str]:
    """本人の声の判定（v1.9〜）：声が出ていたコマごとに、アプリ（DiffCheck --voice、決め直したもの）と review.py の
    voice_self・理由・相関・どの顔の口と合っていたかを比べる。違いの一覧を返す"""
    p = subprocess.run([str(exe), "--voice", str(path)], check=True, capture_output=True, text=True)
    app = [json.loads(x) for x in p.stdout.splitlines() if x.strip()]
    rec = review.load(path)
    d = review.voice_self_details(rec, c, review.face_valid(rec, c), use_recorded=False)
    idx = [i for i in range(len(rec.t)) if d.values[i] == d.values[i]]
    if len(app) != len(idx):
        return [f"声が出ていたコマの数が違います：アプリ {len(app)} / レポート {len(idx)}"]
    out = []
    for x, i in zip(app, idx):
        where = review.jst(float(rec.t[i]), ms=True)
        sync_on = (c["voice_self"].get("sync") or {}).get("enabled", True)
        rep = {"voice_self": bool(d.values[i] == 1), "reason": d.reason[i], **({"match": d.match[i]} if sync_on else {})}
        for k, v in rep.items():
            if x.get(k) != v:
                out.append(f"{where}：{k} が違います（アプリ {x.get(k)} / レポート {v}）")
        if not (c["voice_self"].get("sync") or {}).get("enabled", True):
            continue   # タイミングを判定に使わないとき（v1.9.1〜）、アプリは相関を求めない（レポートだけ）
        for k, arr in (("corr", d.corr), ("corr_other", d.corr_other)):
            a, b = x.get(k), arr[i]
            if (a is None) != (b != b) or (a is not None and abs(a - b) > 1e-9):
                out.append(f"{where}：{k} が違います（アプリ {a} / レポート {b}）")
    return out


def compare_co(path: Path, exe: Path, c: dict) -> tuple[list[str], int]:
    """重なりのできごと（v1.12〜）：アプリ（DiffCheck --co）と review.py の detect_co_change の、数・始まり・終わり・向き・指標を比べる"""
    p = subprocess.run([str(exe), "--co", str(path)], check=True, capture_output=True, text=True)
    app = sorted((json.loads(x) for x in p.stdout.splitlines() if x.strip()), key=lambda o: (round(o["start"], 3), not o["above"]))
    a = review.analyze(review.load(path), c)
    t = a.rec.t
    rep = [{"start": float(t[e["i0"]]), "end": float(t[e["i1"]]), "above": e["above"], "metrics": e["metrics"], "groups": e["groups"]}
           for e in a.co_changes]
    out = []
    if len(app) != len(rep):
        out.append(f"重なりのできごとの数が違います：アプリ {len(app)}件 / レポート {len(rep)}件")
    for x, y in zip(app, rep):
        where = f"{review.jst(y['start'], ms=True)} 重なり"
        if abs(x["start"] - y["start"]) > TOL_S or abs(x["end"] - y["end"]) > TOL_S:
            out.append(f"{where}：時刻が違います（アプリ {review.jst(x['start'], ms=True)}〜{review.jst(x['end'], ms=True)}）")
        for k in ("above", "metrics", "groups"):
            if x[k] != y[k]:
                out.append(f"{where}：{k} が違います（アプリ {x[k]} / レポート {y[k]}）")
    return out, len(rep)


def diff_json(x, y, where: str = "", tol: float = 1e-6) -> list[str]:
    """2つの JSON の値の違い（数は tol まで同じとみなす）"""
    if isinstance(x, dict) and isinstance(y, dict):
        out = []
        for k in sorted(set(x) | set(y)):
            # アプリ（Swift の Codable）は nil のキーを書かないので、無いキーと null は同じとみなす
            out += diff_json(x.get(k), y.get(k), f"{where}.{k}", tol)
        return out
    if isinstance(x, list) and isinstance(y, list):
        if len(x) != len(y):
            return [f"{where}：数が違う（アプリ {len(x)} / レポート {len(y)}）"]
        return [d for i, (a, b) in enumerate(zip(x, y)) for d in diff_json(a, b, f"{where}[{i}]", tol)]
    if isinstance(x, (int, float)) and isinstance(y, (int, float)) and not isinstance(x, bool) and not isinstance(y, bool):
        return [] if abs(x - y) <= tol else [f"{where}：アプリ {x} / レポート {y}"]
    return [] if x == y else [f"{where}：アプリ {x} / レポート {y}"]


def compare_cues(path: Path, exe: Path, c: dict) -> tuple[list[str], bool]:
    """試すモード（v1.18〜）：アプリ（DiffCheck --cues）と face_check.py --cues の結果（その人の最大・下限を変える前と後の表）を比べる。
    返り値：(違い, 試すモードの指示があったか)"""
    import face_check
    p = subprocess.run([str(exe), "--cues", str(path)], check=True, capture_output=True, text=True)
    app = json.loads(p.stdout.strip() or "null")
    rep = face_check.cue_trial(review.load(path), c)
    if app is None and rep is None:
        return [], False
    return diff_json(app, rep, "試すモード", tol=2e-3), True


def main(argv=None) -> int:
    args = [Path(x) for x in (argv if argv is not None else sys.argv[1:])]
    if not args:
        print(__doc__)
        return 2
    c = review.load_criteria(review.HERE / "criteria.json", [])
    exe = build()
    bad = 0
    for p in args:
        diffs, n = compare(p, exe, c)
        vd = compare_voice(p, exe, c)   # 本人の声の判定もコマごとに（v1.9〜）
        diffs += vd[:10] + ([f"ほか本人の声の判定の違い {len(vd) - 10}件"] if len(vd) > 10 else [])
        cd, nco = compare_co(p, exe, c)   # 重なりのできごと（v1.12〜）
        diffs += cd
        qd, has_cues = compare_cues(p, exe, c)   # 試すモード（v1.18〜）
        diffs += qd
        kinds = {}
        for s in report_segments(p, c):
            kinds[s["kind"]] = kinds.get(s["kind"], 0) + 1
        detail = "、".join(f"{review.LABEL[k]} {v}" for k, v in sorted(kinds.items(), key=lambda kv: review.SEG_KINDS.index(kv[0])))
        print(f"{p.name}: {'一致' if not diffs else '違いあり'}（区間 {n}件{'：' + detail if detail else ''}・重なり {nco}件{'・試すモードの結果' if has_cues else ''}）")
        for d in diffs:
            print("  " + d)
        bad += bool(diffs)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
