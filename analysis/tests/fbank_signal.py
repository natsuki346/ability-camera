"""fbank のテストに使う作り物の音（1秒、16kHz、int16）。乱数を使わず、だれが作っても同じになるもの"""
import numpy as np


def signal() -> np.ndarray:
    n = 16000
    t = np.arange(n) / 16000
    chirp = np.sin(2 * np.pi * (100 * t + (6000 - 100) / 2 * t * t))
    voice = sum(np.sin(2 * np.pi * 180 * k * t) / k for k in range(1, 12)) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t))
    lcg, noise = 12345, np.empty(n)
    for i in range(n):
        lcg = (1103515245 * lcg + 12345) % (1 << 31)
        noise[i] = lcg / (1 << 30) - 1
    x = 0.2 * chirp + 0.15 * voice + 0.02 * noise
    return np.round(np.clip(x, -1, 1) * 32767).astype(np.int16)


def write_wav(path) -> None:
    import wave
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(signal().tobytes())
