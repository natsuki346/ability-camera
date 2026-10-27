import Foundation

/// リプレイの今の位置に出す出来事（場面・家族の印・いつもとの違い・顔の向き）
struct ReplayEvent: Identifiable {
    enum Kind { case scene, mark, diff, head }
    let id = UUID()
    let t: Double            // epoch 秒
    let kind: Kind
    let text: String         // 「家族の印：不快」「眉を寄せる動きが、いつもより強い（8秒）」「顔の向き：右へ」
}

struct ReplayRun<V> {
    let start: Double
    var end: Double
    let value: V
}

/// 記録のファイル（JSONL）から、リプレイに使うものを作る。映像は無いので、記録した表情の数値と顔の向きで顔の絵を動かす。
/// 「いつもとの違い」は記録の baseline 行と、撮る側と同じ決まり（DiffEngine）で計算し直す。研究用の合計は作らない
final class ReplayData: Identifiable, @unchecked Sendable {   // 作ったあとは変えない
    let id = UUID()
    let name: String
    let startT: Double               // 最初のコマ（epoch 秒）
    let endT: Double                 // 最後のコマ
    let camera: String?              // ヘッダの camera_label

    // コマごと（顔の絵用）
    let times: [Double]
    private let shapes: [Float]      // shapeKeys の順で、約0.2秒でならした値（撮る側の顔の絵と同じ）
    private let readable: [Bool]     // 直近1秒で顔が映るコマが半分以上
    static var shapeKeys: [String] { FaceSketch.keys + ["yaw", "pitch", "roll"] }

    // 時間の帯・出来事
    let segments: [DiffSegment]                  // 画面に出す違い（表情の「いつもより弱い」は入れない）
    let scenes: [ReplayRun<String>]
    let marks: [ReplayEvent]
    let heads: [ReplayRun<HeadState>]            // 撮る側と同じ決まりで、コマから数え直した顔の向き
    let noBaseline: [ReplayRun<Bool>]            // 普段が無く、比べていない時間
    let events: [ReplayEvent]                    // 時刻の順

    // 要約
    let durationS: Double
    let faceRatio: Double?
    var diffCount: Int { segments.count }
    var markCount: Int { marks.count }
    let notes: [String]

    enum LoadError: LocalizedError {
        case empty
        var errorDescription: String? { "記録のコマがありません（Ability Cam の記録のファイルか確かめてください）" }
    }

    /// 重いので裏のスレッドで呼ぶ
    init(data: Data, name: String) throws {
        self.name = name
        var header: [String: Any] = [:]
        var frames: [[String: Any]] = []
        var baselines: [[String: Any]] = []
        var evs: [[String: Any]] = []
        var first = true
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // 途中で終了されて壊れた最後の行は飛ばす
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { first = false; continue }
            defer { first = false }
            let type = o["type"] as? String
            if first, o["schema"] != nil { header = o; continue }
            switch type {
            case "frame": frames.append(o)
            case "baseline": baselines.append(o)
            case "event": evs.append(o)
            case nil where o["face"] != nil: frames.append(o)
            default: break
            }
        }
        func ms(_ o: [String: Any], _ k: String = "t_ms") -> Double? { (o[k] as? NSNumber).map { $0.doubleValue / 1000 } }
        frames = frames.filter { ms($0) != nil }.sorted { ms($0)! < ms($1)! }
        guard !frames.isEmpty else { throw LoadError.empty }
        baselines.sort { (ms($0) ?? 0) < (ms($1) ?? 0) }
        evs = evs.filter { ms($0) != nil }.sorted { ms($0)! < ms($1)! }
        camera = header["camera_label"] as? String

