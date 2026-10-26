import Foundation
import UIKit

/// 映り方チェック：顔がどのくらい映っていたかを数えるだけ。1コマごとの値・表情の数値・顔の点は残さない
struct FramingCheck {
    static let binSeconds = 10.0
    static let yawLimit = 35.0

    let id = UUID().uuidString
    let startHost: CFTimeInterval      // CACurrentMediaTime
    let startedAt = Date()

    private(set) var endedAt: Date?
    private(set) var frames = 0
    private(set) var durationS = 0.0
    private(set) var faceS = 0.0
    private(set) var facingS = 0.0           // 顔が映っていて、|yaw| < 35°
    private(set) var longestNoFaceS = 0.0
    private var noFaceRunS = 0.0
    private var binTotal: [Double] = []
    private var binFace: [Double] = []
    private var meshLagMs: [Double] = []
    private var prev: (t: Double, face: Bool, facing: Bool)?

    init(startHost: CFTimeInterval) { self.startHost = startHost }

    /// 1コマごと。直前のコマから今のコマまでの間を、直前のコマの状態として数える
    mutating func add(captureT t: Double, face: Bool, yaw: Double?) {
        guard t >= startHost else { return }   // 始める前に撮られたコマ
        frames += 1
        let facing = face && (yaw.map { abs($0) < Self.yawLimit } ?? false)
        if let p = prev, t > p.t { account(from: p.t, dt: t - p.t, face: p.face, facing: p.facing) }
        prev = (t, face, facing)
    }

    mutating func addMeshLag(_ ms: Double) { meshLagMs.append(ms) }

    /// 終えるとき。最後のコマから今までを数える
    mutating func finish(atHost now: CFTimeInterval) {
        if let p = prev, now > p.t { account(from: p.t, dt: min(now - p.t, 1), face: p.face, facing: p.facing) }
        prev = nil
        endedAt = Date()
    }

    private mutating func account(from t: Double, dt: Double, face: Bool, facing: Bool) {
        durationS += dt
        if face { faceS += dt }
        if facing { facingS += dt }
        noFaceRunS = face ? 0 : noFaceRunS + dt
        longestNoFaceS = max(longestNoFaceS, noFaceRunS)
        let i = max(0, Int((t - startHost) / Self.binSeconds))
        while binTotal.count <= i { binTotal.append(0); binFace.append(0) }
        binTotal[i] += dt
        if face { binFace[i] += dt }
    }

    func summary(endedBy: String) -> FramingSummary {
        let r2 = { (x: Double) in (x * 100).rounded() / 100 }
        let r1 = { (x: Double) in (x * 10).rounded() / 10 }
        let sorted = meshLagMs.sorted()
        let median: Double? = sorted.isEmpty ? nil
            : sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let endedAt = endedAt ?? Date()
        return FramingSummary(
            id: id,
            tMs: Int64(endedAt.timeIntervalSince1970 * 1000),
            startedMs: Int64(startedAt.timeIntervalSince1970 * 1000),
            endedMs: Int64(endedAt.timeIntervalSince1970 * 1000),
            durationS: r1(durationS),
            faceS: r1(faceS),
            faceRatio: durationS > 0 ? r2(faceS / durationS) : nil,
            facingS: r1(facingS),
            facingRatio: durationS > 0 ? r2(facingS / durationS) : nil,
            yawLimitDeg: Self.yawLimit,
            longestNoFaceS: r1(longestNoFaceS),
            binS: Self.binSeconds,
            binFaceRatio: zip(binFace, binTotal).map { f, t in t > 0 ? r2(f / t) : nil },
            fpsMean: durationS > 0 ? r1(Double(frames) / durationS) : nil,
            meshLagMsMedian: median.map { $0.rounded() },
            endedBy: endedBy,
            device: UIDevice.current.model,
            ios: UIDevice.current.systemVersion)
    }
}

/// framing-checks.jsonl の1行。要約だけ
struct FramingSummary: Codable {
    var type = "framing_check"
    var schema = "ability-cam.framing.v1"
    let id: String
    let tMs: Int64
    let startedMs: Int64
    let endedMs: Int64
    let durationS: Double
    let faceS: Double
    let faceRatio: Double?
    let facingS: Double                // 顔が映っていて |yaw| < yawLimitDeg だった時間
    let facingRatio: Double?
    let yawLimitDeg: Double
    let longestNoFaceS: Double
    let binS: Double
    let binFaceRatio: [Double?]        // 10秒ごとの、顔が映っていた割合（0〜1）
    let fpsMean: Double?
    let meshLagMsMedian: Double?       // 撮影→網目の遅れの中央値（網目を出していないときは nil）
    let endedBy: String                // button / background
    let device: String
    let ios: String

    enum CodingKeys: String, CodingKey {
        case type, schema, id, device, ios
        case tMs = "t_ms", startedMs = "started_ms", endedMs = "ended_ms", durationS = "duration_s"
        case faceS = "face_s", faceRatio = "face_ratio", facingS = "facing_s", facingRatio = "facing_ratio"
        case yawLimitDeg = "yaw_limit_deg", longestNoFaceS = "longest_no_face_s"
        case binS = "bin_s", binFaceRatio = "bin_face_ratio", fpsMean = "fps_mean"
        case meshLagMsMedian = "mesh_lag_ms_median", endedBy = "ended_by"
    }
}

/// あとから付けるメモ。要約の行は書き換えず、別の行として足す（同じ id の一番新しいものを使う）
struct FramingNote: Codable {
    var type = "framing_note"
    let id: String
    let tMs: Int64
    let note: String
    enum CodingKeys: String, CodingKey { case type, id, note, tMs = "t_ms" }
}

/// 「ファイル」アプリ > このiPhone内 > Ability Cam > framing-checks.jsonl に追記する
enum FramingLog {
    static let fileName = "framing-checks.jsonl"

    static func append<T: Encodable>(_ record: T) throws {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let line = try enc.encode(record) + Data("\n".utf8)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    }
}
