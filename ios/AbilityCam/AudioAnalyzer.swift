import AVFoundation
import Accelerate
import QuartzCore

/// マイクから音量と声の高さをその場で計算する。音声そのものは保存しない。
final class AudioAnalyzer {
    struct Snapshot { var rmsDb: Float?; var f0Hz: Float?; var at: CFTimeInterval = 0 }   // at = 計算した時刻（CACurrentMediaTime）

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var latest = Snapshot()
    private var pitch = PitchTracker()   // 音のスレッドの上でだけ触る

    var current: Snapshot { lock.lock(); defer { lock.unlock() }; return latest }

    /// 映像のコマごと（約33ms）の声の大きさ（v1.9.1〜）。音の塊ごとに、その塊の始まりの時刻（epoch ms）と区切りごとの dB を渡す（音のスレッドから呼ぶ）。
    /// 口の開きとのタイミングを振り返りレポートで見るため（記録の type: "audio" の行）。音声そのものは保存しない
    var onBlocks: ((_ startMs: Int64, _ blockMs: Double, _ db: [Double]) -> Void)?

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement)   // 自動の音量補正やノイズ除去を切る
        try s.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sr = Float(format.sampleRate)
        pitch.reset()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, when in
            self?.analyze(buf, sampleRate: sr)
            self?.blocks(buf, sampleRate: sr, hostTime: when.hostTime)
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
