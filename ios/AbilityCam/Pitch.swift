import Accelerate
import Foundation

/// 声の高さ（f0）の決まり（v1.6.2〜、analysis/criteria.json の pitch と同じ値）
enum PitchCriteria {
    /// これより小さい音では f0 を計算しない（dBFS）。v1.6.1 までは -40（RMS 0.01）で、50cm 離れた普通の声（-45〜-60）がほとんど取れなかった。
    /// 雑音を f0 にしないのは clarityMin の役目（下限 -55 では、平均 -55dB の声の3〜4割を捨てていた。docs/validation-log.md 2026-10-28）
    static let floorDb: Float = -60
    /// 話し声の範囲（Hz）。v1.6.1 までは 70〜1000 で、800Hz のような倍音の取り違えが入っていた
    static let minHz: Float = 70
    static let maxHz: Float = 500
    /// 声らしさ：正規化した自己相関（NSDF）のピークがこれ以上のときだけ f0 にする（雑音を f0 にしない）
    static let clarityMin: Float = 0.6
    /// 一番高いピークのこの割合以上のピークのうち、周期の一番短いものを選ぶ（周期の2倍＝半分の高さに取り違えない）
    static let firstPeakRatio: Float = 0.9
    /// 直近 historyS 秒の f0 の中央値から 0.75 オクターブより離れたら、中央値に近いピーク（2倍・半分の取り違えの相手）を探し、
    /// それが一番高いピークの octaveAltRatio 以上ならそちらにする
    static let octaveJump: Float = 0.75
    static let octaveAltRatio: Float = 0.7
    static let historyS: Double = 1.0
    static let historyMin = 3
    /// 記録・ヘッダに書く、f0 の求め方の版（v1.6.2〜 2。無い記録は v1.6.1 までの求め方）
    static let version = 2
}

/// f0 を1つの音の塊（約 0.05〜0.1秒）ごとに求める。直近の f0 を覚えて、2倍・半分の取り違えを防ぐ
struct PitchTracker {
    struct Result { var f0: Float?; var clarity: Float }

    private var history: [(t: Double, f0: Float)] = []

    /// x：音（-1〜1）。t：秒（取り違えの判定に使う時刻）。音量の下限は呼ぶ側で見る
    mutating func estimate(_ x: UnsafePointer<Float>, n: Int, sampleRate sr: Float, t: Double) -> Result {
        history.removeAll { t - $0.t > PitchCriteria.historyS }
        let peaks = Self.keyMaxima(x, n: n, sampleRate: sr)
        guard let best = peaks.map(\.v).max(), best >= PitchCriteria.clarityMin else { return Result(f0: nil, clarity: peaks.map(\.v).max() ?? 0) }
        // 500Hz より高い山がこれに当たったら、話し声の範囲の外の高さ（その半分・3分の1の高さとしては出さない）
        var pick = peaks.first { $0.v >= PitchCriteria.firstPeakRatio * best }!
        if history.count >= PitchCriteria.historyMin {
            let ref = history.map(\.f0).sorted()[history.count / 2]
            let oct = { (lag: Float) in abs(log2(sr / lag / ref)) }
            if oct(pick.lag) > PitchCriteria.octaveJump,
               let alt = peaks.filter({ $0.v >= PitchCriteria.octaveAltRatio * best && oct($0.lag) <= 1 - PitchCriteria.octaveJump && Self.inRange($0.lag, sr) })
                   .min(by: { oct($0.lag) < oct($1.lag) }) {
                pick = alt
            }
        }
        guard Self.inRange(pick.lag, sr) else { return Result(f0: nil, clarity: best) }
        let f0 = sr / pick.lag
        history.append((t, f0))
        return Result(f0: f0, clarity: best)
    }

    mutating func reset() { history = [] }

    static func inRange(_ lag: Float, _ sr: Float) -> Bool {
        let f = sr / lag
        return f >= PitchCriteria.minHz && f <= PitchCriteria.maxHz
    }

