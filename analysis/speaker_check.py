#!/usr/bin/env python3
"""話者の区別（アプリの ios/AbilityCam/Speaker.swift、v1.10〜）を Mac で確かめる。

ios/Tools/SpeakerCheck と Speaker.swift を swiftc でビルドし、アプリと同じ Core ML のモデル（ios/AbilityCam/Resources/wespeaker.mlmodelc、
v1.10.2〜は ios/AbilityCam/Models/wespeaker_3s.mlpackage を Mac でコンパイルしたもの）で、WAV の声の特徴の数値（埋め込み）を求める。埋め込みはこの道具の中だけで使い、ファイルには書かない。

使い方：
  python speaker_check.py --enroll 名前=登録用.wav ... --test 名前=確かめる.wav ... [--spans 3,1.5,1,0.5]
      登録用の声から人ごとの登録（埋め込みの平均）を作り、確かめる声を span 秒ずつに区切って、いちばん似ている人が合っていた割合と、
      同じ人・ほかの人との似ている度合い、1回の計算時間（Mac）を出す
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "ios" / "AbilityCam" / "Models" / "wespeaker_3s.mlpackage"   # v1.10.2〜（ios/Tools/SpeakerModel/convert.py で変換したもの）
MODEL = PACKAGE   # 使うときは compiled_model() でコンパイルしたもの
SOURCES = [ROOT / "ios" / "AbilityCam" / "Speaker.swift", ROOT / "ios" / "Tools" / "SpeakerCheck" / "main.swift"]


def build() -> Path:
    if not shutil.which("swiftc"):
        raise RuntimeError("swiftc がありません（Xcode の入った Mac で動かしてください）")
    h = hashlib.sha1(b"".join(p.read_bytes() for p in SOURCES)).hexdigest()[:12]
    out = Path(tempfile.gettempdir()) / f"ability-speakercheck-{h}"
    if not out.exists():
        subprocess.run(["swiftc", "-O", "-o", str(out), *map(str, SOURCES)], check=True)
    return out


def compiled_model(package: Path = PACKAGE) -> Path:
    """mlpackage を Mac でコンパイルする（中身が変わったときだけ）"""
    h = hashlib.sha1(b"".join(p.read_bytes() for p in sorted(package.rglob("*")) if p.is_file())).hexdigest()[:12]
    out = Path(tempfile.gettempdir()) / f"ability-speakermodel-{h}"
    if not (out / f"{package.stem}.mlmodelc").exists():
        out.mkdir(exist_ok=True)
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)], check=True, capture_output=True)
    return out / f"{package.stem}.mlmodelc"


def fbank(exe: Path, wav: Path) -> np.ndarray:
    """アプリと同じ fbank（SpeakerFbank）。(フレーム数, 80)"""
    p = subprocess.run([str(exe), "--fbank", str(wav)], check=True, capture_output=True, text=True)
    o = json.loads(p.stdout)
    return np.array(o["fbank"], dtype=float).reshape(o["frames"], o["bins"])


def plan(exe: Path) -> str:
    return subprocess.run([str(exe), "--plan", str(compiled_model())], check=True, capture_output=True, text=True).stdout


def embeddings(exe: Path, wavs: list[Path], span: float, step: float) -> list[dict]:
    p = subprocess.run([str(exe), str(compiled_model()), *map(str, wavs), "--span", str(span), "--step", str(step)],
                       check=True, capture_output=True, text=True)
    return [json.loads(x) for x in p.stdout.splitlines() if x.strip()]


def unit(v: np.ndarray) -> np.ndarray:
    return v / np.linalg.norm(v)


def evaluate(exe: Path, enroll: dict[str, Path], test: dict[str, Path], spans: list[float]) -> dict:
    """返り値：{"enrolled": 人ごとの登録に使った数, "rows": [(span, 合っていた割合, 同じ人の似ている度合いの中央値, ほかの人の中央値, 計算 ms の中央値, 数)]}"""
    reg = {}
    for name, wav in enroll.items():
        e = embeddings(exe, [wav], 1.5, 1.5)
        reg[name] = (unit(np.mean([unit(np.array(x["embedding"])) for x in e], axis=0)), len(e))
    rows = []
    for span in spans:
        hit, same, other, ms, n = 0, [], [], [], 0
        for name, wav in test.items():
            for x in embeddings(exe, [wav], span, max(span, 0.5)):
                v = unit(np.array(x["embedding"]))
                sims = {k: float(v @ r) for k, (r, _) in reg.items()}
                best = max(sims, key=sims.get)
                hit += best == name
                n += 1
                same.append(sims[name])
                other += [s for k, s in sims.items() if k != name]
                ms.append(x["calc_ms"])
        rows.append((span, hit / n if n else None, float(np.median(same)) if same else None,
                     float(np.median(other)) if other else None, float(np.median(ms)) if ms else None, n))
    return {"enrolled": {k: v[1] for k, v in reg.items()}, "rows": rows}


def pairs(values: list[str]) -> dict[str, Path]:
    out = {}
    for v in values:
        name, _, path = v.partition("=")
        out[name] = Path(path)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--enroll", nargs="+", required=True)
    ap.add_argument("--test", nargs="+", required=True)
    ap.add_argument("--spans", default="3,1.5,1,0.5")
    args = ap.parse_args(argv)
    if not MODEL.exists():
        print(f"モデルがありません：{MODEL}（ios/Tools/SpeakerModel/convert.py で作ります）")
        return 2
    r = evaluate(build(), pairs(args.enroll), pairs(args.test), [float(x) for x in args.spans.split(",")])
    print("登録に使った声のまとまり：" + "、".join(f"{k} {v}" for k, v in r["enrolled"].items()))
    print("声の長さ\tいちばん似ている人が合っていた\t同じ人の似ている度合い（中央値）\tほかの人（中央値）\t計算 ms（Mac、中央値）\t数")
    f = lambda v, p="{:.2f}": "–" if v is None else p.format(v)
    for span, acc, same, other, ms, n in r["rows"]:
        print(f"{span:g}秒\t{f(acc, '{:.0%}')}\t{f(same)}\t{f(other)}\t{f(ms, '{:.1f}')}\t{n}")
    print("Core ML の計算の予定（Mac。演算の数：ne＝Neural Engine）：\n" + plan(build()).strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
