import AVFoundation
import Accelerate
import CoreML
import QuartzCore

/// 音の設定（v1.10.2〜、記録の event audio_session）。打ち消し（エコーキャンセル）・自動の音量補正をしていないかを確かめるため
struct AudioSessionSummary: Encodable {
    let category: String
    let mode: String
    let voiceProcessing: Bool       // AVAudioEngine の inputNode の声の処理（エコーキャンセル・ノイズ除去）。オンにしていない
    let otherAudioPlaying: Bool     // 始めたときに、ほかのアプリの音が鳴っていたか
    let mixWithOthers: Bool         // ほかのアプリの音と混ぜて鳴らせる設定か
    let inputGainSettable: Bool
    enum CodingKeys: String, CodingKey {
        case category, mode, voiceProcessing = "voice_processing", otherAudioPlaying = "other_audio_playing", mixWithOthers = "mix_with_others", inputGainSettable = "input_gain_settable"
    }
}

/// マイクから音量と声の高さをその場で計算する。音声そのものは保存しない。
final class AudioAnalyzer {
    private(set) var sessionSummary = AudioSessionSummary(category: "", mode: "", voiceProcessing: false, otherAudioPlaying: false, mixWithOthers: false, inputGainSettable: false)
    struct Snapshot { var rmsDb: Float?; var f0Hz: Float?; var at: CFTimeInterval = 0 }   // at = 計算した時刻（CACurrentMediaTime）

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var latest = Snapshot()
    private var pitch = PitchTracker()   // 音のスレッドの上でだけ触る

    var current: Snapshot { lock.lock(); defer { lock.unlock() }; return latest }

    /// 映像のコマごと（約33ms）の声の大きさ（v1.9.1〜）。音の塊ごとに、その塊の始まりの時刻（epoch ms）と区切りごとの dB を渡す（音のスレッドから呼ぶ）。
    /// 口の開きとのタイミングを振り返りレポートで見るため（記録の type: "audio" の行）。音声そのものは保存しない
    var onBlocks: ((_ startMs: Int64, _ blockMs: Double, _ db: [Double]) -> Void)?
    /// 話者の区別（v1.10〜）。nil なら計算しない（設定「話者の区別を記録する」がオフ、またはモデルが無い）
    var speaker: SpeakerFeed?

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        let otherBefore = s.isOtherAudioPlaying
        try s.setCategory(.record, mode: .measurement)   // 自動の音量補正やノイズ除去を切る
        try s.setActive(true)
        sessionSummary = AudioSessionSummary(category: s.category.rawValue, mode: s.mode.rawValue, voiceProcessing: engine.inputNode.isVoiceProcessingEnabled,
                                             otherAudioPlaying: otherBefore, mixWithOthers: s.categoryOptions.contains(.mixWithOthers),
                                             inputGainSettable: s.isInputGainSettable)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sr = Float(format.sampleRate)
        pitch.reset()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, when in
            self?.analyze(buf, sampleRate: sr)
            self?.blocks(buf, sampleRate: sr, hostTime: when.hostTime)
            if let self, let sp = self.speaker {   // 声が出ているか：f0 がある、または声の大きさがしきい値以上（v1.10.2〜）
                let c = self.current
                sp.feed(buf, hostTime: when.hostTime, voiced: SpeakerMath.voiced(f0: c.f0Hz != nil, rmsDb: c.rmsDb), f0: c.f0Hz != nil)
            }
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock(); latest = Snapshot(); lock.unlock()
    }

    /// 塊を約 1/30 秒ずつに区切って、それぞれの RMS（dB、0.1 に丸める）を求める
    private func blocks(_ buf: AVAudioPCMBuffer, sampleRate sr: Float, hostTime: UInt64) {
        guard let cb = onBlocks, let x = buf.floatChannelData?[0], sr > 0 else { return }
        let total = Int(buf.frameLength), step = max(Int((sr / 30).rounded()), 1)
        guard total >= step else { return }
        var out: [Double] = []
        var i = 0
        while i + step <= total {
            var ms: Float = 0
            vDSP_measqv(x + i, 1, &ms, vDSP_Length(step))
            let db = ms > 0 ? 10 * log10(ms) : -100
            out.append((Double(db) * 10).rounded() / 10)
            i += step
        }
        // 塊の始まりの時刻：音の時計（hostTime）は CACurrentMediaTime と同じ時計なので、今との差から epoch にする
        let hostS = hostTime > 0 ? AVAudioTime.seconds(forHostTime: hostTime) : CACurrentMediaTime() - Double(total) / Double(sr)
        let startMs = Int64(((Date().timeIntervalSince1970 - (CACurrentMediaTime() - hostS)) * 1000).rounded())
        cb(startMs, (Double(step) / Double(sr) * 1000 * 100).rounded() / 100, out)
    }

    private func analyze(_ buf: AVAudioPCMBuffer, sampleRate sr: Float) {
        guard let x = buf.floatChannelData?[0] else { return }
        let n = min(Int(buf.frameLength), 4096)
        guard n >= 512 else { return }

        var meanSq: Float = 0
        vDSP_measqv(x, 1, &meanSq, vDSP_Length(n))
        let rms = sqrt(meanSq)
        let db = rms > 0 ? 20 * log10(rms) : -100
        let now = CACurrentMediaTime()
        // 声の高さ（v1.6.2〜、Pitch.swift）：音の下限は -60dBFS。雑音は声らしさ（自己相関の山の高さ）で除く
        let f0 = db < PitchCriteria.floorDb ? nil : pitch.estimate(x, n: n, sampleRate: sr, t: now).f0

        lock.lock()
        latest = Snapshot(rmsDb: (db * 10).rounded() / 10, f0Hz: f0.map { ($0 * 10).rounded() / 10 }, at: now)
        lock.unlock()
    }
}

