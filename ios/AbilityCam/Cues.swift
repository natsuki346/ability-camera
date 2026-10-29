import Foundation

// 試すモード（v1.18〜、設定の「確かめる用の設定」の中、撮る側だけ）：画面の指示どおりに顔を動かし、正解つきで「いつもとの違い」が出たかを確かめる。
// 指示ごとに記録へ event（kind: "cue"、value、start_ms・end_ms）を書き、終わったら記録を読み直して（ReplayData、DiffCheck --cues と同じ）結果を出す。
// analysis/face_check.py --cues が同じ表を Mac で出す（check_app.py が一致を確かめる）。決まりは criteria.json の cues・calibration（どれも仮の値）

/// 指示の種類（記録の cue の value）
enum CueKind: String, CaseIterable, Codable {
    case calm, frown, smile, turn, rest
    case frownMax = "frown_max", smileMax = "smile_max"   // その人の最大（キャリブレーション）

    /// 画面に出す指示（docs/wording-guide.md：試すモードだけは、自分で試す人への指示を出す。良い・悪いは言わない）
    var instruction: String {
        switch self {
        case .calm: "何もしないでください"
        case .frown: "眉を寄せてください"
        case .smile: "笑ってください"
        case .turn: "顔を横に向けてください"
        case .rest: "戻してください"
        case .frownMax: "いちばん強く眉を寄せてください"
        case .smileMax: "いちばん大きく笑ってください"
        }
    }
}

struct CueStep: Equatable {
    let kind: CueKind
    let seconds: Double
}

/// 1つの指示（時刻は epoch 秒）
struct Cue: Equatable {
    let kind: CueKind
    let start: Double
    let end: Double
}

enum CuePlan {
    static let repeats = 5
    /// 何もしない 30秒 → 眉を寄せる 3秒・戻す 3秒 ×5 → 笑う 3秒・戻す 3秒 ×5 → 横を向く 20秒 → 何もしない 30秒 → いちばん強く眉を寄せる 3秒・戻す 3秒 → いちばん大きく笑う 3秒・戻す 3秒
    static let steps: [CueStep] = {
        var s = [CueStep(kind: .calm, seconds: 30)]
        for _ in 0..<repeats { s += [CueStep(kind: .frown, seconds: 3), CueStep(kind: .rest, seconds: 3)] }
        for _ in 0..<repeats { s += [CueStep(kind: .smile, seconds: 3), CueStep(kind: .rest, seconds: 3)] }
        s += [CueStep(kind: .turn, seconds: 20), CueStep(kind: .calm, seconds: 30),
              CueStep(kind: .frownMax, seconds: 3), CueStep(kind: .rest, seconds: 3),
              CueStep(kind: .smileMax, seconds: 3), CueStep(kind: .rest, seconds: 3)]
        return s
    }()
    static var totalS: Double { steps.reduce(0) { $0 + $1.seconds } }
}

/// その人の動く幅（キャリブレーション、v1.18〜。criteria.json の calibration、仮の値）
enum Calibration {
    /// 「いちばん強く眉を寄せる」で見る指標と向き（−1：眉を寄せると小さくなる点の距離）
    static let frown: [(m: Metric, sign: Double)] = [(.browDown, 1), (.browEyeGap, -1), (.browInnerGap, -1), (.browInnerEye, -1), (.browInnerGap2, -1)]
    /// 「いちばん大きく笑う」で見る指標
    static let smile: [(m: Metric, sign: Double)] = [(.mouthSmile, 1), (.mouthCorner, 1)]
    static var all: [(m: Metric, sign: Double)] { frown + smile }
    static let q = 0.95          // 動く向きの p95（小さくなる指標は p5）を「その人の最大」に
    static let minN = 10         // これより値が少ない指標は最大を決めない
    static let floorFrac = 0.1   // 下限 = min(今の下限, |最大 − 普段の中央値| × floorFrac)
    static let floorMin = 0.001  // ただしこれより小さくしない（動かなかった指標で z が大きくなりすぎないように）