        // コマを読む
        let n = frames.count
        var t = [Double](repeating: 0, count: n)
        var face = [Bool](repeating: false, count: n)
        var yaw = [Double?](repeating: nil, count: n)
        var bsList = [[String: Double]](repeating: [:], count: n)
        var rms = [Double?](repeating: nil, count: n), f0 = [Double?](repeating: nil, count: n)
        var pitch = [Double?](repeating: nil, count: n), roll = [Double?](repeating: nil, count: n)
        for (i, o) in frames.enumerated() {
            t[i] = ms(o)!
            yaw[i] = (o["yaw_deg"] as? NSNumber)?.doubleValue
            pitch[i] = (o["pitch_deg"] as? NSNumber)?.doubleValue
            roll[i] = (o["roll_deg"] as? NSNumber)?.doubleValue
            rms[i] = (o["rms_db"] as? NSNumber)?.doubleValue
            f0[i] = (o["f0_hz"] as? NSNumber)?.doubleValue
            if (o["face"] as? Bool) == true, let bs = o["bs"] as? [String: Any] {
                face[i] = true
                var d: [String: Double] = [:]
                for (k, v) in bs { d[k] = (v as? NSNumber)?.doubleValue ?? 0 }
                bsList[i] = d
            }
        }
        times = t
        startT = t[0]; endT = t[n - 1]
        func avg(_ i: Int, _ a: String, _ b: String) -> Double { ((bsList[i][a] ?? 0) + (bsList[i][b] ?? 0)) / 2 }
        let blink: [Double?] = (0..<n).map { face[$0] ? avg($0, "eyeBlinkLeft", "eyeBlinkRight") : nil }
        let squint: [Double?] = (0..<n).map { face[$0] ? avg($0, "eyeSquintLeft", "eyeSquintRight") : nil }

        // 顔の絵：撮る側と同じく、約0.2秒の移動平均（間が1秒以上空いたら今の値から）。直近1秒で顔が半分未満なら読めない
        let keys = Self.shapeKeys
        var sh = [Float](repeating: 0, count: n * keys.count)
        var rd = [Bool](repeating: false, count: n)
        var cur = [Double](repeating: 0, count: keys.count)
        var lastFaceT = -Double.infinity
        var lo = 0, faceInWin = 0
        for i in 0..<n {
            if face[i] { faceInWin += 1 }
            while t[lo] < t[i] - 1 { if face[lo] { faceInWin -= 1 }; lo += 1 }
            rd[i] = faceInWin * 2 >= (i - lo + 1)
            if face[i] {
                let a = t[i] - lastFaceT > 1 ? 1 : 1 - exp(-max(t[i] - lastFaceT, 0) / 0.2)
                for (j, k) in keys.enumerated() {
                    let x: Double? = switch k {
                    case "yaw": yaw[i]
                    case "pitch": pitch[i]
                    case "roll": roll[i]
                    default: bsList[i][k] ?? 0
                    }
                    if let x { cur[j] += a * (x - cur[j]) }
                }
                lastFaceT = t[i]
            }
            for j in 0..<keys.count { sh[i * keys.count + j] = Float(cur[j]) }
        }
        shapes = sh; readable = rd

        // 普段：記録の baseline 行。目を細めるにまばたきが入っている古い行（blink_masked が無い）は、振り返りレポートと同じく数え直す
        var notes: [String] = []
        let startedAt = ms(header, "started_at_ms") ?? t[0]
        let recount = Self.squintWithoutBlinks(t: t, face: face, yaw: yaw, squint: squint, blink: blink, start0: startedAt)
        var bItems: [(t: Double, stats: [Metric: DiffEngine.Stat]?)] = []
        for b in baselines {
            // 撮る側が比べるのに使わなかった行（v1.2〜の compared: false）は使わない（振り返りレポートと同じ）
            guard let bt = ms(b), (b["compared"] as? Bool) != false else { continue }
            let metrics = b["metrics"] as? [String: [String: Any]] ?? [:]
            var stats: [Metric: DiffEngine.Stat] = [:]
            for m in Metric.allCases {
                var st = metrics[m.rawValue] ?? [:]
                if m == .eyeSquint, (b["blink_masked"] as? Bool) != true {
                    if let s0 = ms(b, "started_ms") { st = recount(s0, bt) }
                    else if !notes.contains(Self.noteNoStart) { notes.append(Self.noteNoStart) }
                }
                if let s = DiffEngine.stat(for: m, mean: (st["mean"] as? NSNumber)?.doubleValue,
                                           std: (st["std"] as? NSNumber)?.doubleValue,
                                           insufficient: (st["insufficient"] as? Bool) ?? true) {
                    stats[m] = s
                }
            }
            bItems.append((bt, stats))
        }
        for e in evs where e["kind"] as? String == "baseline_restart" { bItems.append((ms(e)!, nil)) }
        bItems.sort { $0.t < $1.t }
        if baselines.isEmpty { notes.append("この記録には普段（baseline 行）が無いので、いつもとの違いは出せません") }

