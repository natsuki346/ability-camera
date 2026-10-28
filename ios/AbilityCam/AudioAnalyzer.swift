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

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement)   // 自動の音量補正やノイズ除去を切る
        try s.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sr = Float(format.sampleRate)
        pitch.reset()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.analyze(buf, sampleRate: sr)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock(); latest = Snapshot(); lock.unlock()
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
