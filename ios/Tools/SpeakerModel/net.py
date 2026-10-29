"""WeSpeaker ResNet34（pyannote/wespeaker-voxceleb-resnet34-LM と同じ形）を自分で書いたもの。重みは load_ckpt で読む"""
import torch
import torch.nn as nn
import torch.nn.functional as F
import torchaudio.compliance.kaldi as kaldi


class Block(nn.Module):
    def __init__(self, cin, cout, stride):
        super().__init__()
        self.conv1 = nn.Conv2d(cin, cout, 3, stride, 1, bias=False); self.bn1 = nn.BatchNorm2d(cout)
        self.conv2 = nn.Conv2d(cout, cout, 3, 1, 1, bias=False); self.bn2 = nn.BatchNorm2d(cout)
        self.shortcut = nn.Sequential()
        if stride != 1 or cin != cout:
            self.shortcut = nn.Sequential(nn.Conv2d(cin, cout, 1, stride, bias=False), nn.BatchNorm2d(cout))

    def forward(self, x):
        o = F.relu(self.bn1(self.conv1(x)))
        return F.relu(self.bn2(self.conv2(o)) + self.shortcut(x))


class ResNet34(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 32, 3, 1, 1, bias=False); self.bn1 = nn.BatchNorm2d(32)
        def layer(cin, cout, n, s): return nn.Sequential(*[Block(cin if i == 0 else cout, cout, s if i == 0 else 1) for i in range(n)])
        self.layer1 = layer(32, 32, 3, 1); self.layer2 = layer(32, 64, 4, 2)
        self.layer3 = layer(64, 128, 6, 2); self.layer4 = layer(128, 256, 3, 2)
        self.seg_1 = nn.Linear(5120, 256)

    def frames(self, fbank):            # fbank (B, T, 80) → (B, 2560, T/8)
        x = fbank.permute(0, 2, 1).unsqueeze(1)
        x = F.relu(self.bn1(self.conv1(x)))
        x = self.layer4(self.layer3(self.layer2(self.layer1(x))))
        return x.flatten(1, 2)

    def forward(self, fbank, weights):   # weights (B, T/8)：使うフレームの重み
        x = self.frames(fbank)
        w = weights.unsqueeze(1)
        v1 = w.sum(dim=2) + 1e-8
        mean = (x * w).sum(dim=2) / v1
        v2 = (w * w).sum(dim=2)
        var = ((x - mean.unsqueeze(2)) ** 2 * w).sum(dim=2) / (v1 - v2 / v1 + 1e-8)
        return self.seg_1(torch.cat([mean, torch.sqrt(var)], dim=1))


def load(path):
    import load_ckpt
    sd = {k[len("resnet."):]: v for k, v in load_ckpt.load(path).items() if k.startswith("resnet.")}
    m = ResNet34()
    missing, unexpected = m.load_state_dict(sd, strict=False)
    assert not missing and all("num_batches" in k for k in unexpected), (missing, unexpected)
    return m.eval()


def fbank(wave16k):                       # (N,) float -1..1 → (T, 80)、平均を引いたもの（pyannote と同じ）
    f = kaldi.fbank((wave16k * 32768).unsqueeze(0), num_mel_bins=80, frame_length=25, frame_shift=10, dither=0.0,
                    window_type="hamming", use_energy=False, sample_frequency=16000)
    return f - f.mean(dim=0, keepdim=True)


def frames_out(t):                         # ResNet の出力のフレーム数
    for _ in range(3): t = (t - 1) // 2 + 1
    return t