        // いつもとの違い：撮る側と同じ決まりで、コマを順に流す
        var engine = DiffEngine()
        var bi = 0
        var noBase: [ReplayRun<Bool>] = []
        var hasBase = false
        var segs: [DiffSegment] = []
        for i in 0..<n {
            while bi < bItems.count, bItems[bi].t <= t[i] {   // その時刻のコマから使う（review.py の baseline_index）
                engine.setBaseline(bItems[bi].stats)
                hasBase = bItems[bi].stats != nil
                bi += 1
            }
            if !hasBase {
                if let last = noBase.last, abs(last.end - (i > 0 ? t[i - 1] : t[i])) < 1e-9 { noBase[noBase.count - 1].end = t[i] }
                else { noBase.append(ReplayRun(start: t[i], end: t[i], value: true)) }
            }
            var fv: [Metric: Double] = [:]
            if face[i] {
                fv[.mouthSmile] = avg(i, "mouthSmileLeft", "mouthSmileRight")
                fv[.browDown] = avg(i, "browDownLeft", "browDownRight")
                fv[.eyeSquint] = squint[i]
                fv[.jawOpen] = bsList[i]["jawOpen"] ?? 0
            }
            var voice: [Metric: Double] = [:]
            if let r = rms[i] { voice[.rmsDb] = r }
            if let f = f0[i] { voice[.f0Hz] = f }
            engine.add(DiffInput(t: t[i], face: face[i], yaw: yaw[i], faceValues: fv, blink: blink[i], voice: voice))
            segs += engine.finished
            engine.finished = []
        }
        engine.flush()
        segs += engine.finished
        segments = segs.filter(\.shown).sorted { $0.startT < $1.startT }
        noBaseline = noBase

        // 場面・家族の印・顔の向きの記録
        var sc: [ReplayRun<String>] = []
        var mk: [ReplayEvent] = []
        var list: [ReplayEvent] = []
        for e in evs {
            let et = ms(e)!
            let kind = e["kind"] as? String
            let value = e["value"] as? String
            switch kind {
            case "scene":
                if let last = sc.last, last.end > et { sc[sc.count - 1].end = et }
                if let v = value, v != "なし" { sc.append(ReplayRun(start: et, end: t[n - 1], value: v)) }
                list.append(ReplayEvent(t: et, kind: .scene, text: "場面：\(value ?? "なし")"))
            case "mark":
                let by = (e["source"] as? String) == "viewer" ? "（\(e["by"] as? String ?? "見る側")で）" : ""
                let ev = ReplayEvent(t: et, kind: .mark, text: "家族の印：\(value ?? "")\(by)")
                mk.append(ev); list.append(ev)
            case "head_turn":
                list.append(ReplayEvent(t: et, kind: .head, text: "顔の向き：\(value ?? "")"))
            default: break
            }
        }
        for s in segments {
            list.append(ReplayEvent(t: s.startT, kind: .diff, text: "\(s.message)（\(Int(s.seconds.rounded()))秒）"))
        }
        scenes = sc; marks = mk
        events = list.sorted { $0.t < $1.t }

        // 顔の向きの段：撮る側と同じ決まり（0.5秒続いたら変わる）で、コマから数え直す。向きが記録されていない（v0.3 より前）なら作らない
        var hs: [ReplayRun<HeadState>] = []
        if yaw.contains(where: { $0 != nil }) {
            var tracker = HeadTurnTracker()
            for i in 0..<n {
                if i > 0, t[i] - t[i - 1] > 1 { tracker.reset() }   // カメラを止めていた間は分からない
                let change = tracker.add(tMs: Int64((t[i] * 1000).rounded()), face: face[i], yaw: yaw[i])
                guard let s = tracker.state else { continue }
                if let last = hs.last, last.value == s, t[i] - last.end <= 1 {
                    hs[hs.count - 1].end = t[i]
                } else {
                    let from = change.map { Double($0.tMs) / 1000 } ?? t[i]
                    if !hs.isEmpty, hs[hs.count - 1].end > from { hs[hs.count - 1].end = from }
                    hs.append(ReplayRun(start: from, end: t[i], value: s))
                }
            }
        }
        heads = hs

