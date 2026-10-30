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

/// 「いつもとの違い」が始まった時刻（指標ごと。key は記録の change と同じ "brow_down:above" など）
struct CueStart: Equatable { let t: Double; let key: String }

/// 試すモードの結果（v1.18〜。v1.20〜は数え方を撮る側の change に合わせた）。アプリの画面と DiffCheck --cues（JSON）に出す。face_check.py --cues と同じ決まり
struct CueReport: Codable, Equatable {
    static let graceS = 2.0     // 指示が終わってから、この秒数までに始まったものも数える（ならしの遅れ）
    static let hitZ = 2.0       // 指標ごとの「z が出た」：動く向きの z がこれ以上のコマがあった
    /// 記録し直した区間の始まりを、撮る側の change と同じ時点にそろえる：z が 2 を超えてから startMinS 続いたとき（v1.20〜）
    static let startOffsetS = DiffCriteria.startMinS
    /// frown → 眉を寄せる（brow_down の「いつもより強い」）、smile → 口角を上げる（mouth_smile）
    static let target: [CueKind: String] = [.frown: "brow_down:above", .smile: "mouth_smile:above"]
    /// 指標ごとの表に並べる指標と向き
    static let metrics: [(m: Metric, sign: Double)] = Calibration.frown + Calibration.smile

    struct Hit: Codable, Equatable {
        let kind: String
        let n: Int               // 指示の回数
        let hit: Int             // target の「いつもより強い」が、指示の始まり〜終わり + graceS に始まった指示の数
        let latencyS: [Double]   // 出た指示の、始まりから最初に始まるまでの秒数
        let co: Int              // 重なりのできごとが重なっていた指示の数（v1.20〜：指示ごとに区切る）
    }
    struct Quiet: Codable, Equatable {
        let kind: String
        let seconds: Double
        let windows: Int         // 指示の数
        let diffs: Int           // その間に始まった「いつもとの違い」（指標ごとに始まった回数。声が出たは入れない）
        let byKey: [String: Int] // その内訳（"eyes_closed:closed" など）
        let co: Int              // 重なりのできごとが重なっていた指示の数
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

