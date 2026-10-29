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
    /// 声紋で本人の声か（v1.10.5〜、記録の self_by_speaker・「本人以外の声」）：選んでいる人の似ている度合いがこれ以上なら本人。仮の値。
    /// 記録 ability-cam-20261029-131619 の推定区間で、自分 0.7〜0.87・動画の人 -0.13〜0.27 だったため（この記録を見て決めた値。analysis/criteria.json の speaker.self_threshold）
    static let selfThreshold = 0.45
    /// 声紋で本人の声か・比べる決め方（v1.11〜、記録の self_by_speaker_rel・「本人以外の声」）：選んでいる人の似ている度合いが relMinScore 以上で、
    /// ほかに登録した人のいちばん高い似ている度合いより relMargin 以上高ければ本人。ほかに登録した人がいなければ selfThreshold（0.45）と同じ。
    /// どちらも仮の値：記録 ability-cam-20261029-163456 を見て決めた（1.5秒以上の行で本人と判定した割合が、自分 97%・動画の人 4%・裏声 91%・声を上げた話し声 100%。
    /// 0.45 だけでは裏声 55%）。登録していない人の声（テレビなど）は比べる相手がいないので、別に確かめる（analysis/criteria.json の speaker.rel_min_score・rel_margin）
    static let relMinScore = 0.3
    static let relMargin = 0.15
    /// これより短い声（ms）は、自分でも似ている度合いが下がる（0.4 前後）ので、「本人以外の声」には使わず、記録・レポートでは別に数える
    static let shortWindowMs = 1500
    /// 「本人以外の声」を声紋で決めるときに見る直近の長さ（ms）
    static let otherVoiceWindowMs: Int64 = 1000
    static let enrollTargetS = 15.0                         // 登録：声が合計これだけたまったら作る（v1.10.4〜 15秒、仮の値。speaker_enroll_progress の score が何秒で落ち着くかを見て決め直す。v1.10〜v1.10.3 は 30秒）
    static let enrollMaxAgeDays = 14.0                      // 途中まで集めた登録は、集め始めてから14日で捨てる（声の普段と同じ）
    static let enrollProgressStepS = 5.0                    // 登録の途中、たまった秒数がこれだけ増えるごとに、似ている度合いを記録に書く（v1.10.1〜、登録に必要な秒数を決めるため）
    static let selfGateWaitMs: Int64 = 3000                 // 本人を登録するとき、声のまとまりの終わりのコマがこれだけ待っても来なければ数えない（v1.10.1〜）
}

/// 「声：本人以外の声が入っています」を声紋で決める（v1.10.5〜。選んでいる人の声の登録があるとき）。
/// 直近1秒に、使った声が1.5秒以上の行で self_by_speaker_rel（v1.11〜。v1.10.5 は self_by_speaker）が false のものがあり、true が無ければ出す。1.5秒未満の行しか無いときは出さない
struct SpeakerOtherVoice {
    private var rows: [(t: Int64, windowMs: Int, selfBy: Bool?)] = []

    mutating func add(tMs: Int64, windowMs: Int, selfBySpeaker: Bool?) {
        rows.append((tMs, windowMs, selfBySpeaker))
        rows.removeAll { $0.t < tMs - 5000 }
    }

    mutating func clear() { rows = [] }

    func other(nowMs: Int64) -> Bool {
        let recent = rows.filter { nowMs - $0.t <= SpeakerCriteria.otherVoiceWindowMs && $0.t <= nowMs + 1000 && $0.windowMs >= SpeakerCriteria.shortWindowMs }
        return recent.contains { $0.selfBy == false } && !recent.contains { $0.selfBy == true }
    }
}

/// 声の登録で、何を集めるか（v1.10.1〜。記録の event speaker_enroll の collect）
enum SpeakerEnrollCollect: String {
    case voiceSelf = "voice_self"   // 選んでいる人（本人）：今の判定で本人の声とされた時間（voice_self が true）だけ
    case voiced                     // ほかの人：声が出ている時間すべて（v1.10 と同じ）
}

/// 本人を登録するとき（v1.10.1〜）：声のまとまりの埋め込みを、そのまとまりのコマの voice_self が分かるまで待ち、数えるかを決める。
/// v1.10.4〜の決まり（gate 3）：数える分（終わりから min(使った長さ, 0.5秒)）のコマだけを見る。声の高さの範囲（reason pitch）は見ない（登録はひとりで話すので、声の高さで絞らない）。
///   - no_mouth・no_face（・timing）の voice_self: false のコマがあれば数えない（notSelf）
///   - 顔が読めていて口が動いている声のコマ（voice_self true、または false で reason pitch）が1つ以上あれば数える（null が混じっていても）
///   - それが無く null があれば数えない（noF0）
/// v1.10.3（gate 2）は pitch の false だけで true が無いと数えなかった。v1.10.1〜v1.10.2（gate 1）は、まとまり全体に false が1つでもあれば数えなかった。
/// 判定（だれの声か・本人の声か）は voice_self のまま変えない（声紋の似ている度合いとどちらが良いかは、台本の記録で比べてから決める）
struct SpeakerSelfGate<Item> {
    /// 決まったときの結果（数えなかった理由も。記録の speaker_enroll_progress の not_self_s・no_f0_s・no_frames_s）
    enum Outcome: Equatable {
        case counted     // 数えた
        case notSelf     // no_mouth・no_face（・timing）の voice_self: false のコマがあった
        case noF0        // 口が動いている声のコマが無く、voice_self: null（f0 が取れていない）のコマがあった
        case noFrames    // 数える分のコマが無い・待っても来なかった
    }

