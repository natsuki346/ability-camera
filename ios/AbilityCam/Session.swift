import Foundation
import UIKit

/// 1回の記録（セッション）の要約を数える。記録に書いた行だけから数える（その場でも、あとから読み直しても同じ結果になる）
struct SessionStats {
    static let yawLimit = 35.0

    private(set) var firstMs: Int64?
    private(set) var lastMs: Int64?
    private(set) var frames = 0
    private(set) var durationS = 0.0
    private(set) var faceS = 0.0
    private(set) var facingS = 0.0          // 顔が映っていて |yaw| < 35°
    private(set) var segments = 0           // 「いつもとの違い」が始まった回数（change の行で、新しく出た指標の数）
    private(set) var marks = 0
    private(set) var scenes = 0             // 場面を選んだ回数（「なし」に戻したのは数えない）
    private var activeKeys: Set<String> = []
    private var prev: (t: Int64, face: Bool, facing: Bool)?

    /// コマとコマの間を、前のコマの状態として数える。1秒より空いた分（裏に回っていた間など）は1秒で切る
    mutating func addFrame(tMs: Int64, face: Bool, yawDeg: Double?) {
        see(tMs)
        frames += 1
        let facing = face && (yawDeg.map { abs($0) < Self.yawLimit } ?? false)
        if let p = prev, tMs > p.t {
            let dt = min(Double(tMs - p.t) / 1000, 1)
            durationS += dt
            if p.face { faceS += dt }
            if p.facing { facingS += dt }
        }
        prev = (tMs, face, facing)
    }

    mutating func addEvent(tMs: Int64, kind: String, value: [String]?, part: String? = nil) {
        see(tMs)
        switch kind {
        case "mark": marks += 1
        case "scene": if let v = value?.first, v != "なし" { scenes += 1 }
        case "change":
            // 声が出た（v1.7〜）は普段と比べた違いではないので、違いの数に入れない（sessions.py と同じ）
            let keys = Set((value ?? []).filter { !$0.hasPrefix(DiffTarget.voiceOnKey + ":") })
            segments += keys.subtracting(activeKeys).count
            activeKeys = keys
        case "baseline_restart":
            // 取り直した部分の違いだけを数え直す（v1.9.3〜。part: "face" / "voice"。無ければ両方。review.py の restart_times と同じ見分け方）
            activeKeys = Set(BaselinePart.keysAfterRestart(Array(activeKeys), part: BaselinePart.of(part)))
        default: break
        }
    }

    private mutating func see(_ t: Int64) {
        if firstMs == nil || t < firstMs! { firstMs = t }
        if lastMs == nil || t > lastMs! { lastMs = t }
    }

    func summary(file: String, startedMs: Int64?, recovered: Bool) -> SessionSummary {
        let r1 = { (x: Double) in (x * 10).rounded() / 10 }
        let r2 = { (x: Double) in (x * 100).rounded() / 100 }
        let start = startedMs ?? firstMs ?? 0
        let end = max(lastMs ?? start, start)
        return SessionSummary(
            file: file, tMs: end, startedMs: start, endedMs: end,
            durationS: r1(durationS), frames: frames,
            faceS: r1(faceS), faceRatio: durationS > 0 ? r2(faceS / durationS) : nil,
            facingS: r1(facingS), facingRatio: durationS > 0 ? r2(facingS / durationS) : nil,
            yawLimitDeg: Self.yawLimit,
            segments: segments, marks: marks, scenes: scenes,
            recovered: recovered,
            device: UIDevice.current.model, ios: UIDevice.current.systemVersion)
    }
}

/// sessions.jsonl の1行
struct SessionSummary: Codable, Identifiable {
    var type = "session_summary"
    var schema = "ability-cam.session.v1"
    let file: String                 // 1コマごとの値が入っている記録のファイル名
    let tMs: Int64
    let startedMs: Int64
    let endedMs: Int64
    let durationS: Double            // カメラが動いていた時間（コマの間が1秒より空いた分は数えない）
    let frames: Int
    let faceS: Double
    let faceRatio: Double?
    let facingS: Double
    let facingRatio: Double?
    let yawLimitDeg: Double
    let segments: Int                // アプリの「いつもとの違い」の区間の数
    let marks: Int
    let scenes: Int
    let recovered: Bool              // 要約を作る前に終了され、次に開いたときに整理した
    let device: String
    let ios: String

