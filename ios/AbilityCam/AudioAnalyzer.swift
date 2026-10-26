import AVFoundation
import Accelerate
import QuartzCore

/// マイクから音量と声の高さをその場で計算する。音声そのものは保存しない。
final class AudioAnalyzer {
    struct Snapshot { var rmsDb: Float?; var f0Hz: Float?; var at: CFTimeInterval = 0 }   // at = 計算した時刻（CACurrentMediaTime）

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var latest = Snapshot()

    var current: Snapshot { lock.lock(); defer { lock.unlock() }; return latest }

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement)   // 自動の音量補正やノイズ除去を切る
        try s.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sr = Float(format.sampleRate)
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
        let f0 = rms < 0.01 ? nil : Self.pitch(x, n: n, sampleRate: sr)

        lock.lock()
        latest = Snapshot(rmsDb: (db * 10).rounded() / 10, f0Hz: f0.map { ($0 * 10).rounded() / 10 }, at: CACurrentMediaTime())
        lock.unlock()
    }

    /// 自己相関。70〜1000Hz で、声らしい周期性があるときだけ返す
    static func pitch(_ x: UnsafePointer<Float>, n: Int, sampleRate sr: Float) -> Float? {
        let maxLag = min(Int(sr / 70), n - 1)
        let minLag = Int(sr / 1000)
        guard maxLag > minLag else { return nil }
        var c = [Float](repeating: 0, count: maxLag + 1)
        for l in 0...maxLag {
            var s: Float = 0
            vDSP_dotpr(x, 1, x + l, 1, &s, vDSP_Length(n - l))
            c[l] = s
        }
        var d = 1
        while d < maxLag && c[d] > c[d + 1] { d += 1 }
        var best = -Float.infinity, bestLag = -1
        for l in max(d, minLag)...maxLag where c[l] > best { best = c[l]; bestLag = l }
        guard bestLag > 0, c[0] > 0, best / c[0] >= 0.5 else { return nil }
        return sr / Float(bestLag)
    }
}
