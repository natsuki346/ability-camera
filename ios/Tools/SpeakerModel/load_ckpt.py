"""pyannote の checkpoint から重みだけを読む（weights_only=True。pyannote のクラスは中身の無い代わりのクラスにして、コードは動かさない）"""
import re
import torch
from torch.torch_version import TorchVersion


class Stub:
    def __init__(self, *a, **k): self.args = a
    def __setstate__(self, s): self.state = s
    @classmethod
    def __new__(cls, *a, **k): return object.__new__(cls)


def load(path):
    names = []
    while True:
        try:
            with torch.serialization.safe_globals([TorchVersion] + [(type(n.split(".")[-1], (Stub,), {}), n) for n in names]):
                ck = torch.load(path, map_location="cpu", weights_only=True)
            return ck["state_dict"] if "state_dict" in ck else ck
        except Exception as e:
            m = re.search(r"Unsupported global: GLOBAL ([\w.]+)", str(e))
            if not m or m.group(1) in names or len(names) > 20:
                raise
            names.append(m.group(1))