    private var frames: [(t: Int64, v: Bool?, reason: String?)] = []   // 時刻の順（映像のコマ）。reason は voice_self_reason
    private var pending: [(endMs: Int64, spanS: Double, item: Item)] = []

    mutating func frame(tMs: Int64, voiceSelf: Bool?, reason: String? = nil) {
        if let last = frames.last, tMs <= last.t { return }
        frames.append((tMs, voiceSelf, reason))
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
            out.append((p.item, lastT >= p.endMs ? Self.decide(frames.lazy.map { ($0.t, $0.v, $0.reason) }, endMs: p.endMs, spanS: p.spanS) : .noFrames))
        }
        return out
    }

    mutating func clear() { frames = []; pending = [] }

    /// 決まり（analysis/enroll_check.py も同じ決まり）
    static func decide<S: Sequence>(_ frames: S, endMs: Int64, spanS: Double) -> Outcome where S.Element == (Int64, Bool?, String?) {
        let counted = endMs - Int64((min(spanS, SpeakerCriteria.hopS) * 1000).rounded())
        var good = 0, null = false, any = false
        for (t, v, reason) in frames where t >= counted && t <= endMs {
            any = true
            switch v {
            case .some(true): good += 1
            case .some(false): if reason == "pitch" { good += 1 } else { return .notSelf }   // 声の高さの範囲は見ない
            case .none: null = true
            }
        }
        if good > 0 { return .counted }
        return null ? .noF0 : any ? .notSelf : .noFrames
    }
}

/// 声の登録の途中の数え（v1.10.3〜、記録の speaker_enroll_progress）。計算した声（数えた＋数えなかった）を理由ごとに足す
struct SpeakerEnrollTally: Equatable {
    var computedS = 0.0, notSelfS = 0.0, noF0S = 0.0, noFramesS = 0.0

