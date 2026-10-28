import Foundation

/// 「いつもとの違い」の決まり。振り返りレポート（analysis/criteria.json）と同じ値にしている。
/// 変えるときは criteria.json と README も一緒に変えること
enum DiffCriteria {
    static let smoothS = 0.3          // ならし（時間で重みを決める EMA）
    static let staleS = 1.0           // これより長く値が来なければ、ならした値を捨てる
    static let startZ = 2.0           // |z| ≥ 2 が
    static let startMinS = 0.5        //   0.5秒以上続いたら違い
    static let endZ = 1.5             // 同じ向きで |z| < 1.5 が
    static let endMinS = 0.5          //   0.5秒続いたら終わり
    static let blinkThreshold = 0.3   // 目を細める：eyeBlink 左右平均がこれ以上のコマと
    static let blinkPadS = 0.2        //   前後 0.2秒は使わない（普段にも数えない）
    static let faceWindowS = 1.0      // 表情：直近1秒で顔が映るコマが
    static let minFaceRatio = 0.5     //   半分以上で、
    static let maxAbsYaw = 35.0       //   |yaw| < 35° のときだけ比べる
    // 目を閉じている（v1.4〜、criteria.json の eyes_closed）：普段とは比べず、閉じているかどうかの事実だけ
    static let eyesClosedThreshold = 0.5   // eyeBlink 左右平均がこれ以上が
    static let eyesClosedMinS = 0.5        //   0.5秒以上続いたら「目を閉じている」（短いのはまばたき）
    static let eyesOpenEndS = 0.2          // これ未満が 0.2秒続いたら終わり。秒数は閉じ始めた時刻から
}

/// 違いの種類：指標（普段の z で比べる）か、目を閉じている（事実だけ、v1.4〜）
enum DiffTarget: Hashable {
    case metric(Metric)
    case eyesClosed

    static let eyesClosedKey = "eyes_closed"
    static let eyesClosedLabel = "目を閉じている"

    /// 画面・見る側・時間の流れに並べる順（表情4つ・目を閉じている・声2つ）
    static let all: [DiffTarget] = Metric.allCases.filter(\.isFace).map { .metric($0) } + [.eyesClosed]
        + Metric.allCases.filter { !$0.isFace }.map { .metric($0) }

    /// 画面に出す名前
    var label: String {
        switch self {
        case .metric(let m): m.label
        case .eyesClosed: Self.eyesClosedLabel
        }
    }

    /// 記録・見る側に書く名前（"brow_down" / "eyes_closed"）
    var key: String {
        switch self {
        case .metric(let m): m.rawValue
        case .eyesClosed: Self.eyesClosedKey
        }
    }
}

/// 1つの「違い」（いつもの範囲から外れていた間）
struct DiffSegment: Identifiable, Equatable {
    let id = UUID()
    let target: DiffTarget
    let above: Bool           // 目を閉じているは、いつも true
    let startT: Double        // 撮影時刻（epoch 秒）。|z| ≥ 2 になり始めた時刻
    var endT: Double
    var peakZ: Double
    var open = true           // まだ続いている

    init(metric: Metric, above: Bool, startT: Double, endT: Double, peakZ: Double) {
        target = .metric(metric); self.above = above; self.startT = startT; self.endT = endT; self.peakZ = peakZ
    }

    init(eyesClosedFrom startT: Double, to endT: Double) {
        target = .eyesClosed; above = true; self.startT = startT; self.endT = endT; peakZ = .nan
    }

    /// 指標の違いならその指標（目を閉じているは nil）
    var metric: Metric? { if case .metric(let m) = target { m } else { nil } }

    var seconds: Double { endT - startT }

    /// 画面に出す文（docs/wording-guide.md）。表情は「いつもより強い」、声は「大きい／小さい」「高い／低い」。
    /// 目を閉じているは、状態の名前を付けずに「目を閉じている」だけ（秒数は呼ぶ側が足す）
    var message: String {
        switch metric {
        case nil: DiffTarget.eyesClosedLabel
        case .rmsDb?: "声が、いつもより\(above ? "大きい" : "小さい")"
        case .f0Hz?: "声が、いつもより\(above ? "高い" : "低い")"
        case let m?: "\(m.label)動きが、いつもより\(above ? "強い" : "弱い")"
        }
    }

