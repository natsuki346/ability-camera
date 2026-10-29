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
    // 本人の声（v1.6〜、criteria.json の voice_self）：声が出ていて（f0 がある）、顔が読めていて、口が動いているコマ
    static let mouthKeys = ["jawOpen", "mouthClose", "mouthFunnel", "mouthPucker"]
    static let mouthWindowS = 0.3          // 直近 0.3秒の
    static let mouthMinRange = 0.04        //   変化（最大 − 最小）が、どれかでこれ以上なら口が動いている（仮の値）
    // 口の動きと声のタイミング（v1.9〜、criteria.json の voice_self.sync）：直近 syncWindowS 秒の、口の開き（syncKey）と声の大きさ（rms_db）の相関が
    // syncMinCorr 以上なら本人の声らしい（数えるコマが syncMinFrames より少なければ言えない）。仮の値
    static let syncKey = "jawOpen"
    static let syncWindowS = 1.0
    static let syncMinFrames = 10
    static let syncMinCorr = 0.3
    /// v1.9.1〜：タイミングの決まりは判定に使わない（実際の記録で本人 45% / ほかの人 41% と見分けられず、本人の声の半分以上を捨てたため）。
    /// 相関は振り返りレポートで、映像のコマごとの声の大きさ（記録の type: "audio"）と ±0.2秒のずれを探して求める
    static let syncEnabled = false
    // 声の高さの範囲（v1.9.1〜、criteria.json の voice_self.pitch_range）：保存した声の普段があるとき、f0 が 中央値 ± pitchRangeK × ばらつき（下限 pitchSpreadFloorHz）の外なら
    // 本人の声と言わない。ばらつき＝四分位範囲 ÷ 1.349（外れ値に強い。平均・標準偏差は使わない。v1.9 は 平均 ± 3 × 標準偏差で、151 ± 61Hz と広すぎた）
    static let pitchRangeK = 2.5
    static let pitchSpreadFloorHz = 20.0
    /// 保存した声の普段の声の高さのばらつきがこれを超えたら「声の普段のばらつきが大きいです（取り直せます）」
    static let voiceSpreadWarnHz = 40.0

    /// 四分位（numpy の percentile の linear と同じ：並べた値の (n−1)×p 番目を、前後で比例して求める）
    static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let pos = Double(sorted.count - 1) * p
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    /// 声の高さの中央値と四分位範囲（0.1 に丸める）。値が無ければ nil
    static func robustPitch(_ values: [Double]) -> (median: Double, iqr: Double)? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let r = { (x: Double) in (x * 10).rounded() / 10 }
        return (r(quantile(s, 0.5)), r(quantile(s, 0.75) - quantile(s, 0.25)))
    }

    static func spread(iqr: Double) -> Double { iqr / 1.349 }
    // 声の普段（v1.6〜、criteria.json の voice_baseline）：本人の声のコマが合計これだけたまったら
    static let voiceBaselineS = 10.0
    // 途中まで集めた声の普段は人ごとに保存して、次のセッションで続きから足す（v1.7〜）。集め始めてからこの日数たったら捨てる
    static let voiceBaselineMaxAgeDays = 14.0
    // 声が出た（v1.7〜、criteria.json の voice_on）：普段とは比べず、本人の声のコマがあったという事実だけ。
    // 本人の声のコマを、間が gapS 未満ならひとまとまりにし、最初から最後までが minS 以上なら「声が出た」（最初のコマから最後のコマまで）
    static let voiceOnMinS = 0.3
    static let voiceOnGapS = 0.5
    // 重なりのできごと（v1.12〜、criteria.json の co_change。すべて仮の値で、記録を見て決め直す）：
    // まとまり（coGroups）のうち、z が同じ向きに coZ 以上（下なら −coZ 以下）のメンバーがあるものが coMinGroups 以上（表情を1つ以上含む）のコマが、
    // coMinOverlapS 秒以上続いたら1つのできごとを始める。そのあと、そういうコマが coWindowS 秒来なかったら終わり（終わりは最後にそうだったコマ）。
    // 声の大きさ・高さは1つのまとまり（声だけの重なりは数えない）。jaw_open（話す・ジストニアでも動く）・eye_squint（orbit と重なる）・cheek_raise（orbit と同じ cheekSquint）は入れない
    static let coZ = 2.0
    static let coMinGroups = 2
    static let coMinOverlapS = 0.5
    static let coWindowS = 5.0
    /// sign：その指標の z をこの向きで見る（v1.15〜の顔の点の距離は、眉を寄せる・目を細めると小さくなるので −1。criteria.json では "-brow_eye_gap"）
    /// v1.16〜：brow_eye_gap は外した（記録は続ける）。目のまとまり（eyes：orbit・eye_open・eye_squint）は coSecondary：
    /// ほかのまとまり（眉・口角・口・鼻と上唇・声）が入っているときだけ数える
    static let coGroups: [(name: String, metrics: [(m: Metric, sign: Double)])] = [
        ("brow", [(.browDown, 1), (.browInnerGap, -1)]), ("eyes", [(.orbit, 1), (.eyeOpen, -1), (.eyeSquint, 1)]),
        ("nose_lip", [(.noseLip, 1)]), ("mouth_tense", [(.mouthTense, 1)]),
        ("smile", [(.mouthSmile, 1), (.mouthCorner, 1)]), ("voice", [(.rmsDb, 1), (.f0Hz, 1)])]
    static let coSecondary: Set<String> = ["eyes"]
    /// 補助の指標（v1.17〜、criteria.json の co_change.support）：同じコマで相手の指標が入っているときだけ数える。
    /// brow_inner_gap は browDown が入っていないと眉のまとまりを光らせない（記録 234756 で、眉を寄せても z ±0.4 しか動かなかった。記録は続ける）
    static let coSupport: [Metric: Metric] = [.browInnerGap: .browDown]
    /// 続いている重なりで、入っている表情のまとまり（目と声を除く）が前と1つも重ならなくなったら別のできごとに分ける（v1.16〜。例：眉 → 口角）
    static let coSplitGroups: Set<String> = ["brow", "nose_lip", "mouth_tense", "smile"]
    /// 目の指標（eye_squint・orbit・eye_open）は、顔の向き（yaw）が普段の中央値からこれ以上ずれたコマでは比べない（v1.16〜、仮の値。criteria.json の eye_yaw_tolerance_deg）
    static let eyeYawToleranceDeg = 10.0
    // 目を閉じている割合（v1.12〜、criteria.json の eyes_closed_ratio。判定には使わない）：直近 windowS 秒の顔のあるコマのうち、
    // eyeBlink 左右平均 ≥ eyesClosedThreshold が eyesClosedMinS 秒以上続いたまとまりに入るコマの割合。stepS 秒ごとに記録に書く
    static let eyesRatioWindowS = 30.0
    static let eyesRatioStepS = 5.0
    /// 普段の間の値の幅（最大 − 最小）がこれ未満の表情の数値は「この顔では値がほとんど動いていません」（v1.15〜、データのタブに出すだけ。criteria.json の flat_range）
    static let flatRange = 0.01
}