    var id: String { file }

    enum CodingKeys: String, CodingKey {
        case type, schema, file, frames, segments, marks, scenes, recovered, device, ios
        case tMs = "t_ms", startedMs = "started_ms", endedMs = "ended_ms", durationS = "duration_s"
        case faceS = "face_s", faceRatio = "face_ratio", facingS = "facing_s", facingRatio = "facing_ratio"
        case yawLimitDeg = "yaw_limit_deg"
    }
}

/// 「ファイル」アプリ > このiPhone内 > Ability Cam の sessions.jsonl と、記録のファイル
enum SessionStore {
    static let fileName = "sessions.jsonl"
    static let recordPrefix = "ability-cam-"
    private static let lock = NSLock()

    static var dir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func append(_ s: SessionSummary) throws {
        lock.lock(); defer { lock.unlock() }
        let url = dir.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: try enc.encode(s) + Data("\n".utf8))
    }

    /// 新しい順
    static func load() -> [SessionSummary] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return [] }
        let dec = JSONDecoder()
        var out: [String: SessionSummary] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let s = try? dec.decode(SessionSummary.self, from: Data(line)), s.type == "session_summary" {
                out[s.file] = s
            }
        }
        return out.values.sorted { $0.startedMs > $1.startedMs }
    }

    /// 要約のない記録のファイル（今のセッションのものは除く）を見つけて、読み直して要約する。重いので裏のスレッドで呼ぶ
    static func recoverMissing(except current: String?) -> Int {
        let done = Set(load().map(\.file))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var n = 0
        for f in files.sorted() where f.hasPrefix(recordPrefix) && f.hasSuffix(".jsonl") && f != current && !done.contains(f) {
            guard let s = summarize(file: f) else { continue }
            if (try? append(s)) != nil { n += 1 }
        }
        return n
    }

    /// 記録のファイルを1行ずつ読んで、その場と同じ数え方で要約する
    static func summarize(file: String) -> SessionSummary? {
        guard let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent(file)) else { return nil }
        defer { try? h.close() }
        let dec = JSONDecoder()
        var stats = SessionStats()
        var started: Int64?
        var buf = Data()
        func handle(_ line: Data) {
            guard let r = try? dec.decode(Line.self, from: line) else { return }
            if let s = r.startedAtMs { started = s }
            guard let t = r.tMs else { return }
            switch r.type {
            case "frame": stats.addFrame(tMs: t, face: r.face ?? false, yawDeg: r.yawDeg)
            case "event": stats.addEvent(tMs: t, kind: r.kind ?? "", value: r.value, part: r.part)
            default: break
            }
        }
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            buf.append(chunk)
            var from = buf.startIndex
            while let i = buf[from...].firstIndex(of: UInt8(ascii: "\n")) {
                handle(buf[from..<i])
                from = buf.index(after: i)
            }
            buf = Data(buf[from...])   // 読み切れなかった行の続きだけ残す
        }
        if !buf.isEmpty { handle(buf) }   // 途中で終了されて、最後の行に改行が無いとき（壊れていれば飛ばす）
        return stats.summary(file: file, startedMs: started, recovered: true)
    }

    /// 要約に要るところだけ読む
    private struct Line: Decodable {
        let type: String?
        let tMs: Int64?
        let startedAtMs: Int64?
        let face: Bool?
        let yawDeg: Double?
        let kind: String?
        let value: [String]?
        let part: String?       // baseline_restart：face / voice（v1.7〜・v1.9.2〜）

        enum CodingKeys: String, CodingKey {
            case type, face, kind, value, part, tMs = "t_ms", startedAtMs = "started_at_ms", yawDeg = "yaw_deg"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            tMs = try c.decodeIfPresent(Int64.self, forKey: .tMs)
            startedAtMs = try c.decodeIfPresent(Int64.self, forKey: .startedAtMs)
            face = try c.decodeIfPresent(Bool.self, forKey: .face)
            yawDeg = try c.decodeIfPresent(Double.self, forKey: .yawDeg)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            part = try? c.decodeIfPresent(String.self, forKey: .part)
            if let a = try? c.decodeIfPresent([String].self, forKey: .value) { value = a }
            else if let s = try? c.decodeIfPresent(String.self, forKey: .value) { value = [s] }
            else { value = nil }
        }
    }
}
