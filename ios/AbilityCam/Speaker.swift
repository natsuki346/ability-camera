import Accelerate
import CoreML
import Foundation

/// 話者の区別（v1.10〜、docs/speaker-plan.md の最初の段階）：だれの声かを分けて記録するためだけに使う。本人確認・認証には使わない。
/// 画面には出さず、記録（type: "speaker" の行）に、登録した人ごとの似ている度合いと、使った声の長さ・計算時間だけを書く。
/// 声の特徴の数値（埋め込み）は persons.json の中だけ。声そのものは保存しない（メモリの輪のバッファだけ）。
///
/// モデル（v1.10.2〜）：WeSpeaker ResNet34-LM（pyannote/wespeaker-voxceleb-resnet34-LM、CC BY 4.0。README の「ライセンス」）の重みを、
/// このリポジトリで Core ML に変換したもの（ios/Tools/SpeakerModel/convert.py → AbilityCam/Models/wespeaker_3s.mlpackage）。
/// 入力は直近 3秒の fbank（1行、298×80。SpeakerFbank がこの端末で求める）と、ResNet の出力のフレームごとの重み（38、使う直近の声に 1）。
/// v1.10〜v1.10.1 の Fluid Inference の変換（10秒×3行、fbank もモデルの中）は、iPhone で約210ms かかり、Neural Engine で動いていなかった（docs/validation-log.md）
enum SpeakerCriteria {
    static let model = "wespeaker-r34lm-3s-fp16-v2"         // 記録のヘッダ・行に書く版。モデルを替えたら変える（前の登録は使わない）
    static let resourceName = "wespeaker_3s"
    static let sampleRate = 16_000
    static let windowSamples = 48_000                       // モデルの入力（3秒、固定）
    static let fbankFrames = 298                            // 3秒の fbank のフレーム数（25ms・10ms、端は切る）
    static let maskFrames = 38                              // ResNet の出力のフレーム数（298 を 3回半分にしたもの）
    static let maxSpanS = 3.0                               // 埋め込みに使う直近の声の長さの上限（＝入力の長さ）
    static let minSpanS = 0.2                               // これより短い声は計算しない（1.5秒未満も計算して、長さを記録に書く）
    static let hopS = 0.5                                   // 声が出ている間、この間隔で1回
    static let voiceGapS = 0.3                              // これより長く声が途切れたら（下の voicedFloorDb の決め方で）、声のまとまりを切る
    /// 声が出ているか（v1.10.2〜）：f0 がある、または声の大きさがこれ以上。叫び声・息の多い声・スピーカーからの声は f0 が取れないことが多いため。
    /// 記録 ability-cam-20261029-114906 で、黙っている区間（95〜145秒）は -60〜-75dB、話している区間は -38〜-46dB。その間で、
    /// 黙っている区間の上端から 8dB、話している区間の下端から 6dB 離した値（analysis/criteria.json の speaker.voiced_floor_db と同じ）
    static let voicedFloorDb: Float = -52
    static let enrollTargetS = 30.0                         // 登録：声が合計これだけたまったら作る（仮の値）
    static let enrollMaxAgeDays = 14.0                      // 途中まで集めた登録は、集め始めてから14日で捨てる（声の普段と同じ）
    static let enrollProgressStepS = 5.0                    // 登録の途中、たまった秒数がこれだけ増えるごとに、似ている度合いを記録に書く（v1.10.1〜、30秒の根拠を決めるため）
    static let selfGateWaitMs: Int64 = 3000                 // 本人を登録するとき、声のまとまりの終わりのコマがこれだけ待っても来なければ数えない（v1.10.1〜）
}

/// 声の登録で、何を集めるか（v1.10.1〜。記録の event speaker_enroll の collect）
enum SpeakerEnrollCollect: String {
    case voiceSelf = "voice_self"   // 選んでいる人（本人）：今の判定で本人の声とされた時間（voice_self が true）だけ
    case voiced                     // ほかの人：声が出ている時間すべて（v1.10 と同じ）
}

