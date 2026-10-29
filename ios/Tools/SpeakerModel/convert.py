"""話者の区別のモデルを、1行・3秒の fbank を入れる形に Core ML に変換する（v1.10.2〜、アプリの AbilityCam/Models/wespeaker_3s.mlpackage）。

元の重み：https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM の pytorch_model.bin（CC BY 4.0、
revision 837717ddb9ff5507820346191109dc79c958d614、sha256 366edf44f4c80889a3eb7a9d7bdf02c4aede3127f7dd15e274dcdb826b143c56）。
ResNet は net.py に自分で書いたもの（pyannote のコードは使わない）。重みは load_ckpt.py が weights_only=True で読む。
使った環境：Python 3.12、torch 2.7.0、torchaudio 2.7.0、coremltools 9.0（Mac）。
使い方：python convert.py pytorch_model.bin 出力.mlpackage
Float16。Mac の Core ML の計算の予定では、111 の演算がすべて Neural Engine（docs/validation-log.md）。
入力 fbank (1, 298, 80)：3秒（48000 サンプル、16kHz）の kaldi fbank（80、25ms/10ms、hamming、平均を引いたもの。アプリの SpeakerFbank が求める）
入力 weights (1, 38)：ResNet の出力のフレームごとの重み（使う直近の声に 1）。出力 embedding (1, 256)"""
import sys, numpy as np, torch, coremltools as ct
import net

FRAMES, OUT = 298, net.frames_out(298)
m = net.load(sys.argv[1])
ex = (torch.randn(1, FRAMES, 80), torch.ones(1, OUT))
tr = torch.jit.trace(m, ex)
ml = ct.convert(tr, inputs=[ct.TensorType("fbank", shape=(1, FRAMES, 80), dtype=np.float32),
                            ct.TensorType("weights", shape=(1, OUT), dtype=np.float32)],
                outputs=[ct.TensorType("embedding", dtype=np.float32)],
                convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17)
ml.author = "WeSpeaker / pyannote (wespeaker-voxceleb-resnet34-LM), converted for Ability Cam"
ml.license = "CC BY 4.0"
ml.short_description = "WeSpeaker ResNet34-LM speaker embedding, 1 x 3 s fbank input (fbank computed outside the model)"
ml.save(sys.argv[2])
print("frames", FRAMES, "out", OUT)
