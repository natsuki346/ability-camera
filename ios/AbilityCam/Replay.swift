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
    let coChanges: [CoChange]                    // 重なりのできごと（v1.12〜。画面には出さず、check_app.py で振り返りレポートと比べる）
    let scenes: [ReplayRun<String>]
    let marks: [ReplayEvent]
    let heads: [ReplayRun<HeadState>]            // 撮る側と同じ決まりで、コマから数え直した顔の向き
    let noBaseline: [ReplayRun<Bool>]            // 普段が無く、比べていない時間
    let events: [ReplayEvent]                    // 時刻の順

    // 要約
    let durationS: Double
    let faceRatio: Double?
    let selfVoiceS: Double                       // 本人の声の時間（v1.6〜）
    let otherVoiceS: Double                      // 本人の声と言えない声の時間
    /// 声が出ていたコマの、撮る側と同じ決まりで決め直した本人の声の判定（v1.9〜。記録の voice_self ではなく決め直したもの。check_app.py が比べる）
    let voiceDetail: [(t: Double, voiceSelf: Bool, reason: String?, corr: Double?, corrOther: Double?, match: String?)]
    /// いつもとの違いの数（声が出たは普段と比べたものではないので入れない。sessions.jsonl の segments と同じ）
    var diffCount: Int { segments.filter { $0.target != .voiceOn }.count }
    var voiceOnCount: Int { segments.filter { $0.target == .voiceOn }.count }   // 声が出た回数（v1.7〜）
    var voiceOnS: Double { segments.filter { $0.target == .voiceOn }.reduce(0) { $0 + $1.seconds } }
    var markCount: Int { marks.count }
    let notes: [String]
    /// 家族の印（v1.13〜：詳しい中身をあとから付ける・変えるため）
    struct MarkItem: Identifiable { let tMs: Int64; let value: String; let detail: String?; let detailAt: Int64?; let by: String?; var id: Int64 { tMs } }
    let markItems: [MarkItem]
    /// 詳しい中身の選択肢（記録のヘッダの mark_details。無い古い記録は初めの選択肢）
    let detailOptions: MarkDetails
    /// 読んだファイル（あとから詳しい中身を書くとき。見る側で開いたものは、選んだファイルそのもの）
    var sourceURL: URL?
    /// 試すモードの指示（v1.18〜、記録の event kind: "cue"）と、その人の最大（kind: "calibration" の max。最後のもの）
    let cues: [Cue]
    let calibMax: [Metric: Double]?
    /// keepZ のとき：判定したコマごとの z と、顔のあるコマの生の値（試すモードの結果・DiffCheck --cues 用）
    let zLog: [(t: Double, z: [Metric: Double])]
    let rawFace: [(t: Double, v: [Metric: Double])]
    /// 撮る側の change の行（v1.20〜、試すモードの「いつもとの違い」を撮る側と同じに数えるため）
    let changeRows: [(t: Double, keys: [String])]

    /// 標準偏差の下限の決め方（v1.18〜）。recorded：記録の baseline 行の std_floor（無ければ指標の下限）。defaults：いつも指標の下限。
    /// calibrated：その人の最大から、行ごとに決め直した下限（Calibration.floors。試すモードの「下限を変えた後」）
    enum FloorMode { case recorded, defaults, calibrated([Metric: Double]) }

    enum LoadError: LocalizedError {
        case empty
        var errorDescription: String? { "記録のコマがありません（Ability Cam の記録のファイルか確かめてください）" }
    }

    /// 重いので裏のスレッドで呼ぶ
    init(data: Data, name: String, floorMode: FloorMode = .recorded, keepZ: Bool = false) throws {
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
        // v1.6.1 までの記録（direction_version が無い）は、映像で見た右・左なので入れ替えて、本人から見た右・左にする（review.py と同じ）
        let flip: Double = FaceDirection.version(of: header) < 2 ? -1 : 1

        // コマを読む
        let n = frames.count
        var t = [Double](repeating: 0, count: n)
        var face = [Bool](repeating: false, count: n)
        var yaw = [Double?](repeating: nil, count: n)
        var bsList = [[String: Double]](repeating: [:], count: n)
        var rms = [Double?](repeating: nil, count: n), f0 = [Double?](repeating: nil, count: n)
        var pitch = [Double?](repeating: nil, count: n), roll = [Double?](repeating: nil, count: n)
        var recordedVoiceSelf = [Bool??](repeating: nil, count: n)   // 記録の voice_self（v1.6〜。キーが無い古い記録は nil）
        var otherJaw = [Double?](repeating: nil, count: n)           // もう1つの顔の jawOpen（v1.9〜）
        var geoList = [[String: Double]?](repeating: nil, count: n)  // 顔の点の距離（v1.15〜）
        for (i, o) in frames.enumerated() {
            if let v = o["voice_self"] { recordedVoiceSelf[i] = .some(v as? Bool) }
            t[i] = ms(o)!
            yaw[i] = (o["yaw_deg"] as? NSNumber).map { $0.doubleValue * flip }
            pitch[i] = (o["pitch_deg"] as? NSNumber)?.doubleValue
            roll[i] = (o["roll_deg"] as? NSNumber).map { $0.doubleValue * flip }
            rms[i] = (o["rms_db"] as? NSNumber)?.doubleValue
            otherJaw[i] = (o["other_jaw_open"] as? NSNumber)?.doubleValue
            if let g = o["geo"] as? [String: Any] { geoList[i] = g.compactMapValues { ($0 as? NSNumber)?.doubleValue } }
            // 声の高さの範囲の外（v1.6.1 までの記録の 800Hz のような取り違え）は使わない（review.py の F0_RANGE と同じ）
            f0[i] = ((o["f0_hz"] as? NSNumber)?.doubleValue).flatMap {
                $0 >= Double(PitchCriteria.minHz) && $0 <= Double(PitchCriteria.maxHz) ? $0 : nil }
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
        var bItems: [(t: Double, stats: [Metric: DiffEngine.Stat]?, part: BaselinePart, yaw: Double?, metricYaw: [Metric: Double])] = []
        for b in baselines {
            // 撮る側が比べるのに使わなかった行（v1.2〜の compared: false）は使わない（振り返りレポートと同じ）
            guard let bt = ms(b), (b["compared"] as? Bool) != false else { continue }
            let metrics = b["metrics"] as? [String: [String: Any]] ?? [:]
            var stats: [Metric: DiffEngine.Stat] = [:]
            // 標準偏差の下限（v1.18〜）
            let recFloor = (b["std_floor"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            var floors: [Metric: Double] = [:]
            switch floorMode {
            case .recorded: for m in Metric.allCases { if let f = recFloor[m.rawValue] { floors[m] = f } }
            case .defaults: break
            case .calibrated(let mx):
                floors = Calibration.floors(ref: { m in
                    guard let st = metrics[m.rawValue], (st["insufficient"] as? Bool) != true else { return nil }
                    return ((st["median"] as? NSNumber) ?? (st["mean"] as? NSNumber))?.doubleValue
                }, max: mx)
            }
            for m in Metric.allCases {
                var st = metrics[m.rawValue] ?? [:]
                if m == .eyeSquint, (b["blink_masked"] as? Bool) != true {
                    if let s0 = ms(b, "started_ms") { st = recount(s0, bt) }
                    else if !notes.contains(Self.noteNoStart) { notes.append(Self.noteNoStart) }
                }
                if let s = DiffEngine.stat(for: m, mean: (st["mean"] as? NSNumber)?.doubleValue,
                                           std: (st["std"] as? NSNumber)?.doubleValue,
                                           insufficient: (st["insufficient"] as? Bool) ?? true, floor: floors[m]) {
                    stats[m] = s
                }
            }
            // 表情の普段の yaw（v1.16〜：中央値、無ければ平均。記録の左右の向きに合わせる）
            let yst = (b["pose"] as? [String: [String: Any]])?["yaw_deg"]
            let byaw = (yst?["insufficient"] as? Bool) == true ? nil
                : ((yst?["median"] as? NSNumber)?.doubleValue ?? (yst?["mean"] as? NSNumber)?.doubleValue).map { $0 * flip }
            // 今日の普段から足した指標（from_today）は、今日の普段の yaw と比べる（v1.17〜、from_today_yaw_deg）
            var my: [Metric: Double] = [:]
            if let ty = (b["from_today_yaw_deg"] as? NSNumber)?.doubleValue {
                for k in b["from_today"] as? [String] ?? [] { if let m = Metric(rawValue: k) { my[m] = ty * flip } }
            }
            bItems.append((bt, stats, BaselinePart.of(b["part"] as? String), byaw, my))
        }
        // カメラを変えたとき・表情だけの取り直し（part: "face"、v1.7〜）は表情の普段だけ消す（声の普段は続ける。review.py の restart_times と同じ）
        for e in evs where e["kind"] as? String == "baseline_restart" {
            // part: "voice"（声だけ取り直した、v1.9.2〜）は声の普段だけ消す
            bItems.append((ms(e)!, nil, BaselinePart.of(e["part"] as? String), nil, [:]))
        }
        bItems.sort { $0.t < $1.t }
        if baselines.isEmpty { notes.append("この記録には普段（baseline 行）が無いので、いつもとの違いは出せません") }

        // いつもとの違い：撮る側と同じ決まりで、コマを順に流す
        var engine = DiffEngine()
        if keepZ { engine.zLog = [] }
        var raws: [(t: Double, v: [Metric: Double])] = []
        var voiceTracker = VoiceSelfTracker()
        // 保存した声の普段の行（source: saved、声を含む行）の時刻と f0 の平均・標準偏差（データ不足なら使わない）
        // 中央値の無い行（v1.9 までに保存した声の普段）は使わない（review.py の pitch_ranges と同じ）
        // 声も取り直したとき（baseline_restart の part が face でないもの）は、範囲を外す（median が nil、v1.9.3〜）
        var pitchRanges: [(t: Double, median: Double?, iqr: Double?)] = baselines.compactMap { b in
            guard (b["source"] as? String) == "saved", BaselinePart.of(b["part"] as? String) != .face, let bt = ms(b),
                  let st = (b["metrics"] as? [String: [String: Any]])?[Metric.f0Hz.rawValue],
                  (st["insufficient"] as? Bool) != true, let m = (st["median"] as? NSNumber)?.doubleValue else { return nil }
            return (bt, m, (st["iqr"] as? NSNumber)?.doubleValue ?? 0)
        }
        for e in evs where e["kind"] as? String == "baseline_restart" && BaselinePart.of(e["part"] as? String) != .face {
            pitchRanges.append((ms(e)!, nil, nil))
        }
        // 声の普段を集め終えた・保存し直したときに、撮る側が使い始めた範囲（v1.9.4〜、kind: "voice_pitch_range"。median が無ければ外した）
        for e in evs where e["kind"] as? String == "voice_pitch_range" {
            pitchRanges.append((ms(e)!, (e["median"] as? NSNumber)?.doubleValue, (e["iqr"] as? NSNumber)?.doubleValue ?? 0))
        }
        pitchRanges.sort { $0.t < $1.t }
        var pi = 0
        var detail: [(t: Double, voiceSelf: Bool, reason: String?, corr: Double?, corrOther: Double?, match: String?)] = []
        var selfS = 0.0, otherS = 0.0
        var bi = 0
        var noBase: [ReplayRun<Bool>] = []
        var hasBase = false
        var segs: [DiffSegment] = []
        for i in 0..<n {
            while bi < bItems.count, bItems[bi].t <= t[i] {   // その時刻のコマから使う（review.py の baseline_index）
                engine.setBaseline(bItems[bi].stats, part: bItems[bi].part, yaw: bItems[bi].yaw, metricYaw: bItems[bi].metricYaw)
                if bItems[bi].part != .voice { hasBase = bItems[bi].stats != nil }   // 斜線は表情の普段が無い時間
                bi += 1
            }
            if !hasBase {
                if let last = noBase.last, abs(last.end - (i > 0 ? t[i - 1] : t[i])) < 1e-9 { noBase[noBase.count - 1].end = t[i] }
                else { noBase.append(ReplayRun(start: t[i], end: t[i], value: true)) }
            }
            var fv: [Metric: Double] = [:]
            if face[i] {   // 表情のまとまり（v1.12〜）と顔の点の距離（v1.15〜）も（重なりのできごとに使う）
                fv = Metric.faceValues { bsList[i][$0] ?? 0 }.merging(Metric.geometryValues(geoList[i])) { a, _ in a }
            }
            if keepZ && !fv.isEmpty { raws.append((t[i], fv)) }
            var voice: [Metric: Double] = [:]
            if let r = rms[i] { voice[.rmsDb] = r }
            if let f = f0[i] { voice[.f0Hz] = f }
            // 本人の声か：記録に書いてあればそれを、無い古い記録は撮る側と同じ決まりで決め直す（review.py と同じ）
            while pi < pitchRanges.count, pitchRanges[pi].t <= t[i] {   // 保存した声の普段の範囲（v1.9〜、review.py の pitch_ranges と同じ）
                voiceTracker.setPitchRange(median: pitchRanges[pi].median, iqr: pitchRanges[pi].iqr, fromT: pitchRanges[pi].t)
                pi += 1
            }
            let computed = voiceTracker.add(t: t[i], face: face[i], yaw: yaw[i], bs: bsList[i], rms: rms[i], f0: f0[i], otherJaw: otherJaw[i])
            if let c = computed {
                detail.append((t[i], c, voiceTracker.reason?.rawValue, voiceTracker.corr, voiceTracker.corrOther, voiceTracker.match?.rawValue))
            }
            let vs = recordedVoiceSelf[i] ?? computed
            if vs == true { selfS += i + 1 < n ? min(t[i + 1] - t[i], 1) : 0 }
            if vs == false { otherS += i + 1 < n ? min(t[i + 1] - t[i], 1) : 0 }
            engine.add(DiffInput(t: t[i], face: face[i], yaw: yaw[i], faceValues: fv, blink: blink[i], voice: voice, voiceSelf: vs))
            segs += engine.finished
            engine.finished = []
        }
        engine.flush()
        segs += engine.finished
        segments = segs.filter(\.shown).sorted { $0.startT < $1.startT }
        coChanges = engine.coDet.finished
        zLog = engine.zLog ?? []
        rawFace = raws
        changeRows = evs.compactMap { e in
            guard e["kind"] as? String == "change", let t = ms(e) else { return nil }
            return (t, e["value"] as? [String] ?? [])
        }
        // 試すモード（v1.18〜）
        cues = evs.compactMap { e in
            guard e["kind"] as? String == "cue", let k = CueKind(rawValue: e["value"] as? String ?? ""),
                  let s = ms(e, "start_ms"), let en = ms(e, "end_ms") else { return nil }
            return Cue(kind: k, start: s, end: en)
        }
        calibMax = evs.last { $0["kind"] as? String == "calibration" }.flatMap { e in
            (e["max"] as? [String: Any]).map { d in
                Dictionary(uniqueKeysWithValues: d.compactMap { k, v in Metric(rawValue: k).flatMap { m in (v as? NSNumber).map { (m, $0.doubleValue) } } })
            }
        }
        selfVoiceS = selfS; otherVoiceS = otherS
        voiceDetail = detail
        noBaseline = noBase

        // 場面・家族の印・顔の向きの記録
        var sc: [ReplayRun<String>] = []
        var mk: [ReplayEvent] = []
        var list: [ReplayEvent] = []
        var items: [MarkItem] = []
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
                let detail = e["detail"] as? String   // 家族の印の詳しい中身（v1.13〜、家族の言葉）
                let ev = ReplayEvent(t: et, kind: .mark, text: "家族の印：\(value ?? "")\(detail.map { "・\($0)" } ?? "")\(by)")
                mk.append(ev); list.append(ev)
                if let tm = (e["t_ms"] as? NSNumber)?.int64Value {
                    items.append(MarkItem(tMs: tm, value: value ?? "", detail: detail, detailAt: (e["detail_at"] as? NSNumber)?.int64Value,
                                          by: (e["source"] as? String) == "viewer" ? (e["by"] as? String ?? "見る側") : nil))
                }
            case "head_turn":
                let v = flip < 0 ? FaceDirection.swapSides(value ?? "") : (value ?? "")
                list.append(ReplayEvent(t: et, kind: .head, text: "顔の向き：\(v)（\(FaceDirection.note)）"))
            default: break
            }
        }
        for s in segments {
            list.append(ReplayEvent(t: s.startT, kind: .diff, text: "\(s.message)（\(Int(s.seconds.rounded()))秒）"))
        }
        scenes = sc; marks = mk; markItems = items
        detailOptions = MarkDetails(header: header["mark_details"]) ?? .initial
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