    /// starts：指標ごとに「いつもとの違い」が始まった時刻（撮る側の change から、または記録し直した区間から）。co：重なりのできごとの始まり・終わり
    static func compute(cues: [Cue], starts: [CueStart], co: [(start: Double, end: Double)], zLog: [(t: Double, z: [Metric: Double])]) -> CueReport {
        var r = CueReport()
        let st = starts.filter { !$0.key.hasPrefix(DiffTarget.voiceOnKey + ":") }
        func coOn(_ c: Cue) -> Bool { co.contains { $0.start < c.end - 1e-9 && $0.end >= c.start - 1e-9 } }
        for kind in [CueKind.frown, .smile] {
            let cs = cues.filter { $0.kind == kind }
            guard let key = target[kind] else { continue }
            var lat: [Double] = []
            for c in cs {
                let first = st.filter { $0.key == key && $0.t >= c.start - 1e-9 && $0.t <= c.end + graceS + 1e-9 }.map(\.t).min()
                if let f = first { lat.append(((f - c.start) * 1000).rounded() / 1000) }
            }
            r.hits.append(Hit(kind: kind.rawValue, n: cs.count, hit: lat.count, latencyS: lat, co: cs.filter(coOn).count))
        }
        for kind in [CueKind.calm, .turn, .rest] {
            let cs = cues.filter { $0.kind == kind }
            let inside = st.filter { s in cs.contains { s.t >= $0.start - 1e-9 && s.t < $0.end - 1e-9 } }
            var by: [String: Int] = [:]
            for s in inside { by[s.key, default: 0] += 1 }
            r.quiet.append(Quiet(kind: kind.rawValue, seconds: ((cs.reduce(0) { $0 + $1.end - $1.start }) * 1000).rounded() / 1000,
                                 windows: cs.count, diffs: inside.count, byKey: by, co: cs.filter(coOn).count))
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

    /// 撮る側の change の行から：前の行に無かった key が出たら、その時刻に始まった（同じ key が続いているだけなら数えない）
    static func starts(changes: [(t: Double, keys: [String])]) -> [CueStart] {
        var prev: Set<String> = [], out: [CueStart] = []
        for c in changes.sorted(by: { $0.t < $1.t }) {
            for k in c.keys where !prev.contains(k) { out.append(CueStart(t: c.t, key: k)) }
            prev = Set(c.keys)
        }
        return out
    }

    /// 記録し直した区間から（画面に出す区間だけ。始まりは z が超えてから startOffsetS 後＝change と同じ時点）
    static func starts(segments: [DiffSegment]) -> [CueStart] {
        segments.filter(\.shown).map { CueStart(t: $0.startT + startOffsetS, key: $0.key) }
    }

    func hit(_ k: CueKind) -> Hit? { hits.first { $0.kind == k.rawValue } }
    func quiet(_ k: CueKind) -> Quiet? { quiet.first { $0.kind == k.rawValue } }
    func row(_ m: Metric, _ k: CueKind) -> Row? { rows.first { $0.metric == m.rawValue && $0.kind == k.rawValue } }

    /// 1分あたり（秒が 0 なら nil）
    static func perMin(_ count: Int, _ seconds: Double) -> Double? { seconds > 0 ? Double(count) / seconds * 60 : nil }
}

/// 記録し直した判定（区間・重なり・コマごとの z）
struct CueReplay {
    let segments: [DiffSegment]
    let coChanges: [CoChange]
    let zLog: [(t: Double, z: [Metric: Double])]
    var co: [(start: Double, end: Double)] { coChanges.map { ($0.startT, $0.endT) } }
}

/// 試すモードの結果（v1.18〜）。
/// before（今の下限）：「いつもとの違い」は撮る側の change の行から数える（v1.20〜。撮る側の画面と同じ）。change の行が無い記録は記録し直した区間から。
///   重なり・指標ごとの z は、試すモードの間に使っていた下限（記録の std_floor）で記録し直したもの。
/// after（最大から決めた下限）：その人の最大で決めた下限で記録し直したもの（撮る側では使っていないので、change は無い）
struct CueTrial: Codable, Equatable {
    var max: [String: Double]
    var before: CueReport
    var after: CueReport?
    var fromChanges: Bool            // before の「いつもとの違い」を撮る側の change から数えた
    var beforeReplayHits: [CueReport.Hit]?   // 確かめる用：before を記録し直した区間で数えたときの回数（change と違えば、記録し直しが撮る側と合っていない）

    static func compute(cues: [Cue], changes: [(t: Double, keys: [String])], before: CueReplay, after: CueReplay?,
                        maxima: [Metric: Double]) -> CueTrial {
        let fromChanges = !changes.isEmpty
        let replayStarts = CueReport.starts(segments: before.segments)
        let b = CueReport.compute(cues: cues, starts: fromChanges ? CueReport.starts(changes: changes) : replayStarts, co: before.co, zLog: before.zLog)
        let a = after.map { CueReport.compute(cues: cues, starts: CueReport.starts(segments: $0.segments), co: $0.co, zLog: $0.zLog) }
        let check = fromChanges ? CueReport.compute(cues: cues, starts: replayStarts, co: before.co, zLog: []).hits : nil
        return CueTrial(max: Dictionary(uniqueKeysWithValues: maxima.map { ($0.key.rawValue, $0.value) }), before: b, after: a,
                        fromChanges: fromChanges, beforeReplayHits: check)
    }

    /// 記録のファイルから（DiffCheck --cues。アプリは記録を読み直さず、試すモードの間の入力から同じ compute を使う）
    static func run(data: Data, name: String) throws -> CueTrial? {
        let d = try ReplayData(data: data, name: name, floorMode: .recorded, keepZ: true)
        let cues = lastRun(d.cues)
        guard let first = cues.first, let last = cues.last else { return nil }
        let mx = Calibration.maxima(frames: d.rawFace, cues: cues)
        var after: CueReplay?
        if !mx.isEmpty {
            let a = try ReplayData(data: data, name: name, floorMode: .calibrated(mx), keepZ: true)
            after = CueReplay(segments: a.segments, coChanges: a.coChanges, zLog: a.zLog)
        }
        // change の行：試すモードの間と、その直前の状態（続いている違いを「始まった」と数えないため）
        let rows = d.changeRows.filter { $0.t <= last.end + CueReport.graceS + 1 }
        let before = rows.filter { $0.t < first.start }.last.map { [$0] } ?? []
        return compute(cues: cues, changes: before + rows.filter { $0.t >= first.start }, before: CueReplay(segments: d.segments, coChanges: d.coChanges, zLog: d.zLog),
                       after: after, maxima: mx)
    }

    /// 最後の試すモード：指示の間が 10秒より空いたら別のまとまり
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