    /// 正規化した自己相関（NSDF、McLeod の方法）の「鍵となる山」：0 を上に横切ってから下に横切るまでの一番高い点。
    /// 周期が 70Hz より短いものすべて（500Hz より高いものも、範囲の外の高さと分かるように返す）。lag は放物線で補った周期（サンプル数）
    static func keyMaxima(_ x0: UnsafePointer<Float>, n: Int, sampleRate sr: Float) -> [(lag: Float, v: Float)] {
        let minLag = Int((sr / PitchCriteria.maxHz).rounded(.down))
        let maxLag = Int((sr / PitchCriteria.minHz).rounded(.up))
        let w = n - maxLag - 1                       // どの周期でも同じ長さで比べる
        guard minLag >= 2, w >= maxLag else { return [] }
        // 直流を除く
        var mean: Float = 0
        vDSP_meanv(x0, 1, &mean, vDSP_Length(n))
        var x = [Float](repeating: 0, count: n)
        var neg = -mean
        vDSP_vsadd(x0, 1, &neg, &x, 1, vDSP_Length(n))
        // 2乗の累積和（m(τ) を早く出す）
        var cum = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { cum[i + 1] = cum[i] + x[i] * x[i] }
        let e0 = cum[w]
        var d = [Float](repeating: 0, count: maxLag + 2)
        x.withUnsafeBufferPointer { p in
            let b = p.baseAddress!
            for l in 0...(maxLag + 1) {
                var r: Float = 0
                vDSP_dotpr(b, 1, b + l, 1, &r, vDSP_Length(w))
                let m = e0 + (cum[l + w] - cum[l])
                d[l] = m > 0 ? 2 * r / m : 0
            }
        }
        // 鍵となる山
        var out: [(lag: Float, v: Float)] = []
        var l = 1
        while l <= maxLag, d[l] > 0 { l += 1 }       // 最初に 0 を下に横切るまで（周期 0 の山）は飛ばす
        while l <= maxLag {
            while l <= maxLag, d[l] <= 0 { l += 1 }
            guard l <= maxLag else { break }
            var top = l
            while l <= maxLag, d[l] > 0 { if d[l] > d[top] { top = l }; l += 1 }
            guard top >= 2, top <= maxLag else { continue }
            if l > maxLag, d[top] < d[min(top + 1, maxLag + 1)] { continue }   // 範囲の端で切れた山（まだ上っている）は使わない
            let a = d[top - 1], b = d[top], c = d[top + 1]
            let den = a - 2 * b + c
            let shift = den < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / den)) : 0
            let v = den < 0 ? b - 0.25 * (a - c) * shift : b
            out.append((Float(top) + shift, min(v, 1)))
        }
        return out
    }
}

/// 「数字」の「声の高さが取れた割合（直近10秒、声が出ていたときのうち）」（v1.6.2〜）。音の塊ごとに入れる。
/// 声が出ていた＝音が下限（-60dB）以上で、直近30秒の静かなときの音（下から1割）より 6dB 以上大きい塊
/// （部屋の音が下限より大きい部屋でも、部屋の音だけの塊を分母に入れないため）
struct PitchCoverage {
    static let windowS = 10.0, roomWindowS = 30.0, aboveRoomDb: Float = 6, roomQuantile = 0.1
    private var chunks: [(t: Double, db: Float, f0: Bool)] = []

    mutating func add(t: Double, db: Float, f0: Bool) {
        chunks.append((t, db, f0))
        while let c = chunks.first, t - c.t > Self.roomWindowS { chunks.removeFirst() }
    }

    mutating func reset() { chunks = [] }

    /// 直近30秒の静かなときの音（dB）
    var roomDb: Float? {
        guard chunks.count >= 10 else { return nil }
        let s = chunks.map(\.db).sorted()
        return s[Int(Double(s.count - 1) * Self.roomQuantile)]
    }

    /// 割合（0〜1）。声が出ていた塊が無ければ nil
    func ratio(now: Double) -> Double? {
        guard let room = roomDb else { return nil }
        let voiced = chunks.filter { now - $0.t <= Self.windowS && $0.db >= PitchCriteria.floorDb && $0.db >= room + Self.aboveRoomDb }
        guard !voiced.isEmpty else { return nil }
        return Double(voiced.filter(\.f0).count) / Double(voiced.count)
    }
}