/// 本人を登録するとき（v1.10.1〜）：声のまとまりの埋め込みを、そのまとまりのコマの voice_self が分かるまで待ち、数えるかを決める。
/// 数える：使った声のまとまり全体に voice_self が false のコマが無く、数える分（終わりから min(使った長さ, 0.5秒)）のコマがすべて true（1コマ以上）
struct SpeakerSelfGate<Item> {
    /// 決まったときの結果（v1.10.2〜、数えなかった理由も）
    enum Outcome: Equatable {
        case counted     // 数えた
        case notSelf     // 使った声のまとまりに voice_self: false のコマがあった
        case noF0        // false は無いが、数える分に voice_self: null（f0 が取れていない）のコマがあった（記録の skipped_no_f0_s）
        case noFrames    // 数える分のコマが無い・待っても来なかった
    }

    private var frames: [(t: Int64, v: Bool?)] = []        // 時刻の順（映像のコマ）
    private var pending: [(endMs: Int64, spanS: Double, item: Item)] = []

    mutating func frame(tMs: Int64, voiceSelf: Bool?) {
        if let last = frames.last, tMs <= last.t { return }
        frames.append((tMs, voiceSelf))
        let keep = tMs - Int64((SpeakerCriteria.maxSpanS + 7) * 1000)
        if let i = frames.firstIndex(where: { $0.t >= keep }), i > 0 { frames.removeFirst(i) }
    }

    mutating func embedding(endMs: Int64, spanS: Double, item: Item) { pending.append((endMs, spanS, item)) }

    /// 決まったもの（数えるか）を古い順に返す。nowMs：今の時刻（コマが来ないまま待ちすぎたものは数えない）
    mutating func ready(nowMs: Int64) -> [(item: Item, outcome: Outcome)] {
        var out: [(item: Item, outcome: Outcome)] = []
        let lastT = frames.last?.t ?? Int64.min
        while let p = pending.first, lastT >= p.endMs || nowMs - p.endMs > SpeakerCriteria.selfGateWaitMs {
            pending.removeFirst()
            out.append((p.item, lastT >= p.endMs ? decide(endMs: p.endMs, spanS: p.spanS) : .noFrames))
        }
        return out
    }

    mutating func clear() { frames = []; pending = [] }

    private func decide(endMs: Int64, spanS: Double) -> Outcome {
        let start = endMs - Int64((spanS * 1000).rounded())
        let counted = endMs - Int64((min(spanS, SpeakerCriteria.hopS) * 1000).rounded())
        var n = 0, null = false
        for f in frames where f.t >= start && f.t <= endMs {
            if f.v == false { return .notSelf }
            if f.t >= counted { if f.v == nil { null = true } else { n += 1 } }
        }
        return null ? .noF0 : n > 0 ? .counted : .noFrames
    }
}

/// 声の登録（persons.json の中だけ。記録には書かない）
struct SpeakerEnrollment: Codable, Equatable {
    var model: String
    var embedding: [Float]          // 登録に使った声のまとまりの埋め込み（長さ1）の平均を、長さ1にしたもの
    var n: Int                      // 使った声のまとまりの数
    var validS: Double              // 使った声の長さの合計
    var savedMs: Int64
    var spread: Double?             // まとまりどうしの似ている度合いのばらつき（1 − 平均との似ている度合い の平均）
    var consentBy: String           // 登録に同意した人（名前。この端末の中だけ）
    var consentMs: Int64

    enum CodingKeys: String, CodingKey {
        case model, embedding, n, validS = "valid_s", savedMs = "saved_ms", spread, consentBy = "consent_by", consentMs = "consent_ms"
    }
}

/// 途中まで集めた登録（取り直し中・登録の途中。14日で捨てる）
struct SpeakerEnrollPartial: Codable, Equatable {
    var model: String
    var sum: [Float]
    var embeddings: Int
    var validS: Double
    var startedMs: Int64
    var consentBy: String
    var consentMs: Int64
    var spreadSum = 0.0             // 足した埋め込みと、その時点の平均との似ている度合いのずれの合計（ばらつきの目安）

    enum CodingKeys: String, CodingKey {
        case model, sum, embeddings, validS = "valid_s", startedMs = "started_ms", consentBy = "consent_by", consentMs = "consent_ms", spreadSum = "spread_sum"
    }

    func expired(now: Int64) -> Bool { Double(now - startedMs) / 86_400_000 >= SpeakerCriteria.enrollMaxAgeDays }
}