/// 重なりのできごと（v1.12〜、記録の event kind: "co_change"。review.py の detect_co_change と同じ決まり）
struct CoChange: Equatable {
    var above: Bool
    var startT: Double
    var endT: Double
    var metrics: Set<Metric>
    var groups: Set<String>
    /// 始まったときの表情のまとまり（coSplitGroups のもの。v1.16〜：これと1つも重ならなくなったら別のできごと）
    var core: Set<String> = []

    var seconds: Double { endT - startT }
    /// 記録に書く並び（Metric.allCases の順）
    var metricKeys: [String] { Metric.allCases.filter { metrics.contains($0) }.map(\.rawValue) }
    var groupKeys: [String] { DiffCriteria.coGroups.map(\.name).filter { groups.contains($0) } }
}

struct CoChangeDetector {
    private struct Dir {
        var run0: Double?
        var runMetrics: Set<Metric> = []
        var runGroups: Set<String> = []
        var event: CoChange?
    }
    private var dirs: [Bool: Dir] = [true: Dir(), false: Dir()]
    /// 終わったできごと（呼ぶ側が取り出す）
    var finished: [CoChange] = []

    /// z：そのコマで判定できた指標の z（判定できない指標は入れない）
    mutating func step(t: Double, z: [Metric: Double]) {
        for above in [true, false] {
            var d = dirs[above]!
            let sign = above ? 1.0 : -1.0
            var lit: [String: [Metric]] = [:]
            for g in DiffCriteria.coGroups {
                var ms = g.metrics.filter { (z[$0.m] ?? 0) * $0.sign * sign >= DiffCriteria.coZ - 1e-9 }.map(\.m)
                ms = ms.filter { m in DiffCriteria.coSupport[m].map { ms.contains($0) } ?? true }   // 補助の指標は相手が入っているときだけ（v1.17〜）
                if !ms.isEmpty { lit[g.name] = ms }
            }
            // 目のまとまりは、ほかのまとまりが入っているときだけ数える（v1.16〜）
            if lit.keys.allSatisfy(DiffCriteria.coSecondary.contains) { lit = [:] }
            let litGroups = Set(lit.keys), litMetrics = Set(lit.values.flatMap { $0 })
            let face = litMetrics.contains(where: \.isFace)
            if litGroups.count >= DiffCriteria.coMinGroups && face {
                let prim = litGroups.intersection(DiffCriteria.coSplitGroups)
                if var e = d.event {
                    if !prim.isEmpty, !e.core.isEmpty, prim.isDisjoint(with: e.core) {
                        // 表情のまとまりが入れ替わった（例：眉 → 口角）：前のできごとはここまでにして、新しく数え始める（v1.16〜）
                        finished.append(e); d.event = nil
                        d.run0 = t; d.runMetrics = litMetrics; d.runGroups = litGroups
                    } else {
                        e.endT = t; e.metrics.formUnion(litMetrics); e.groups.formUnion(litGroups)
                        d.event = e
                    }
                } else {
                    if d.run0 == nil { d.run0 = t; d.runMetrics = []; d.runGroups = [] }
                    d.runMetrics.formUnion(litMetrics); d.runGroups.formUnion(litGroups)
                    if let r = d.run0, t - r >= DiffCriteria.coMinOverlapS - 1e-9 {
                        d.event = CoChange(above: above, startT: r, endT: t, metrics: d.runMetrics, groups: d.runGroups,
                                           core: d.runGroups.intersection(DiffCriteria.coSplitGroups))
                    }
                }
            } else {
                d.run0 = nil
                if let e = d.event, t - e.endT >= DiffCriteria.coWindowS - 1e-9 {
                    finished.append(e); d.event = nil
                }
            }
            dirs[above] = d
        }
    }

