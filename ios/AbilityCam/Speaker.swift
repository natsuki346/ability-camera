import CoreML
import Foundation

/// 話者の区別（v1.10〜、docs/speaker-plan.md の最初の段階）：だれの声かを分けて記録するためだけに使う。本人確認・認証には使わない。
/// 画面には出さず、記録（type: "speaker" の行）に、登録した人ごとの似ている度合いと、使った声の長さ・計算時間だけを書く。
/// 声の特徴の数値（埋め込み）は persons.json の中だけ。声そのものは保存しない（メモリの輪のバッファだけ）。
///
/// モデル：WeSpeaker ResNet34-LM（pyannote/wespeaker-voxceleb-resnet34-LM）を Fluid Inference が Core ML に変換したもの
/// （FluidInference/speaker-diarization-coreml の wespeaker.mlmodelc、CC BY 4.0。README の「ライセンス」）。
/// 入力は 16kHz の 10秒の声（3行）と、使うフレームの印（3行×589）。ここでは1行目だけを使い、直近の声のまとまり（最大3秒）に印を付ける
enum SpeakerCriteria {
    static let model = "wespeaker-r34lm-fluid-coreml-v1"   // 記録のヘッダ・行に書く版。モデルを替えたら変える（前の登録は使わない）
    static let resourceName = "wespeaker"
    static let sampleRate = 16_000
    static let windowSamples = 160_000                      // モデルの入力（10秒、固定）
    static let maskFrames = 589                             // 10秒のフレーム数（固定）
    static let rows = 3
    static let maxSpanS = 3.0                               // 埋め込みに使う直近の声の長さの上限
    static let minSpanS = 0.2                               // これより短い声は計算しない（1.5秒未満も計算して、長さを記録に書く）
    static let hopS = 0.5                                   // 声が出ている間、この間隔で1回
    static let voiceGapS = 0.3                              // これより長く声が途切れたら、声のまとまりを切る
    static let enrollTargetS = 30.0                         // 登録：声が合計これだけたまったら作る（仮の値）
    static let enrollMaxAgeDays = 14.0                      // 途中まで集めた登録は、集め始めてから14日で捨てる（声の普段と同じ）
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

    /// 登録に1つ足す（span 秒の声の埋め込み）
    static func add(_ p: inout SpeakerEnrollPartial, embedding e: [Float], spanS: Double) {
        let u = normalized(e)
        if p.embeddings > 0 { p.spreadSum += 1 - cosine(u, p.sum) }
        if p.sum.isEmpty { p.sum = u } else { for i in p.sum.indices where i < u.count { p.sum[i] += u[i] } }
        p.embeddings += 1
        p.validS += spanS
    }

    /// 集め終えた登録
    static func finish(_ p: SpeakerEnrollPartial, now: Int64) -> SpeakerEnrollment {
        SpeakerEnrollment(model: p.model, embedding: normalized(p.sum), n: p.embeddings, validS: (p.validS * 10).rounded() / 10,
                          savedMs: now, spread: p.embeddings > 1 ? (p.spreadSum / Double(p.embeddings - 1) * 1000).rounded() / 1000 : nil,
                          consentBy: p.consentBy, consentMs: p.consentMs)
    }

    /// モデルの「使うフレームの印」：10秒の窓の終わりから spanS 秒のフレームに 1
    static func mask(spanS: Double) -> [Float] {
        let n = SpeakerCriteria.maskFrames
        let k = max(1, min(n, Int((spanS / 10 * Double(n)).rounded(.up))))
        return [Float](repeating: 0, count: n - k) + [Float](repeating: 1, count: k)
    }
}

/// 声の特徴の数値を求める（Core ML）。重いので、呼ぶ側が別のキューで呼ぶ
final class SpeakerEmbedder {
    private let model: MLModel
    private let waveform: MLMultiArray
    private let maskArray: MLMultiArray

    /// モデルが無い（setup.sh で取っていない）ときは nil
    init?(bundle: Bundle = .main, url: URL? = nil, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) {
        guard let u = url ?? bundle.url(forResource: SpeakerCriteria.resourceName, withExtension: "mlmodelc") else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        guard let m = try? MLModel(contentsOf: u, configuration: cfg),
              let w = try? MLMultiArray(shape: [NSNumber(value: SpeakerCriteria.rows), NSNumber(value: SpeakerCriteria.windowSamples)], dataType: .float32),
              let k = try? MLMultiArray(shape: [NSNumber(value: SpeakerCriteria.rows), NSNumber(value: SpeakerCriteria.maskFrames)], dataType: .float32)
        else { return nil }
        model = m; waveform = w; maskArray = k
    }

    /// window：直近 10秒の 16kHz の声（足りなければ前を 0 で埋めたもの、windowSamples 個）。spanS：そのうち使う直近の秒数。
    /// 返り値：長さ1の埋め込み（256）
    func embed(window: [Float], spanS: Double) -> [Float]? {
        guard window.count == SpeakerCriteria.windowSamples else { return nil }
        let w = waveform.dataPointer.assumingMemoryBound(to: Float.self)
        let k = maskArray.dataPointer.assumingMemoryBound(to: Float.self)
        let m = SpeakerMath.mask(spanS: spanS)
        for r in 0..<SpeakerCriteria.rows {
            window.withUnsafeBufferPointer { src in
                (w + r * SpeakerCriteria.windowSamples).update(from: src.baseAddress!, count: SpeakerCriteria.windowSamples)
            }
            m.withUnsafeBufferPointer { src in (k + r * SpeakerCriteria.maskFrames).update(from: src.baseAddress!, count: SpeakerCriteria.maskFrames) }
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["waveform": waveform, "mask": maskArray]),
              let out = try? model.prediction(from: input),
              let e = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        let dim = e.shape.last?.intValue ?? 256
        let p = e.dataPointer.assumingMemoryBound(to: Float.self)
        let v = Array(UnsafeBufferPointer(start: p, count: dim))   // 1行目
        guard v.allSatisfy({ $0.isFinite }) else { return nil }
        return SpeakerMath.normalized(v)
    }
}

/// 16kHz の声の輪のバッファ（10秒、メモリだけ）と、直近の声のまとまりの長さ
struct SpeakerRing {
    private var buf = [Float](repeating: 0, count: SpeakerCriteria.windowSamples)
    private var pos = 0
    private var filled = 0
    private(set) var voicedStart: Double?    // 声のまとまりの始まり（秒、音の時計）
    private(set) var lastVoiced: Double?

    mutating func append(_ x: UnsafePointer<Float>, count n: Int) {
        for i in 0..<n {
            buf[pos] = x[i]
            pos = (pos + 1) % buf.count
        }
        filled = min(buf.count, filled + n)
    }

    /// 音の塊ごとに、声が出ていたか（f0 があったか）を入れる
    mutating func mark(voiced: Bool, at t: Double) {
        if voiced {
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

    /// 古い順に並べた 10秒
    func window() -> [Float] { Array(buf[pos...] + buf[..<pos]) }
}