enum SpeakerMath {
    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    /// コサイン類似度（どちらも長さ1なら内積）
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .nan }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return .nan }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// 声が出ているか（v1.10.2〜）：f0 がある、または声の大きさが voicedFloorDb 以上
    static func voiced(f0: Bool, rmsDb: Float?) -> Bool { f0 || (rmsDb.map { $0 >= SpeakerCriteria.voicedFloorDb } ?? false) }

    /// 登録に1つ足す（span 秒の声の埋め込み）
    static func add(_ p: inout SpeakerEnrollPartial, embedding e: [Float], spanS: Double) {
        let u = normalized(e)
        if p.embeddings > 0 { p.spreadSum += 1 - cosine(u, p.sum) }
        if p.sum.isEmpty { p.sum = u } else { for i in p.sum.indices where i < u.count { p.sum[i] += u[i] } }
        p.embeddings += 1
        p.validS += spanS
    }

    /// 登録に1つ足し、たまった秒数が 5秒の区切りを越えたら、足す前の登録（平均）と、この声との似ている度合いを返す（v1.10.1〜、記録の speaker_enroll_progress）
    static func addWithProgress(_ p: inout SpeakerEnrollPartial, embedding e: [Float], spanS: Double) -> Double? {
        let step = SpeakerCriteria.enrollProgressStepS
        let before = p.validS
        let score = p.sum.isEmpty ? nil : cosine(normalized(e), p.sum)
        add(&p, embedding: e, spanS: spanS)
        guard let s = score, s.isFinite, (p.validS + 1e-9) / step >= ((before + 1e-9) / step).rounded(.down) + 1 else { return nil }
        return (s * 1000).rounded() / 1000
    }

    /// 集め終えた登録
    static func finish(_ p: SpeakerEnrollPartial, now: Int64) -> SpeakerEnrollment {
        SpeakerEnrollment(model: p.model, embedding: normalized(p.sum), n: p.embeddings, validS: (p.validS * 10).rounded() / 10,
                          savedMs: now, spread: p.embeddings > 1 ? (p.spreadSum / Double(p.embeddings - 1) * 1000).rounded() / 1000 : nil,
                          consentBy: p.consentBy, consentMs: p.consentMs)
    }

    /// モデルの「使うフレームの重み」：3秒の窓の終わりから spanS 秒のフレームに 1
    static func mask(spanS: Double) -> [Float] {
        let n = SpeakerCriteria.maskFrames
        let k = max(1, min(n, Int((spanS / SpeakerCriteria.maxSpanS * Double(n)).rounded(.up))))
        return [Float](repeating: 0, count: n - k) + [Float](repeating: 1, count: k)
    }
}

/// kaldi の fbank（torchaudio.compliance.kaldi.fbank と同じ：80、25ms・10ms、hamming、DC を引く、プリエンファシス 0.97、512 の FFT のパワー、
/// 20Hz〜8kHz のメル、log（下限は Float の epsilon））を求め、フレームの平均を引く（pyannote と同じ）。v1.10.2〜、モデルの外で Float32 で求める
final class SpeakerFbank {
    static let frameLen = 400, shift = 160, nfft = 512, bins = 80
    private let window: [Float]
    private let mel: [Float]          // (257, 80)
    private let fft: FFTSetup
    private var frame = [Float](repeating: 0, count: SpeakerFbank.nfft)
    private var re = [Float](repeating: 0, count: SpeakerFbank.nfft / 2)
    private var im = [Float](repeating: 0, count: SpeakerFbank.nfft / 2)
    private var power = [Float](repeating: 0, count: SpeakerFbank.nfft / 2 + 1)