    /// 最大：frown_max・smile_max の指示の間の値（顔のあるコマの生の値）。frames は時刻の順でなくてよい
    static func maxima(frames: [(t: Double, v: [Metric: Double])], cues: [Cue]) -> [Metric: Double] {
        var out: [Metric: Double] = [:]
        for (kind, list) in [(CueKind.frownMax, frown), (CueKind.smileMax, smile)] {
            let ws = cues.filter { $0.kind == kind }
            guard !ws.isEmpty else { continue }
            for (m, sign) in list {
                let xs = frames.filter { f in ws.contains { f.t >= $0.start - 1e-9 && f.t <= $0.end + 1e-9 } }.compactMap { $0.v[m] }.sorted()
                guard xs.count >= minN else { continue }
                out[m] = (DiffCriteria.quantile(xs, sign > 0 ? q : 1 - q) * 10000).rounded() / 10000
            }
        }
        return out
    }

    /// その普段で使う下限（指標の下限より小さくなるものだけ）。ref：その普段の中央値（無い普段は平均）
    static func floors(ref: (Metric) -> Double?, max: [Metric: Double]) -> [Metric: Double] {
        var out: [Metric: Double] = [:]
        for (m, x) in max {
            guard let r = ref(m) else { continue }
            let f = Swift.max(floorMin, Swift.min(m.stdFloor, abs(x - r) * floorFrac))
            if f < m.stdFloor - 1e-12 { out[m] = (f * 1e6).rounded() / 1e6 }
        }
        return out
    }
}

/// 試すモードの結果（v1.18〜）。アプリの画面と DiffCheck --cues（JSON）に出す。face_check.py --cues と同じ決まり
struct CueReport: Codable, Equatable {
    static let graceS = 2.0     // 指示が終わってから、この秒数までに出たものも数える（ならしの遅れ）
    static let hitZ = 2.0       // 指標ごとの「z が出た」：動く向きの z がこれ以上のコマがあった
    /// frown → 眉を寄せる（brow_down の「いつもより強い」）、smile → 口角を上げる（mouth_smile）
    static let target: [CueKind: Metric] = [.frown: .browDown, .smile: .mouthSmile]
    /// 指標ごとの表に並べる指標と向き
    static let metrics: [(m: Metric, sign: Double)] = Calibration.frown + Calibration.smile

    struct Hit: Codable, Equatable {
        let kind: String
        let n: Int               // 指示の回数
        let hit: Int             // 「いつもとの違い」が出た回数（指示の始まり〜終わり + graceS に始まった、target の「いつもより強い」）
        let latencyS: [Double]   // 出た回の、指示の始まりから違いの始まりまでの秒数
    }
    struct Quiet: Codable, Equatable {
        let kind: String
        let seconds: Double
        let diffs: Int           // その間に始まった「いつもとの違い」（声が出たは入れない）
        let co: Int              // その間に始まった重なりのできごと
    }
    struct Row: Codable, Equatable {
        let metric: String
        let kind: String
        let n: Int
        let hit: Int             // 動く向きの z ≥ hitZ のコマがあった回数
        let zMedian: Double?     // 指示の間の、動く向きの z の中央値
    }
    var hits: [Hit] = []
    var quiet: [Quiet] = []
    var rows: [Row] = []