    /// 続いているもの（記録の終わり）
    mutating func flush() {
        for above in [true, false] {
            if let e = dirs[above]!.event { finished.append(e) }
            dirs[above]!.event = nil; dirs[above]!.run0 = nil
        }
        finished.sort { $0.startT < $1.startT }
    }
}

/// 目を閉じている割合（v1.12〜、記録の event kind: "eyes_closed_ratio"。判定には使わない）。
/// 顔のあるコマだけを見る。閉じている（eyeBlink 左右平均 ≥ 0.5）コマが続いたまとまり（顔の無いコマで切る）のうち、最初から最後までが 0.5秒以上のものに入るコマを数える
struct EyesClosedRatio {
    private var frames: [(t: Double, closed: Bool)] = []
    private var runIDs: [Int] = []        // frames と同じ並び。閉じているまとまりの番号（閉じていなければ -1）
    private var runSpan: [Int: (start: Double, end: Double)] = [:]
    private var nextRun = 0
    private var inRun = false
    private var lastEmit: Double?

    /// face：そのコマに顔があるか。blink：eyeBlink 左右平均。返り値：stepS 秒ごとに (割合, 顔のあるコマ, 閉じていたコマ)
    mutating func add(t: Double, face: Bool, blink: Double?) -> (ratio: Double, faceFrames: Int, closedFrames: Int)? {
        if face, let b = blink {
            let closed = b >= DiffCriteria.eyesClosedThreshold
            if closed {
                if !inRun { nextRun += 1; inRun = true; runSpan[nextRun] = (t, t) }
                runSpan[nextRun]!.end = t
            } else {
                inRun = false
            }
            frames.append((t, closed)); runIDs.append(closed ? nextRun : -1)
        } else {
            inRun = false
        }
        if let i = frames.firstIndex(where: { $0.t > t - DiffCriteria.eyesRatioWindowS }), i > 0 {
            frames.removeFirst(i); runIDs.removeFirst(i)
        } else if let f = frames.first, f.t <= t - DiffCriteria.eyesRatioWindowS {
            frames.removeAll(); runIDs.removeAll()
        }
        let keep = Set(runIDs.filter { $0 >= 0 })
        runSpan = runSpan.filter { keep.contains($0.key) || $0.key == nextRun }
        if lastEmit == nil { lastEmit = t }
        guard t - lastEmit! >= DiffCriteria.eyesRatioStepS - 1e-9 else { return nil }
        lastEmit = t
        let closedN = runIDs.filter { id in id >= 0 && (runSpan[id].map { $0.end - $0.start >= DiffCriteria.eyesClosedMinS - 1e-9 } ?? false) }.count
        return frames.isEmpty ? nil : (Double(closedN) / Double(frames.count), frames.count, closedN)
    }