    /// 記録の change に書く形（"brow_down:above"、目を閉じているは "eyes_closed:closed"）
    var key: String { metric == nil ? "\(target.key):closed" : "\(target.key):\(above ? "above" : "below")" }

    /// 画面に出すか。表情の「いつもより弱い」は出さない（criteria.json の face_below_counts: false）
    var shown: Bool { above || !(metric?.isFace ?? true) }
}

/// 1コマ分の入力
struct DiffInput {
    var t: Double                     // 撮影時刻（epoch 秒）
    var face: Bool
    var yaw: Double?
    var faceValues: [Metric: Double]  // 顔があるときの表情の値（左右平均）
    var blink: Double?                // eyeBlink 左右平均
    var voice: [Metric: Double]       // 声の大きさ・高さ（このコマで新しく来た値）
}

/// 撮る側のその場の判定と、リプレイ（記録のファイルから計算し直す）で同じものを使う。
/// analysis/review.py の analyze() / detect() と同じ決まりを、1コマずつ流す形にしたもの。
/// 目を細めるのまばたきは前後 0.2秒を外すので、判定は 0.2秒遅れて進む（後ろのコマを待つ）
struct DiffEngine {
    struct Stat { let mean: Double; let sd: Double }   // sd は下限をかけたもの

    /// baseline 行の1指標から、判定に使う平均と標準偏差（下限をかけたもの）。データ不足なら nil（比べない）
    static func stat(for m: Metric, mean: Double?, std: Double?, insufficient: Bool) -> Stat? {
        guard !insufficient, let mean else { return nil }
        return Stat(mean: mean, sd: max(std ?? 0, m.stdFloor))
    }

    private enum Item {
        case frame(DiffInput, faceValid: Bool)
        case baseline([Metric: Stat]?)
    }

    private var queue: [Item] = []
    private var latestT = -Double.infinity
    private var blinkTimes: [Double] = []
    private var recentFace: [(t: Double, face: Bool)] = []
    private var lastYaw: (v: Double, t: Double)?
    private var baseline: [Metric: Stat]?
    private var smooth: [Metric: (v: Double, t: Double)] = [:]
    private var det: [Metric: Detector] = [:]
    private var closedDet = ClosedDetector()

    /// 今の z（判定できたコマのもの。判定できないときは入れない）
    private(set) var z: [Metric: Double] = [:]
    /// 今のならした値（判定したコマのもの。値が古いときは入れない）
    private(set) var value: [Metric: Double] = [:]
    /// 続いている違い（表情の「弱い」も含む。出すかは shown で決める）
    private(set) var active: [DiffTarget: DiffSegment] = [:]
    /// 終わった違い（呼ぶ側が取り出す）
    var finished: [DiffSegment] = []
    /// 最後に判定したコマの時刻
    private(set) var processedT = -Double.infinity
    /// 最後に判定したコマで、目を閉じているかを判定できたか（普段があり、顔が読めて |yaw| < 35°）
    private(set) var eyesJudgeable = false

    /// 普段を決めた・取り直した（nil）。この時刻より後のコマから使う
    mutating func setBaseline(_ b: [Metric: Stat]?) {
        queue.append(.baseline(b))
    }

    /// 1コマ足す。0.2秒より前のコマを判定する
    mutating func add(_ x: DiffInput) {
        // 顔が読めるか・横を向きすぎていないかは、そのコマまでで決める（review.py の face_valid）
        recentFace.append((x.t, x.face))
        while let f = recentFace.first, f.t <= x.t - DiffCriteria.faceWindowS { recentFace.removeFirst() }
        let ratio = Double(recentFace.filter(\.face).count) / Double(recentFace.count)
        if let y = x.yaw { lastYaw = (y, x.t) }
        let yawNow = lastYaw.flatMap { x.t - $0.t <= DiffCriteria.staleS ? $0.v : nil }
        let valid = ratio >= DiffCriteria.minFaceRatio && !(yawNow.map { abs($0) >= DiffCriteria.maxAbsYaw } ?? false)

        if (x.blink ?? 0) >= DiffCriteria.blinkThreshold { blinkTimes.append(x.t) }
        latestT = max(latestT, x.t)
        queue.append(.frame(x, faceValid: valid))
        drain(until: latestT - DiffCriteria.blinkPadS)
    }