        // 要約（sessions.jsonl と同じ数え方：コマの間が1秒より空いた分は1秒で切る）
        var dur = 0.0, faceS = 0.0
        for i in 1..<max(n, 1) where t[i] > t[i - 1] {
            let dt = min(t[i] - t[i - 1], 1)
            dur += dt
            if face[i - 1] { faceS += dt }
        }
        durationS = dur
        faceRatio = dur > 0 ? faceS / dur : nil
        self.notes = notes
    }

    private static let noteNoStart = "記録し始めた時刻が無い普段は、目を細めるにまばたきが入ったまま使っています"

    /// 時刻 x の顔の絵の値（記録が無い・顔が読めないときは nil）
    func shape(at x: Double) -> [String: Double]? {
        guard let i = index(at: x), x - times[i] <= 1, readable[i] else { return nil }
        let keys = Self.shapeKeys
        var d: [String: Double] = [:]
        for (j, k) in keys.enumerated() { d[k] = Double(shapes[i * keys.count + j]) }
        return d
    }

    /// x 以前で一番新しいコマ
    func index(at x: Double) -> Int? {
        var lo = 0, hi = times.count - 1
        guard hi >= 0, x >= times[0] else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= x { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 撮る側が普段に数えるコマ（review.py の baseline_candidates）から、まばたき（と前後0.2秒）を外して、
    /// 目を細めるの普段を数え直す。返り値：(記録し始めた時刻, 記録し終えた時刻) → baseline 行の metrics と同じ形
    private static func squintWithoutBlinks(t: [Double], face: [Bool], yaw: [Double?], squint: [Double?], blink: [Double?],
                                            start0: Double) -> (Double, Double) -> [String: Any] {
        let n = t.count
        var valid = [Bool](repeating: false, count: n)
        var k = 0, prev: Double?
        var lo = 0, faceInWin = 0
        for i in 0..<n {
            k = prev == nil || t[i] - prev! > 1 ? 1 : k + 1
            prev = t[i]
            if face[i] { faceInWin += 1 }
            while t[lo] < t[i] - 1 { if face[lo] { faceInWin -= 1 }; lo += 1 }
            let readable = faceInWin * 2 >= (i - lo + 1)
            let facing = yaw[i].map { abs($0) < 35 } ?? false
            valid[i] = k % 3 == 0 && t[i] - start0 >= 5 && readable && face[i] && facing
        }
        let hits = (0..<n).filter { (blink[$0] ?? 0) >= DiffCriteria.blinkThreshold }.map { t[$0] }
        func blinked(_ x: Double) -> Bool {
            // hits は昇順。x に一番近いものだけ見る
            var a = 0, b = hits.count
            while a < b { let m = (a + b) / 2; if hits[m] < x { a = m + 1 } else { b = m } }
            let near = [a - 1, a].filter { $0 >= 0 && $0 < hits.count }.map { abs(hits[$0] - x) }
            return (near.min() ?? .infinity) <= DiffCriteria.blinkPadS + 1e-9
        }
        return { s0, s1 in
            var w = Welford()
            for i in 0..<n where t[i] >= s0 && t[i] <= s1 + 1e-6 && valid[i] && !blinked(t[i]) {
                if let x = squint[i] { w.add(x) }
            }
            var st: [String: Any] = ["n": w.n, "insufficient": w.n < 30]
            if w.n > 0 {
                st["mean"] = NSNumber(value: (w.mean * 10000).rounded() / 10000)
                st["std"] = NSNumber(value: (w.std * 10000).rounded() / 10000)
            }
            return st
        }
    }
}