    static func compute(cues: [Cue], segments: [DiffSegment], coChanges: [CoChange], zLog: [(t: Double, z: [Metric: Double])]) -> CueReport {
        var r = CueReport()
        let shown = segments.filter { $0.target != .voiceOn }
        for kind in [CueKind.frown, .smile] {
            let cs = cues.filter { $0.kind == kind }
            guard let m = target[kind] else { continue }
            var lat: [Double] = []
            for c in cs {
                let s = shown.filter { $0.target == .metric(m) && $0.above && $0.startT >= c.start - 1e-9 && $0.startT <= c.end + graceS + 1e-9 }
                    .min { $0.startT < $1.startT }
                if let s { lat.append(((s.startT - c.start) * 1000).rounded() / 1000) }
            }
            r.hits.append(Hit(kind: kind.rawValue, n: cs.count, hit: lat.count, latencyS: lat))
        }
        for kind in [CueKind.calm, .turn, .rest] {
            let cs = cues.filter { $0.kind == kind }
            func inside(_ t: Double) -> Bool { cs.contains { t >= $0.start - 1e-9 && t < $0.end - 1e-9 } }
            r.quiet.append(Quiet(kind: kind.rawValue, seconds: ((cs.reduce(0) { $0 + $1.end - $1.start }) * 1000).rounded() / 1000,
                                 diffs: shown.filter { inside($0.startT) }.count, co: coChanges.filter { inside($0.startT) }.count))
        }
        for kind in [CueKind.frown, .smile] {
            let cs = cues.filter { $0.kind == kind }
            for (m, sign) in metrics {
                var zs: [Double] = []
                var hit = 0
                for c in cs {
                    var got = false
                    for f in zLog where f.t >= c.start - 1e-9 && f.t <= c.end + graceS + 1e-9 {
                        guard let z = f.z[m] else { continue }
                        if f.t <= c.end + 1e-9 { zs.append(z * sign) }
                        if z * sign >= hitZ - 1e-9 { got = true }
                    }
                    if got { hit += 1 }
                }
                let med = zs.isEmpty ? nil : (DiffCriteria.quantile(zs.sorted(), 0.5) * 1000).rounded() / 1000
                r.rows.append(Row(metric: m.rawValue, kind: kind.rawValue, n: cs.count, hit: hit, zMedian: med))
            }
        }
        return r
    }

    func hit(_ k: CueKind) -> Hit? { hits.first { $0.kind == k.rawValue } }
    func quiet(_ k: CueKind) -> Quiet? { quiet.first { $0.kind == k.rawValue } }
    func row(_ m: Metric, _ k: CueKind) -> Row? { rows.first { $0.metric == m.rawValue && $0.kind == k.rawValue } }

    /// 1分あたり（秒が 0 なら nil）
    static func perMin(_ count: Int, _ seconds: Double) -> Double? { seconds > 0 ? Double(count) / seconds * 60 : nil }
}

/// 試すモードの結果を、記録のファイルから出す（v1.18〜。アプリが終わったときと DiffCheck --cues で同じ）。
/// before：今の下限（試すモードの間に使っていた下限＝記録の baseline 行の std_floor、無ければ指標ごとの下限。v1.19〜）、after：この記録の「いちばん強く・大きく」から求めたその人の最大で決めた下限。
/// 記録の中の最後の試すモードの指示だけを使う（同じ記録で2回試したときは後の方）
struct CueTrial: Codable, Equatable {
    var max: [String: Double]        // この記録から求めたその人の最大（Calibration.maxima）
    var before: CueReport
    var after: CueReport?            // 最大が1つも求まらなければ nil

    static func run(data: Data, name: String) throws -> CueTrial? {
        let d = try ReplayData(data: data, name: name, floorMode: .recorded, keepZ: true)
        let cues = lastRun(d.cues)
        guard !cues.isEmpty else { return nil }
        let mx = Calibration.maxima(frames: d.rawFace, cues: cues)
        let before = CueReport.compute(cues: cues, segments: d.segments, coChanges: d.coChanges, zLog: d.zLog)
        var after: CueReport?
        if !mx.isEmpty {
            let a = try ReplayData(data: data, name: name, floorMode: .calibrated(mx), keepZ: true)
            after = CueReport.compute(cues: cues, segments: a.segments, coChanges: a.coChanges, zLog: a.zLog)
        }
        return CueTrial(max: Dictionary(uniqueKeysWithValues: mx.map { ($0.key.rawValue, $0.value) }), before: before, after: after)
    }

    /// 最後の試すモード：最初の指示（何もしない）から始まるまとまりのうち、最後のもの（指示の間が 10秒より空いたら別のまとまり）
    static func lastRun(_ cues: [Cue]) -> [Cue] {
        let s = cues.sorted { $0.start < $1.start }
        var out: [Cue] = []
        for c in s {
            if let last = out.last, c.start - last.end > 10 { out = [] }
            out.append(c)
        }
        return out
    }
}