    mutating func reset() { self = EyesClosedRatio() }
}

/// 本人の声か（review.py の voice_self と同じ決まり）。1コマずつ流す。
/// 返り値：nil＝声が出ていない（f0 が無い）、true＝本人の声、false＝本人の声と言えない（理由は reason）
/// v1.9〜：口の動きの大きさに加えて、口の開きと声の大きさのタイミングが合っているか（直近1秒の相関）と、
/// 保存した声の普段があるときは声の高さが普段の範囲に入っているかで決める。声紋（声の特徴で人を特定するもの）は作らない
struct VoiceSelfTracker {
    /// 本人の声と言えなかった理由（記録の voice_self_reason）。決まりを見る順
    enum Reason: String {
        case pitch          // 声の高さが、保存した声の普段の範囲の外
        case noFace = "no_face"     // 顔が読めていない・横を向きすぎ・そのコマに顔が無い
        case noMouth = "no_mouth"   // 口がほとんど動いていない
        case timing         // 口の開きと声の大きさのタイミングが合っていない（相関が低い・数えるコマが足りない）
    }
    /// 声が出ていたとき、どの顔の口と声のタイミングが合っていたか（記録の voice_match。将来、複数の人を分けるための下準備）
    enum Match: String { case selfFace = "self", other, none }

    private var recentFace: [(t: Double, face: Bool)] = []
    private var lastYaw: (v: Double, t: Double)?
    private var mouth: [(t: Double, v: [String: Double])] = []
    private var sync: [(t: Double, jaw: Double?, rms: Double?, other: Double?)] = []
    private var pitchRange: (center: Double, spread: Double, fromT: Double)?

    /// 顔が読めているか（DiffEngine の faceValid と同じ：直近1秒で顔が映るコマが半分以上、|yaw| < 35°）
    private(set) var faceValid = false
    /// 最後のコマの判定の中身（声が出ていなければ reason・corr は nil）
    private(set) var reason: Reason?
    private(set) var corr: Double?          // 本人として選んだ顔の口の開きと声の大きさの相関（直近1秒）
    private(set) var corrOther: Double?     // もう1つの顔の相関（2つ映っているとき）
    private(set) var match: Match?

    /// 保存した声の普段の声の高さ（中央値・四分位範囲）を、この時刻のコマから使う（nil で使わない。中央値の無い v1.9 までの声の普段は使わない）
    mutating func setPitchRange(median: Double?, iqr: Double?, fromT: Double) {
        pitchRange = median.map { ($0, DiffCriteria.spread(iqr: iqr ?? 0), fromT) }
    }

