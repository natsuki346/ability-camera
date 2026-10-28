#!/usr/bin/env python3
"""声の高さ（f0）の求め方（アプリの ios/AbilityCam/Pitch.swift、v1.6.2〜）を Mac で確かめる。

ios/Tools/PitchCheck と Pitch.swift を swiftc でビルドし、WAV（16bit・1ch）を流す。
アプリと同じように、0.1秒ごとの音の塊の先頭 4096 サンプルで音量と f0 を求める。

使い方：
  python pitch_check.py 音.wav ...     塊の数・音の下限を超えた塊・f0 が取れた割合・f0 の範囲・2倍／半分の跳びを出す
                                       （部屋の音だけの WAV なら「f0 が取れた塊」が 0 になるはず）
  python pitch_check.py --selftest     作り物の音（声に似た音・雑音・範囲の外の高さ）で決まりどおりか確かめる

音の下限は環境変数 PITCH_FLOOR_DB で変えて試せる（アプリは criteria.json の pitch.floor_db）。
"""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "ios" / "AbilityCam" / "Pitch.swift", ROOT / "ios" / "Tools" / "PitchCheck" / "main.swift"]
SR = 48000


def build() -> Path:
    if not shutil.which("swiftc"):
        raise RuntimeError("swiftc がありません（Xcode の入った Mac で動かしてください）")
    h = hashlib.sha1(b"".join(p.read_bytes() for p in SOURCES)).hexdigest()[:12]
    out = Path(tempfile.gettempdir()) / f"ability-pitchcheck-{h}"
    if not out.exists():
        subprocess.run(["swiftc", "-O", "-o", str(out), *map(str, SOURCES)], check=True)
    return out


def run(exe: Path, wav: Path) -> list[dict]:
    p = subprocess.run([str(exe), str(wav)], check=True, capture_output=True, text=True)
    return [json.loads(x) for x in p.stdout.splitlines() if x.strip()]


def run_signal(exe: Path, x: np.ndarray) -> list[dict]:
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "x.wav"
        write_wav(p, x)
        return run(exe, p)


def write_wav(path: Path, x: np.ndarray, sr: int = SR) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())


def summarize(rows: list[dict], floor_db: float) -> dict:
    loud = [r for r in rows if r["rms_db"] >= floor_db]
    f0 = np.array([r["f0_hz"] for r in rows if r["f0_hz"] is not None], dtype=float)
    seq = [r["f0_hz"] for r in rows]
    jumps = sum(1 for a, b in zip(seq, seq[1:]) if a and b and abs(np.log2(b / a)) > 0.75)
    return {"chunks": len(rows), "above_floor": len(loud), "f0": len(f0),
            "f0_ratio_of_above_floor": round(len(f0) / len(loud), 3) if loud else None,
            "f0_min": float(f0.min()) if len(f0) else None, "f0_median": float(np.median(f0)) if len(f0) else None,
            "f0_max": float(f0.max()) if len(f0) else None, "octave_jumps": jumps}


# ---- 作り物の音 ----

def at_db(x: np.ndarray, db: float) -> np.ndarray:
    return x * 10 ** (db / 20) / np.sqrt(np.mean(x ** 2))


def noise(kind: str, secs: float, seed: int = 1) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = int(SR * secs)
    w = rng.standard_normal(n)
    if kind == "white":
        return w
    f = np.fft.rfftfreq(n, 1 / SR)
    f[0] = f[1]
    F = np.fft.rfft(w)
    if kind == "pink":
        F /= np.sqrt(f)
    elif kind == "brown":
        F /= f
    elif kind == "fan":   # 低い方に寄った雑音＋弱い 120Hz のうなり
        F /= 1 + (f / 300) ** 2
        y = np.fft.irfft(F, n)
        return y / np.std(y) + 0.3 * np.sin(2 * np.pi * 120 * np.arange(n) / SR)
    return np.fft.irfft(F, n)


def voice_like(f0: float, secs: float, weak_fundamental: bool = False, seed: int = 2) -> np.ndarray:
    """声に似た音：f0 の倍音（5Hz・2% の揺れ）に、母音のような山（700Hz・1200Hz・2600Hz）をかけたもの"""
    rng = np.random.default_rng(seed)
    n = int(SR * secs)
    t = np.arange(n) / SR
    inst = f0 * (1 + 0.02 * np.sin(2 * np.pi * 5 * t) + 0.003 * rng.standard_normal(n).cumsum() / np.sqrt(n))
    phase = 2 * np.pi * np.cumsum(inst) / SR
    y = np.zeros(n)
    for k in range(1, int(4000 / f0) + 1):
        fk = k * f0
        env = sum(a / (1 + ((fk - c) / bw) ** 2) for c, bw, a in ((700, 150, 1.0), (1200, 200, 0.6), (2600, 300, 0.25)))
        amp = env / k ** 0.5
        if k == 1 and weak_fundamental:
            amp *= 0.1
        y += amp * np.sin(k * phase)
    return y


def selftest(exe: Path) -> list[str]:
    """決まりどおりでないものを返す（空なら合格）"""
    bad = []
    bg = at_db(noise("pink", 3, seed=9), -72)
    for f0 in (85, 120, 220, 330, 450):
        rows = run_signal(exe, at_db(voice_like(f0, 3), -58) + bg)
        got = np.array([r["f0_hz"] for r in rows if r["f0_hz"] is not None])
        ok = np.abs(got / f0 - 1) <= 0.05
        if len(got) < 0.9 * len(rows) or ok.mean() < 0.95:
            bad.append(f"声に似た音 {f0}Hz（-58dB）：取れた {len(got)}/{len(rows)}、5% 以内 {ok.sum()}")
    rows = run_signal(exe, at_db(voice_like(150, 3, weak_fundamental=True), -50))
    got = np.array([r["f0_hz"] for r in rows if r["f0_hz"] is not None])
    if len(got) < 0.9 * len(rows) or (np.abs(got / 150 - 1) > 0.05).any():
        bad.append(f"基音の弱い 150Hz：{np.round(got)}")
    for f in (650, 900):
        rows = run_signal(exe, at_db(np.sin(2 * np.pi * f * np.arange(SR * 2) / SR), -40))
        got = [r["f0_hz"] for r in rows if r["f0_hz"] is not None]
        if got:
            bad.append(f"範囲の外の {f}Hz が f0 になった：{got[:5]}")
    for kind in ("white", "pink", "brown", "fan"):
        for db in (-55, -45):
            rows = run_signal(exe, at_db(noise(kind, 10), db))
            got = [r["f0_hz"] for r in rows if r["f0_hz"] is not None]
            if got:
                bad.append(f"雑音（{kind}、{db}dB）が f0 になった：{len(got)}件")
    rows = run_signal(exe, at_db(voice_like(200, 2), -66))
    if any(r["f0_hz"] is not None for r in rows):
        bad.append("下限より小さい音で f0 が出た")
    return bad


def main(argv=None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    if not args:
        print(__doc__)
        return 2
    exe = build()
    if args == ["--selftest"]:
        bad = selftest(exe)
        print("\n".join(bad) if bad else "決まりどおりでした")
        return 1 if bad else 0
    crit = json.loads((Path(__file__).parent / "criteria.json").read_text())
    import os
    floor = float(os.environ.get("PITCH_FLOOR_DB", crit["pitch"]["floor_db"]))
    for a in args:
        print(Path(a).name, json.dumps(summarize(run(exe, Path(a)), floor), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