    init() {
        let n = Self.frameLen
        window = (0..<n).map { Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
        let melOf = { (f: Double) in 1127 * log(1 + f / 700) }
        let lo = melOf(20), hi = melOf(Double(SpeakerCriteria.sampleRate) / 2)
        let delta = (hi - lo) / Double(Self.bins + 1), width = Double(SpeakerCriteria.sampleRate) / Double(Self.nfft)
        var m = [Float](repeating: 0, count: (Self.nfft / 2 + 1) * Self.bins)
        for b in 0..<Self.bins {
            let l = lo + Double(b) * delta, c = l + delta, r = c + delta
            for i in 0..<(Self.nfft / 2) {   // 最後（ナイキスト）の列は 0
                let x = melOf(width * Double(i))
                m[i * Self.bins + b] = Float(max(0, min((x - l) / (c - l), (r - x) / (r - c))))
            }
        }
        mel = m
        fft = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    static func frames(samples: Int) -> Int { samples < frameLen ? 0 : 1 + (samples - frameLen) / shift }

    /// x：16kHz の声（-1〜1）。返り値：(フレーム数 × 80) を行ごとに並べたもの
    func compute(_ x: [Float]) -> [Float] {
        let nf = Self.frames(samples: x.count), n = Self.frameLen, half = Self.nfft / 2
        var out = [Float](repeating: 0, count: nf * Self.bins)
        var spec = [Float](repeating: 0, count: nf * (half + 1))
        for f in 0..<nf {
            for j in 0..<n { frame[j] = x[f * Self.shift + j] * 32768 }
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(n))
            for j in 0..<n { frame[j] -= mean }
            for j in stride(from: n - 1, to: 0, by: -1) { frame[j] -= 0.97 * frame[j - 1] }
            frame[0] -= 0.97 * frame[0]
            for j in 0..<n { frame[j] *= window[j] }
            for j in n..<Self.nfft { frame[j] = 0 }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var z = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &z, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(fft, &z, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            // zrip は 2倍の値。0 番目の実部が直流、虚部がナイキスト
            power[0] = re[0] * re[0] / 4
            power[half] = im[0] * im[0] / 4
            for k in 1..<half { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
            for k in 0...half { spec[f * (half + 1) + k] = power[k] }
        }
        guard nf > 0 else { return out }
        vDSP_mmul(spec, 1, mel, 1, &out, 1, vDSP_Length(nf), vDSP_Length(Self.bins), vDSP_Length(half + 1))
        for i in out.indices { out[i] = log(max(out[i], Float.ulpOfOne)) }
        for b in 0..<Self.bins {
            var mean: Float = 0
            vDSP_meanv(out.withUnsafeBufferPointer { $0.baseAddress! + b }, vDSP_Stride(Self.bins), &mean, vDSP_Length(nf))
            for f in 0..<nf { out[f * Self.bins + b] -= mean }
        }
        return out
    }
}

/// 声の特徴の数値を求める（Core ML）。重いので、呼ぶ側が別のキューで呼ぶ
final class SpeakerEmbedder {
    private let model: MLModel
    private let fbankArray: MLMultiArray
    private let maskArray: MLMultiArray
    private let fbank = SpeakerFbank()
    let url: URL
    let computeUnits: MLComputeUnits

    static func bundledURL(_ bundle: Bundle = .main) -> URL? { bundle.url(forResource: SpeakerCriteria.resourceName, withExtension: "mlmodelc") }

    /// モデルが無いときは nil
    init?(bundle: Bundle = .main, url: URL? = nil, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) {
        guard let u = url ?? Self.bundledURL(bundle) else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        guard let m = try? MLModel(contentsOf: u, configuration: cfg),
              let f = try? MLMultiArray(shape: [1, NSNumber(value: SpeakerCriteria.fbankFrames), NSNumber(value: SpeakerFbank.bins)], dataType: .float32),
              let k = try? MLMultiArray(shape: [1, NSNumber(value: SpeakerCriteria.maskFrames)], dataType: .float32)
        else { return nil }
        model = m; fbankArray = f; maskArray = k; self.url = u; self.computeUnits = computeUnits
    }

    /// window：直近 3秒の 16kHz の声（足りなければ前を 0 で埋めたもの、windowSamples 個）。spanS：そのうち使う直近の秒数。
    /// 返り値：長さ1の埋め込み（256）
    func embed(window: [Float], spanS: Double) -> [Float]? {
        guard window.count == SpeakerCriteria.windowSamples else { return nil }
        let fb = fbank.compute(window)
        guard fb.count == SpeakerCriteria.fbankFrames * SpeakerFbank.bins else { return nil }
        let m = SpeakerMath.mask(spanS: spanS)
        fb.withUnsafeBufferPointer { fbankArray.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count) }
        m.withUnsafeBufferPointer { maskArray.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["fbank": fbankArray, "weights": maskArray]),
              let out = try? model.prediction(from: input),
              let e = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        let dim = e.shape.last?.intValue ?? 256
        var v = [Float](repeating: 0, count: dim)
        for i in 0..<dim { v[i] = e[i].floatValue }
        guard v.allSatisfy({ $0.isFinite }) else { return nil }
        return SpeakerMath.normalized(v)
    }

    /// 演算ごとに、どこで動かす予定か（Neural Engine / GPU / CPU の数。iOS 17.4・macOS 14.4〜。記録の event speaker_model）
    static func computePlan(url: URL, computeUnits: MLComputeUnits) async -> [String: Int]? {
        guard #available(iOS 17.4, macOS 14.4, *) else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        guard let plan = try? await MLComputePlan.load(contentsOf: url, configuration: cfg),
              case let .program(program) = plan.modelStructure, let main = program.functions["main"] else { return nil }
        var count: [String: Int] = [:]
        func walk(_ block: MLModelStructure.Program.Block) {
            for op in block.operations {
                if let u = plan.deviceUsage(for: op) {
                    let k: String
                    switch u.preferred { case .neuralEngine: k = "ne"; case .gpu: k = "gpu"; case .cpu: k = "cpu"; @unknown default: k = "other" }
                    count[k, default: 0] += 1
                }
                op.blocks.forEach(walk)
            }
        }
        walk(main.block)
        return count
    }
}

/// 16kHz の声の輪のバッファ（3秒、メモリだけ。v1.10.2〜）と、直近の声のまとまりの長さ・f0 が取れていた割合
struct SpeakerRing {
    private var buf = [Float](repeating: 0, count: SpeakerCriteria.windowSamples)
    private var pos = 0
    private var filled = 0
    private(set) var voicedStart: Double?    // 声のまとまりの始まり（秒、音の時計）
    private(set) var lastVoiced: Double?
    private var blocks: [(t: Double, f0: Bool)] = []   // 声が出ていた音の塊（直近 maxSpanS 秒より少し長く）と、f0 が取れていたか（v1.10.2〜、f0_ratio）

    mutating func append(_ x: UnsafePointer<Float>, count n: Int) {
        for i in 0..<n {
            buf[pos] = x[i]
            pos = (pos + 1) % buf.count
        }
        filled = min(buf.count, filled + n)
    }

    /// 音の塊ごとに、声が出ていたか（SpeakerMath.voiced）と、f0 が取れていたかを入れる
    mutating func mark(voiced: Bool, f0: Bool = false, at t: Double) {
        if voiced {
            blocks.append((t, f0))
            if let i = blocks.firstIndex(where: { $0.t > t - SpeakerCriteria.maxSpanS - 1 }), i > 0 { blocks.removeFirst(i) }
            if let l = lastVoiced, t - l <= SpeakerCriteria.voiceGapS { } else { voicedStart = t }
            lastVoiced = t
        } else if let l = lastVoiced, t - l > SpeakerCriteria.voiceGapS {
            voicedStart = nil; lastVoiced = nil
        }
    }

    /// 今使う声の長さ（直近の声のまとまり、最大 maxSpanS 秒）。声が出ていなければ nil
    func span(now t: Double) -> Double? {
        guard let s = voicedStart, let l = lastVoiced, t - l <= SpeakerCriteria.voiceGapS else { return nil }
        return min(SpeakerCriteria.maxSpanS, max(0, t - s), Double(filled) / Double(SpeakerCriteria.sampleRate))
    }

    /// 使った声の長さ spanS のうち、声が出ていた音の塊で f0 が取れていた割合（v1.10.2〜、記録の f0_ratio）
    func f0Ratio(spanS: Double, now t: Double) -> Double? {
        let b = blocks.filter { $0.t > t - spanS + 1e-6 && $0.t <= t + 1e-6 }
        return b.isEmpty ? nil : Double(b.filter(\.f0).count) / Double(b.count)
    }

    /// 古い順に並べた 3秒
    func window() -> [Float] { Array(buf[pos...] + buf[..<pos]) }
}