    /// 相関（ピアソン）。どちらかがほとんど動いていなければ nil
    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        let n = Double(xs.count)
        guard xs.count >= 2 else { return nil }
        var mx = 0.0, my = 0.0
        for i in xs.indices { mx += xs[i]; my += ys[i] }
        mx /= n; my /= n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in xs.indices {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        guard sxx > 1e-12, syy > 1e-12 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    private func correlation(other: Bool) -> Double? {
        var xs: [Double] = [], ys: [Double] = []
        for e in sync {
            guard let x = other ? e.other : e.jaw, let r = e.rms else { continue }
            xs.append(x); ys.append(r)
        }
        guard xs.count >= DiffCriteria.syncMinFrames else { return nil }
        return Self.pearson(xs, ys)
    }

    /// rms：そのコマの声の大きさ（記録に書いた 0.1 に丸めた値）。f0：声の高さ（無ければ声が出ていない）。otherJaw：もう1つの顔の jawOpen
    mutating func add(t: Double, face: Bool, yaw: Double?, bs: [String: Double], rms: Double?, f0: Double?, otherJaw: Double? = nil) -> Bool? {
        recentFace.append((t, face))
        while let f = recentFace.first, f.t <= t - DiffCriteria.faceWindowS { recentFace.removeFirst() }
        let ratio = Double(recentFace.filter(\.face).count) / Double(recentFace.count)
        if let y = yaw { lastYaw = (y, t) }
        let yawNow = lastYaw.flatMap { t - $0.t <= DiffCriteria.staleS ? $0.v : nil }
        faceValid = ratio >= DiffCriteria.minFaceRatio && !(yawNow.map { abs($0) >= DiffCriteria.maxAbsYaw } ?? false)

        if face {
            var v: [String: Double] = [:]
            for k in DiffCriteria.mouthKeys { if let x = bs[k] { v[k] = x } }
            mouth.append((t, v))
        }
        while let m = mouth.first, t - m.t > DiffCriteria.mouthWindowS + 1e-9 { mouth.removeFirst() }
        sync.append((t, face ? bs[DiffCriteria.syncKey] : nil, rms, otherJaw))
        while let e = sync.first, t - e.t > DiffCriteria.syncWindowS + 1e-9 { sync.removeFirst() }

        reason = nil; corr = nil; corrOther = nil; match = nil
        guard let f0 else { return nil }
        if DiffCriteria.syncEnabled {
            corr = correlation(other: false)
            corrOther = otherJaw == nil ? nil : correlation(other: true)
        }
        let okSelf = (corr ?? -.infinity) >= DiffCriteria.syncMinCorr - 1e-9
        let okOther = (corrOther ?? -.infinity) >= DiffCriteria.syncMinCorr - 1e-9
        if DiffCriteria.syncEnabled {
            match = okSelf && (corrOther == nil || corr! >= corrOther!) ? .selfFace : okOther ? .other : Match.none
        }

        if let p = pitchRange, t >= p.fromT - 1e-9,
           abs(f0 - p.center) > DiffCriteria.pitchRangeK * max(p.spread, DiffCriteria.pitchSpreadFloorHz) + 1e-9 {
            reason = .pitch; return false
        }
        guard face, faceValid, mouth.count >= 2 else { reason = .noFace; return false }
        var range = 0.0
        for k in DiffCriteria.mouthKeys {
            let xs = mouth.compactMap { $0.v[k] }
            if let lo = xs.min(), let hi = xs.max() { range = max(range, hi - lo) }
        }
        guard range >= DiffCriteria.mouthMinRange - 1e-9 else { reason = .noMouth; return false }
        guard okSelf || !DiffCriteria.syncEnabled else { reason = .timing; return false }
        return true
    }
}

/// 声の普段の進み具合が増えないときの理由（v1.6.2〜）。本人の声の決まり（VoiceSelfTracker）のどこで外れたかを、コマごとに数える。
/// 本人の声のコマが stallS 秒来ていないとき、直近 stallS 秒で一番多かった理由を出す
struct VoiceWaitTracker {
    enum Reason: String {
        case noPitch = "声の高さが取れていません"
        case noMouth = "口が動いていません"
        case noFace = "顔が読めていません"
        case timing = "口の動きと声のタイミングが合っていません"   // v1.9〜
        case pitch = "声の高さが本人の普段の範囲の外です"           // v1.9〜（保存した声の普段があるとき）
    }
    static let stallS = 3.0
    private var recent: [(t: Double, r: Reason)] = []
    private var lastSelfT: Double?
    private var firstT: Double?

    /// voiceSelf：VoiceSelfTracker の返り値（nil：f0 が無い）。faceValid：顔が読めているか（そのコマに顔があり、直近1秒で読めている）。
    /// selfReason：VoiceSelfTracker が本人の声と言わなかった理由（v1.9〜）
    mutating func add(t: Double, voiceSelf: Bool?, faceValid: Bool, selfReason: VoiceSelfTracker.Reason? = nil) -> Reason? {
        if firstT == nil { firstT = t }
        if voiceSelf == true { lastSelfT = t; recent = []; return nil }
        // 顔が読めていなければ、口が動いているかは分からないので先に出す。f0 が無いのは、顔が読めているときだけ「声の高さ」とする
        let r: Reason = !faceValid ? .noFace : voiceSelf == nil ? .noPitch
            : selfReason == .pitch ? .pitch : selfReason == .timing ? .timing : .noMouth
        recent.append((t, r))
        while let f = recent.first, t - f.t > Self.stallS { recent.removeFirst() }
        guard t - (lastSelfT ?? firstT!) >= Self.stallS else { return nil }
        var count: [Reason: Int] = [:]
        for x in recent { count[x.r, default: 0] += 1 }
        return [Reason.noPitch, .noMouth, .timing, .pitch, .noFace].max { (count[$0] ?? 0) < (count[$1] ?? 0) }
    }

    mutating func reset() { recent = []; lastSelfT = nil; firstT = nil }
}

/// baseline 行のどの部分か（v1.6〜）。古い記録の行は all（表情も声も）
enum BaselinePart: String {
    case all, face, voice