    /// 足し、計算した声が 5秒の区切りを越えたら true（そのとき記録に1行書く）
    mutating func add<I>(_ o: SpeakerSelfGate<I>.Outcome, seconds s: Double) -> Bool {
        let step = SpeakerCriteria.enrollProgressStepS, before = computedS
        computedS += s
        switch o {
        case .counted: break
        case .notSelf: notSelfS += s
        case .noF0: noF0S += s
        case .noFrames: noFramesS += s
        }
        return ((computedS + 1e-9) / step).rounded(.down) > ((before + 1e-9) / step).rounded(.down)
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

    /// 声紋で本人の声か（v1.10.5〜）：選んでいる人の似ている度合いが selfThreshold 以上なら true、未満なら false、登録が無ければ nil
    static func selfBySpeaker(score: Double?) -> Bool? { score.map { $0 >= SpeakerCriteria.selfThreshold - 1e-9 } }

    /// 声紋で本人の声か・比べる決め方（v1.11〜）：選んでいる人の似ている度合いが relMinScore 以上で、ほかに登録した人のいちばん高い似ている度合いより
    /// relMargin 以上高ければ true、そうでなければ false。ほかに登録した人がいなければ selfBySpeaker と同じ。選んでいる人の登録が無ければ nil
    static func selfBySpeakerRel(score: Double?, others: [Double]) -> Bool? {
        guard let s = score else { return nil }
        guard let top = others.max() else { return selfBySpeaker(score: s) }
        return s >= SpeakerCriteria.relMinScore - 1e-9 && s - top >= SpeakerCriteria.relMargin - 1e-9
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
    private var tmp = [Float](repeating: 0, count: SpeakerFbank.frameLen)
    private var re = [Float](repeating: 0, count: SpeakerFbank.nfft / 2)
    private var im = [Float](repeating: 0, count: SpeakerFbank.nfft / 2)

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

    /// x：16kHz の声（-1〜1）。返り値：(フレーム数 × 80) を行ごとに並べたもの。
    /// v1.10.5〜：1つずつのループをやめ、vDSP（窓・プリエンファシス・FFT・パワー・メルの重みの行列の掛け算・log・平均を引く）で書いた。
    /// Swift はファイルごとに最適化を変えられず、Xcode の Debug（-Onone）で iPhone 146ms・Mac 55ms かかっていたため（Accelerate は Debug でも最適化済み）
    func compute(_ x: [Float]) -> [Float] {
        let nf = Self.frames(samples: x.count), n = Self.frameLen, half = Self.nfft / 2, bins = Self.bins
        guard nf > 0 else { return [] }
        var out = [Float](repeating: 0, count: nf * bins)
        var spec = [Float](repeating: 0, count: nf * (half + 1))
        var scale: Float = 32768, pre: Float = -0.97, quarter: Float = 0.25
        x.withUnsafeBufferPointer { xp in
        frame.withUnsafeMutableBufferPointer { fp in
        window.withUnsafeBufferPointer { wp in
        re.withUnsafeMutableBufferPointer { rp in
        im.withUnsafeMutableBufferPointer { ip in
        spec.withUnsafeMutableBufferPointer { sp in
        tmp.withUnsafeMutableBufferPointer { tp in
            let f0 = fp.baseAddress!, w = wp.baseAddress!, t = tp.baseAddress!
            var z = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_vclr(f0 + n, 1, vDSP_Length(Self.nfft - n))   // 400〜511 は 0 のまま
            for f in 0..<nf {
                // 32768 倍して、フレームの平均（DC）を引く（tmp に）
                vDSP_vsmul(xp.baseAddress! + f * Self.shift, 1, &scale, t, 1, vDSP_Length(n))
                var mean: Float = 0
                vDSP_meanv(t, 1, &mean, vDSP_Length(n))
                var neg = -mean
                vDSP_vsadd(t, 1, &neg, t, 1, vDSP_Length(n))
                // プリエンファシス：y[j] = x[j] − 0.97 x[j−1]（j ≥ 1）、y[0] = x[0] − 0.97 x[0]（tmp から frame へ）
                vDSP_vsma(t, 1, &pre, t + 1, 1, f0 + 1, 1, vDSP_Length(n - 1))
                f0[0] = t[0] - 0.97 * t[0]
                vDSP_vmul(f0, 1, w, 1, f0, 1, vDSP_Length(n))
                f0.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &z, 1, vDSP_Length(half)) }
                vDSP_fft_zrip(fft, &z, 1, 9, FFTDirection(FFT_FORWARD))
                // zrip は 2倍の値。0 番目の実部が直流、虚部がナイキスト
                let row = sp.baseAddress! + f * (half + 1)
                let nyq = z.imagp[0]
                z.imagp[0] = 0
                vDSP_zvmags(&z, 1, row, 1, vDSP_Length(half))          // re² + im²（直流は re² だけ）
                row[half] = nyq * nyq
                vDSP_vsmul(row, 1, &quarter, row, 1, vDSP_Length(half + 1))
            }
        }}}}}}}
        vDSP_mmul(spec, 1, mel, 1, &out, 1, vDSP_Length(nf), vDSP_Length(bins), vDSP_Length(half + 1))
        let total = out.count
        var eps = Float.ulpOfOne, count = Int32(total)
        out.withUnsafeMutableBufferPointer { op in
            let o = op.baseAddress!
            vDSP_vthr(o, 1, &eps, o, 1, vDSP_Length(total))   // 下限は Float の epsilon
            vvlogf(o, o, &count)
            for b in 0..<bins {   // メルごとに、フレームの平均を引く
                var mean: Float = 0
                vDSP_meanv(o + b, vDSP_Stride(bins), &mean, vDSP_Length(nf))
                var neg = -mean
                vDSP_vsadd(o + b, vDSP_Stride(bins), &neg, o + b, vDSP_Stride(bins), vDSP_Length(nf))
            }
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
    private let lock = NSLock()   // アプリの中で1つを使い回すので（v1.10.3〜）、前の記録のキューと重なっても入力の配列を壊さない
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
    /// 返り値：長さ1の埋め込み（256）と、fbank・モデルの計算にかかった時間（ms、v1.10.3〜）
    func embed(window: [Float], spanS: Double) -> (embedding: [Float], fbankMs: Double, predictMs: Double)? {
        guard window.count == SpeakerCriteria.windowSamples else { return nil }
        lock.lock(); defer { lock.unlock() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let fb = fbank.compute(window)
        let t1 = CFAbsoluteTimeGetCurrent()
        guard fb.count == SpeakerCriteria.fbankFrames * SpeakerFbank.bins else { return nil }
        let m = SpeakerMath.mask(spanS: spanS)
        fb.withUnsafeBufferPointer { fbankArray.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count) }
        m.withUnsafeBufferPointer { maskArray.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["fbank": fbankArray, "weights": maskArray]),
              let out = try? model.prediction(from: input),
              let e = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        let t2 = CFAbsoluteTimeGetCurrent()
        let dim = e.shape.last?.intValue ?? 256
        var v = [Float](repeating: 0, count: dim)
        if e.dataType == .float32 {
            let p = e.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<dim { v[i] = p[i] }
        } else {
            for i in 0..<dim { v[i] = e[i].floatValue }
        }
        guard v.allSatisfy({ $0.isFinite }) else { return nil }
        return (SpeakerMath.normalized(v), (t1 - t0) * 1000, (t2 - t1) * 1000)
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