/// 話者の区別の音の流れ（v1.10〜、docs/speaker-plan.md）。タップの中では計算しない：16kHz に変えて輪のバッファ（3秒、メモリだけ）に足すだけ。
/// 声が出ている間だけ（f0 がある、または声の大きさがしきい値以上。v1.10.2〜）、0.5秒ごとに、別の低い優先度のキューで直近の声のまとまり（最大3秒。1.5秒未満も）の埋め込みを求め、onEmbedding に渡す
/// 話者の区別の計算の、確かめる用の切り替え（v1.10.3〜。設定の「確かめる用の設定」、または起動引数 -speakerQoS userInitiated / -speakerComputeUnits all など。
/// 起動引数は UserDefaults に入るので、どちらでも同じ）。記録のヘッダ speaker_qos・speaker_compute_units
enum SpeakerSettings {
    static let qosKey = "speakerQoS", unitsKey = "speakerComputeUnits"
    static let qosChoices = ["utility", "userInitiated"]
    static let unitsChoices = ["cpuAndNeuralEngine", "all", "cpuOnly", "cpuAndGPU"]

    static var qosName: String { UserDefaults.standard.string(forKey: qosKey).flatMap { qosChoices.contains($0) ? $0 : nil } ?? "utility" }
    static var unitsName: String { UserDefaults.standard.string(forKey: unitsKey).flatMap { unitsChoices.contains($0) ? $0 : nil } ?? "cpuAndNeuralEngine" }
    static var qos: DispatchQoS { qosName == "userInitiated" ? .userInitiated : .utility }
    static func units(_ name: String) -> MLComputeUnits {
        switch name { case "all": return .all; case "cpuOnly": return .cpuOnly; case "cpuAndGPU": return .cpuAndGPU; default: return .cpuAndNeuralEngine }
    }
}

/// 話者の区別のモデルを、アプリの中で1回だけ読み込む（v1.10.3〜。v1.10.2 は記録ごとに読み込み直していて、iPhone で約5秒かかっていた）。
/// computeUnits を切り替えたときだけ読み込み直す
final class SpeakerModelStore {
    static let shared = SpeakerModelStore()
    struct Loaded { let units: String; let embedder: SpeakerEmbedder; let loadMs: Double; let plan: [String: Int]? }
    private let queue = DispatchQueue(label: "speaker-load", qos: .utility)
    private var loaded: Loaded?          // queue の上でだけ触る

    /// アプリを開いたとき・設定をオンにしたとき（待たない）
    func preload() {
        guard SpeakerEmbedder.bundledURL() != nil else { return }
        let u = SpeakerSettings.unitsName
        queue.async { _ = self.load(u) }
    }

    /// 読み込んだもの（cached：前に読み込んだものを使った）。まだなら、ここで読み込む（呼んだキューで待つ）
    func get(_ units: String) -> (loaded: Loaded, cached: Bool)? {
        queue.sync {
            let cached = loaded?.units == units
            return load(units).map { ($0, cached) }
        }
    }