    static func of(_ s: String?) -> BaselinePart { s.flatMap(BaselinePart.init(rawValue:)) ?? .all }

    /// 記録の change のキー（"brow_down:above"・"eyes_closed:closed"・"rms_db:below"）がどの普段のものか。声が出た（voice_on）は普段と関係ないので nil
    static func ofChangeKey(_ key: String) -> BaselinePart? {
        let name = String(key.split(separator: ":").first ?? "")
        if name == DiffTarget.eyesClosedKey { return .face }
        return Metric(rawValue: name).map { $0.isFace ? .face : .voice }
    }

    /// 「普段を取り直す」（baseline_restart）のあとも続いているとみなす change のキー（v1.9.3〜）。
    /// 違いの数（sessions.jsonl の segments）は、取り直した部分のキーだけを数え直す（表情だけ取り直しても、続いている声の違いを2回数えない）。
    /// part が all（両方）なら全部数え直す（今まで通り）。sessions.py の keys_after_restart と同じ
    static func keysAfterRestart(_ keys: [String], part: BaselinePart) -> [String] {
        guard part != .all else { return [] }
        return keys.filter { ofChangeKey($0) != part }
    }
    func covers(_ m: Metric) -> Bool { self == .all || (self == .face) == m.isFace }
}

/// 違いの種類：指標（普段の z で比べる）か、目を閉じている（事実だけ、v1.4〜）か、声が出た（事実だけ、v1.7〜）
enum DiffTarget: Hashable {
    case metric(Metric)
    case eyesClosed
    case voiceOn

    static let eyesClosedKey = "eyes_closed"
    static let eyesClosedLabel = "目を閉じている"
    static let voiceOnKey = "voice_on"
    static let voiceOnLabel = "声が出た"

    /// 画面・見る側・時間の流れに並べる順（表情4つ・目を閉じている・声2つ・声が出た）
    static let all: [DiffTarget] = Metric.main.filter(\.isFace).map { .metric($0) } + [.eyesClosed]
        + Metric.main.filter { !$0.isFace }.map { .metric($0) } + [.voiceOn]

    /// 普段と比べた違いか（目を閉じている・声が出たは事実だけ）
    var isFact: Bool { if case .metric = self { false } else { true } }

    /// 画面に出す名前
    var label: String {
        switch self {
        case .metric(let m): m.label
        case .eyesClosed: Self.eyesClosedLabel
        case .voiceOn: Self.voiceOnLabel
        }
    }

    /// 記録・見る側に書く名前（"brow_down" / "eyes_closed" / "voice_on"）
    var key: String {
        switch self {
        case .metric(let m): m.rawValue
        case .eyesClosed: Self.eyesClosedKey
        case .voiceOn: Self.voiceOnKey
        }
    }

    init?(key: String) {
        if key == Self.eyesClosedKey { self = .eyesClosed }
        else if key == Self.voiceOnKey { self = .voiceOn }
        else if let m = Metric(rawValue: key) { self = .metric(m) }
        else { return nil }
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

    init(voiceOnFrom startT: Double, to endT: Double) {
        target = .voiceOn; above = true; self.startT = startT; self.endT = endT; peakZ = .nan
    }

    /// 指標の違いならその指標（目を閉じている・声が出たは nil）
    var metric: Metric? { if case .metric(let m) = target { m } else { nil } }

    var seconds: Double { endT - startT }

    /// 画面に出す文（docs/wording-guide.md）。表情は「いつもより強い」、声は「大きい／小さい」「高い／低い」。
    /// 目を閉じているは、状態の名前を付けずに「目を閉じている」だけ（秒数は呼ぶ側が足す）
    var message: String {
        switch metric {
        case nil: target.label
        case .rmsDb?: "声が、いつもより\(above ? "大きい" : "小さい")"
        case .f0Hz?: "声が、いつもより\(above ? "高い" : "低い")"
        case let m?: "\(m.label)動きが、いつもより\(above ? "強い" : "弱い")"
        }
    }

    /// 記録の change に書く形（"brow_down:above"、目を閉じているは "eyes_closed:closed"、声が出たは "voice_on:on"）
    var key: String {
        switch target {
        case .eyesClosed: "\(target.key):closed"
        case .voiceOn: "\(target.key):on"
        case .metric: "\(target.key):\(above ? "above" : "below")"
        }
    }

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
    var voiceSelf: Bool? = nil        // 本人の声か（v1.6〜、VoiceSelfTracker）。声の違いは本人の声のコマだけで判定する
}

/// 撮る側のその場の判定と、リプレイ（記録のファイルから計算し直す）で同じものを使う。
/// analysis/review.py の analyze() / detect() と同じ決まりを、1コマずつ流す形にしたもの。
/// 目を細めるのまばたきは前後 0.2秒を外すので、判定は 0.2秒遅れて進む（後ろのコマを待つ）
struct DiffEngine {
    struct Stat { let mean: Double; let sd: Double }   // sd は下限をかけたもの