    /// 残りを全部判定する（記録の終わり）
    mutating func flush() {
        drain(until: .infinity)
        for (k, s) in active {
            var s = s
            s.open = false
            finished.append(s)
            active[k] = nil
        }
    }

    private mutating func drain(until limit: Double) {
        while let first = queue.first {
            switch first {
            case .baseline(let b):
                baseline = b
                queue.removeFirst()
            case .frame(let x, let valid):
                guard x.t <= limit else { return }
                queue.removeFirst()
                process(x, faceValid: valid)
            }
        }
    }

    private func blinked(at t: Double) -> Bool {
        blinkTimes.contains { abs($0 - t) <= DiffCriteria.blinkPadS + 1e-9 }
    }

    private mutating func process(_ x: DiffInput, faceValid: Bool) {
        processedT = x.t
        blinkTimes.removeAll { $0 < x.t - DiffCriteria.blinkPadS - 1 }
        let blink = blinked(at: x.t)
        for m in Metric.allCases {
            // 生の値（目を細めるは、まばたきのコマを入れない）
            var raw: Double? = m.isFace ? (x.face ? x.faceValues[m] : nil) : x.voice[m]
            if m == .eyeSquint && blink { raw = nil }
            // ならす（review.py の smooth：1秒より空いたら今の値から）
            if let r = raw {
                if let s = smooth[m], x.t - s.t <= DiffCriteria.staleS {
                    let a = 1 - exp(-max(x.t - s.t, 0) / DiffCriteria.smoothS)
                    smooth[m] = (s.v + a * (r - s.v), x.t)
                } else {
                    smooth[m] = (r, x.t)
                }
            }
            var zz: Double?
            value[m] = smooth[m].flatMap { x.t - $0.t <= DiffCriteria.staleS ? $0.v : nil }
            if let s = smooth[m], x.t - s.t <= DiffCriteria.staleS, let b = baseline?[m] {
                zz = (s.v - b.mean) / b.sd
            }
            if m.isFace && !faceValid { zz = nil }
            if m == .eyeSquint && blink { zz = nil }
            z[m] = zz

            var d = det[m] ?? Detector()
            let (started, ended) = d.step(t: x.t, z: zz)
            det[m] = d
            let k = DiffTarget.metric(m)
            if let e = ended {
                var seg = active[k] ?? DiffSegment(metric: m, above: e.sign > 0, startT: e.start, endT: e.end, peakZ: e.peak)
                seg.endT = e.end; seg.peakZ = e.peak; seg.open = false
                finished.append(seg)
                active[k] = nil
            }
            if let s = started {
                active[k] = DiffSegment(metric: m, above: s.sign > 0, startT: s.start, endT: s.end, peakZ: s.peak)
            } else if let cur = d.seg, var seg = active[k] {
                seg.endT = cur.end; seg.peakZ = cur.peak
                active[k] = seg
            }
        }

        // 目を閉じている：普段とは比べないが、ほかの違いと同じく普段がある間だけ、顔が読めて |yaw| < 35° のコマで判定する
        let judgeable = baseline != nil && faceValid
        eyesJudgeable = judgeable
        let (cStarted, cEnded) = closedDet.step(t: x.t, judgeable: judgeable,
                                               closed: x.face ? x.blink.map { $0 >= DiffCriteria.eyesClosedThreshold } : nil)
        if let e = cEnded {
            var seg = active[.eyesClosed] ?? DiffSegment(eyesClosedFrom: e.start, to: e.end)
            seg.endT = e.end; seg.open = false
            finished.append(seg)
            active[.eyesClosed] = nil
        }
        if let s = cStarted {
            active[.eyesClosed] = DiffSegment(eyesClosedFrom: s.start, to: s.end)
        } else if let cur = closedDet.seg, var seg = active[.eyesClosed] {
            seg.endT = cur.end
            active[.eyesClosed] = seg
        }
    }