    private func load(_ units: String) -> Loaded? {
        if let l = loaded, l.units == units { return l }
        guard let url = SpeakerEmbedder.bundledURL() else { return nil }
        let cu = SpeakerSettings.units(units)
        let t0 = CACurrentMediaTime()
        guard let e = SpeakerEmbedder(url: url, computeUnits: cu) else { return nil }
        let ms = (CACurrentMediaTime() - t0) * 1000
        // どこで動かす予定か（iOS 17.4〜）。async なので、この読み込みのキューで待つ
        var plan: [String: Int]?
        let sem = DispatchSemaphore(value: 0)
        Task.detached { plan = await SpeakerEmbedder.computePlan(url: url, computeUnits: cu); sem.signal() }
        sem.wait()
        let l = Loaded(units: units, embedder: e, loadMs: ms, plan: plan)
        loaded = l
        return l
    }
}

/// 1回の計算の内訳（v1.10.3〜、記録の speaker 行の calc_ms・fbank_ms・predict_ms・wait_ms）
struct SpeakerTiming {
    let calcMs: Double      // fbank とモデル（embed の中）
    let fbankMs: Double
    let predictMs: Double
    let waitMs: Double      // 声のまとまりが決まってから、計算を始めるまで（キューの待ち）
}

final class SpeakerFeed {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var ring = SpeakerRing()            // lock の中でだけ触る
    private var converter: AVAudioConverter?
    private var outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeakerCriteria.sampleRate), channels: 1, interleaved: false)!
    private var busy = false
    private var lastRun = -Double.infinity
    private var embedder: SpeakerEmbedder?
    private let ready: Bool

    /// 埋め込みを求めた（音のスレッドではなく speaker のキュー）。endMs：使った声のまとまりの終わりの時刻（epoch ms）。
    /// calcMs は fbank とモデルの計算の合計。f0Ratio：そのまとまりで f0 が取れていた割合
    var onEmbedding: ((_ endMs: Int64, _ spanS: Double, _ timing: SpeakerTiming, _ f0Ratio: Double?, _ embedding: [Float]) -> Void)?
    /// モデルを用意した：どこで動かす予定か（Neural Engine / GPU / CPU の演算の数）・computeUnits・読み込みにかかった時間・前に読み込んだものか（v1.10.2〜、記録の event speaker_model）
    var onModel: ((_ plan: [String: Int]?, _ computeUnits: String, _ loadMs: Double?, _ cached: Bool) -> Void)?
    let qosName: String
    let unitsName: String

    /// モデルが無ければ nil。キューの優先度と computeUnits は SpeakerSettings（記録を始めたときのもの）
    init?() {
        guard SpeakerEmbedder.bundledURL() != nil else { return nil }
        ready = true
        qosName = SpeakerSettings.qosName; unitsName = SpeakerSettings.unitsName
        queue = DispatchQueue(label: "speaker", qos: SpeakerSettings.qos)
        let units = unitsName
        queue.async { [weak self] in   // 読み込み（済んでいれば使い回す）も別のキューで
            let r = SpeakerModelStore.shared.get(units)
            self?.embedder = r?.loaded.embedder
            self?.onModel?(r?.loaded.plan, r == nil ? "failed" : units, r?.loaded.loadMs, r?.cached ?? false)
        }
    }

    func feed(_ buf: AVAudioPCMBuffer, hostTime: UInt64, voiced: Bool, f0: Bool) {
        guard ready else { return }
        if converter == nil || converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: outFormat) }
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * outFormat.sampleRate / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let x = out.floatChannelData?[0] else { return }
        let hostS = hostTime > 0 ? AVAudioTime.seconds(forHostTime: hostTime) : CACurrentMediaTime()
        let endS = hostS + Double(buf.frameLength) / buf.format.sampleRate
        lock.lock()
        ring.append(x, count: Int(out.frameLength))
        ring.mark(voiced: voiced, f0: f0, at: endS)
        let span = ring.span(now: endS)
        var job: (window: [Float], span: Double, f0Ratio: Double?, at: CFTimeInterval)?
        if voiced, let s = span, s >= SpeakerCriteria.minSpanS, endS - lastRun >= SpeakerCriteria.hopS - 1e-6, !busy {
            busy = true; lastRun = endS
            job = (ring.window(), s, ring.f0Ratio(spanS: s, now: endS), CACurrentMediaTime())
        }
        lock.unlock()
        guard let job else { return }
        let endMs = Int64(((Date().timeIntervalSince1970 - (CACurrentMediaTime() - endS)) * 1000).rounded())
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            guard let emb = self.embedder else { return }
            let t0 = CACurrentMediaTime()
            guard let e = emb.embed(window: job.window, spanS: job.span) else { return }
            let timing = SpeakerTiming(calcMs: (CACurrentMediaTime() - t0) * 1000, fbankMs: e.fbankMs, predictMs: e.predictMs, waitMs: (t0 - job.at) * 1000)
            self.onEmbedding?(endMs, job.span, timing, job.f0Ratio, e.embedding)
        }
    }
}