    /// baseline 行の1指標から、判定に使う平均と標準偏差（下限をかけたもの）。データ不足なら nil（比べない）
    /// floor：その普段で使う標準偏差の下限（v1.18〜、その人の最大から決めた下限。baseline 行の std_floor）。無ければ指標の下限
    static func stat(for m: Metric, mean: Double?, std: Double?, insufficient: Bool, floor: Double? = nil) -> Stat? {
        guard !insufficient, let mean else { return nil }
        return Stat(mean: mean, sd: max(std ?? 0, floor ?? m.stdFloor))
    }

    private enum Item {
        case frame(DiffInput, faceValid: Bool, yaw: Double?)
        case baseline([Metric: Stat]?, BaselinePart, yaw: Double?, metricYaw: [Metric: Double])
    }

    private var queue: [Item] = []
    private var latestT = -Double.infinity
    private var blinkTimes: [Double] = []
    private var recentFace: [(t: Double, face: Bool)] = []
    private var lastYaw: (v: Double, t: Double)?
    private var faceBaseline: [Metric: Stat]?    // 表情の普段（目を閉じているもこれがある間だけ判定）
    private var voiceBaseline: [Metric: Stat]?   // 声の普段（v1.6〜は表情とは別に集める）
    private var smooth: [Metric: (v: Double, t: Double)] = [:]
    private var det: [Metric: Detector] = [:]
    private var closedDet = ClosedDetector()
    private var voiceOnDet = VoiceOnDetector()
    /// 重なりのできごと（v1.12〜）。終わったものは coDet.finished
    var coDet = CoChangeDetector()
    private var faceYaw: Double?                 // 表情の普段の yaw（v1.16〜）
    private var metricYaw: [Metric: Double] = [:]   // 今日の普段から足した指標の yaw（v1.17〜。from_today の指標は今日の普段の向きと比べる）
    /// 最後に判定したコマで、顔の向きが普段と違うので目の指標を比べなかったか（データのタブ、v1.16〜）
    private(set) var eyesYawExcluded = false

    /// 判定したコマごとの z（v1.18〜。nil でなければ足していく。試すモードの結果・DiffCheck --cues 用）
    var zLog: [(t: Double, z: [Metric: Double])]?
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

    /// 普段を決めた・取り直した（nil で両方を消す）。この時刻より後のコマから使う。
    /// part が face / voice なら、その部分だけ変える（v1.6〜）
    /// yaw：その表情の普段の yaw の中央値（v1.16〜。目の指標を、顔の向きが普段から yawTolerance 以上ずれたコマでは比べない。無い古い普段は平均）
    /// metricYaw：指標ごとに別の普段の yaw（v1.17〜。保存した普段で比べていて、今日の普段から足した指標＝from_today は今日の普段の yaw）
    mutating func setBaseline(_ b: [Metric: Stat]?, part: BaselinePart = .all, yaw: Double? = nil, metricYaw: [Metric: Double] = [:]) {
        queue.append(.baseline(b, part, yaw: yaw, metricYaw: metricYaw))
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
        queue.append(.frame(x, faceValid: valid, yaw: yawNow))
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
        coDet.flush()
    }

    private mutating func drain(until limit: Double) {
        while let first = queue.first {
            switch first {
            case .baseline(let b, let part, let yaw, let my):
                if part != .voice { faceYaw = b == nil ? nil : yaw; metricYaw = b == nil ? [:] : my }
                if part != .voice { faceBaseline = b.map { $0.filter { $0.key.isFace } } }
                if part != .face { voiceBaseline = b.map { $0.filter { !$0.key.isFace } } }
                queue.removeFirst()
            case .frame(let x, let valid, let yaw):
                guard x.t <= limit else { return }
                queue.removeFirst()
                process(x, faceValid: valid, yaw: yaw)
            }
        }
    }

    private func blinked(at t: Double) -> Bool {
        blinkTimes.contains { abs($0 - t) <= DiffCriteria.blinkPadS + 1e-9 }
    }