    /// 目を閉じている（review.py の detect_eyes_closed を1コマずつにしたもの）。
    /// 閉じている（eyeBlink 左右平均 ≥ 0.5）が 0.5秒以上続いたら始まり（閉じ始めた時刻から）、閉じていないが 0.2秒続いたら、その最初のコマで終わり。
    /// 判定できないコマ（普段が無い・顔が読めない・横を向きすぎ）が来たら、前のコマで打ち切る。顔の無いコマ（closed が nil）は何も変えない
    struct ClosedDetector {
        struct Seg { var start: Double; var end: Double }
        private var run0: Double?
        private(set) var seg: Seg?
        private var open0: Double?
        private var lastT = -Double.infinity

        mutating func step(t: Double, judgeable: Bool, closed: Bool?) -> (Seg?, Seg?) {
            let prevT = lastT
            lastT = t
            guard judgeable else {
                run0 = nil; open0 = nil
                guard var s = seg else { return (nil, nil) }
                s.end = max(prevT, s.start)
                seg = nil
                return (nil, s)
            }
            guard let closed else { return (nil, nil) }
            if var s = seg {
                if closed {
                    open0 = nil
                    s.end = t
                    seg = s
                    return (nil, nil)
                }
                if open0 == nil { open0 = t }
                if let o = open0, t - o >= DiffCriteria.eyesOpenEndS - 1e-9 {
                    s.end = o
                    seg = nil; open0 = nil
                    return (nil, s)
                }
                return (nil, nil)
            }
            guard closed else { run0 = nil; return (nil, nil) }
            if run0 == nil { run0 = t }
            if let r = run0, t - r >= DiffCriteria.eyesClosedMinS - 1e-9 {
                let new = Seg(start: r, end: t)
                seg = new; run0 = nil; open0 = nil
                return (new, nil)
            }
            return (nil, nil)
        }
    }

    /// review.py の detect() を1コマずつにしたもの
    struct Detector {
        struct Seg { var sign: Int; var start: Double; var end: Double; var peak: Double }
        private var run0: Double?
        private var runSign = 0
        private var runPeak = 0.0
        private(set) var seg: Seg?
        private var calm0: Double?
        private var lastT = -Double.infinity   // 前のコマの時刻

        /// 返り値：(このコマで始まった違い, このコマで終わった違い)
        mutating func step(t: Double, z: Double?) -> (Seg?, Seg?) {
            let prevT = lastT
            lastT = t
            guard var s = seg else {
                guard let z, abs(z) >= DiffCriteria.startZ else { run0 = nil; return (nil, nil) }
                let sign = z > 0 ? 1 : -1
                if run0 != nil && sign != runSign { run0 = nil }
                if run0 == nil { run0 = t; runSign = sign; runPeak = z }
                if abs(z) > abs(runPeak) { runPeak = z }
                if let r = run0, t - r >= DiffCriteria.startMinS {
                    let new = Seg(sign: sign, start: r, end: t, peak: runPeak)
                    seg = new; run0 = nil; calm0 = nil
                    return (new, nil)
                }
                return (nil, nil)
            }
            guard let z else {   // 判定できないコマ：前のコマで打ち切る
                s.end = max(prevT, s.start)
                seg = nil
                return (nil, s)
            }
            if z * Double(s.sign) < DiffCriteria.endZ {
                if calm0 == nil { calm0 = t }
                if let c = calm0, t - c >= DiffCriteria.endMinS {
                    s.end = c
                    seg = nil
                    return (nil, s)
                }
            } else {
                calm0 = nil
                s.end = t
                if z * Double(s.sign) > s.peak * Double(s.sign) { s.peak = z }
            }
            seg = s
            return (nil, nil)
        }
    }
}