    private mutating func process(_ x: DiffInput, faceValid: Bool, yaw: Double?) {
        // 目の指標（v1.16〜）：顔の向きが普段から yawTolerance 以上ずれたコマでは比べない（目の値は向きでずれるため。review.py と同じ：直近 1秒の yaw）
        // v1.17〜：今日の普段から足した指標（from_today）は、今日の普段の yaw と比べる
        func offYaw(_ m: Metric) -> Bool {
            guard m.isEyeMetric, let fy = metricYaw[m] ?? faceYaw, let y = yaw else { return false }
            return abs(y - fy) >= DiffCriteria.eyeYawToleranceDeg - 1e-9
        }
        eyesYawExcluded = Metric.allCases.contains { offYaw($0) && (faceBaseline?[$0] != nil) }
        processedT = x.t
        blinkTimes.removeAll { $0 < x.t - DiffCriteria.blinkPadS - 1 }
        let blink = blinked(at: x.t)
        for m in Metric.allCases {
            // 生の値（目を細めるは、まばたきのコマを入れない）
            var raw: Double? = m.isFace ? (x.face ? x.faceValues[m] : nil) : x.voice[m]
            if m.blinkMasked && blink { raw = nil }
            if !m.isFace && x.voiceSelf != true { raw = nil }   // 声は本人の声のコマの値だけ使う（v1.6〜）
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
            if let s = smooth[m], x.t - s.t <= DiffCriteria.staleS, let b = (m.isFace ? faceBaseline : voiceBaseline)?[m] {
                zz = (s.v - b.mean) / b.sd
            }
            if m.isFace && !faceValid { zz = nil }
            if !m.isFace && x.voiceSelf == false { zz = nil }   // 本人以外の声（と言えない声）のコマでは判定しない
            if m.blinkMasked && blink { zz = nil }
            if offYaw(m) { zz = nil }
            z[m] = zz
            guard m.isMain else { continue }   // 表情のまとまり（v1.12〜）は z だけ。「いつもとの違い」の区間にはしない

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

        // 重なりのできごと（v1.12〜）：判定できた指標の z だけで
        coDet.step(t: x.t, z: z)
        zLog?.append((x.t, z))

        // 目を閉じている：普段とは比べないが、ほかの違いと同じく普段がある間だけ、顔が読めて |yaw| < 35° のコマで判定する
        let judgeable = faceBaseline != nil && faceValid
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

        // 声が出た：普段が無くても、すべてのコマで判定する（本人の声のコマかどうかだけを見る）
        let (vStarted, vEnded) = voiceOnDet.step(t: x.t, on: x.voiceSelf == true)
        if let e = vEnded {
            var seg = active[.voiceOn] ?? DiffSegment(voiceOnFrom: e.start, to: e.end)
            seg.endT = e.end; seg.open = false
            finished.append(seg)
            active[.voiceOn] = nil
        }
        if let s = vStarted {
            active[.voiceOn] = DiffSegment(voiceOnFrom: s.start, to: s.end)
        } else if let cur = voiceOnDet.seg, var seg = active[.voiceOn] {
            seg.endT = cur.end
            active[.voiceOn] = seg
        }
    }

    /// 声が出た（review.py の detect_voice_on を1コマずつにしたもの）。
    /// 本人の声のコマ（on）を、前の on のコマとの間が 0.5秒未満ならひとまとまりにする。まとまりの最初の on から今の on までが 0.3秒以上になったら始まり。
    /// on のコマが来ないまま、最後の on から 0.5秒たったコマで終わり（終わりの時刻は最後の on のコマ）
    struct VoiceOnDetector {
        struct Seg { var start: Double; var end: Double }
        private var first: Double?
        private var lastOn: Double?
        private(set) var seg: Seg?

        mutating func step(t: Double, on: Bool) -> (Seg?, Seg?) {
            var ended: Seg?
            if let l = lastOn, t - l >= DiffCriteria.voiceOnGapS - 1e-9 {   // 切れ目
                if var s = seg { s.end = l; ended = s }
                seg = nil; first = nil; lastOn = nil
            }
            guard on else { return (nil, ended) }
            if first == nil { first = t }
            lastOn = t
            if var s = seg {
                s.end = t
                seg = s
                return (nil, ended)
            }
            if let f = first, t - f >= DiffCriteria.voiceOnMinS - 1e-9 {
                let new = Seg(start: f, end: t)
                seg = new
                return (new, ended)
            }
            return (nil, ended)
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
