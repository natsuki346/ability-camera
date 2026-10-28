import Foundation
import UIKit

/// 1コマ = 1行の JSONL。「ファイル」アプリ > このiPhone内 > Ability Cam に保存される。
struct FrameRecord: Encodable {
    let type = "frame"
    let tMs: Int64              // 撮影時刻（epoch ms）。手首の記録と並べるときの時刻
    let face: Bool
    let bs: [String: Float]?    // 表情の数値 52種（0〜1）
    let pts: [[Float]]?
    let rmsDb: Float?
    let f0Hz: Float?
    let procMs: Double
    let latMs: Double
    var yawDeg: Double?         // 顔の向き（度）。映像で見て右・上・右へ傾く が +
    var pitchDeg: Double?
    var rollDeg: Double?
    var faceCx: Double?         // 本人として使った顔の枠：中心 x・y と幅（0〜1、v1.2〜）
    var faceCy: Double?
    var faceW: Double?
    var voiceSelf = Nullable<Bool>(nil)   // 本人の声か（v1.6〜）：true / false（本人の声と言えない）/ null（声が出ていない）。いつも書く

    enum CodingKeys: String, CodingKey {
        case type, tMs = "t_ms", face, bs, pts, rmsDb = "rms_db", f0Hz = "f0_hz", procMs = "proc_ms", latMs = "lat_ms"
        case yawDeg = "yaw_deg", pitchDeg = "pitch_deg", rollDeg = "roll_deg", faceCx = "face_cx", faceCy = "face_cy", faceW = "face_w"
        case voiceSelf = "voice_self"
    }
}

/// nil のときも null と書く値（書いていない古い記録と見分けるため）
struct Nullable<T: Encodable>: Encodable {
    let value: T?
    init(_ v: T?) { value = v }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value { try c.encode(value) } else { try c.encodeNil() }
    }
}

/// 場面・家族の印・違いの組み合わせの変化。t_ms は押した（変わった）瞬間
struct EventRecord: Encodable {
    enum Value: Encodable {
        case text(String), list([String])
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .list(let a): try c.encode(a)
            }
        }
    }

    let type = "event"
    let tMs: Int64
    let kind: String            // scene / mark / change / baseline_restart / head_turn / camera
    let value: Value?
    var faceReadable: Bool?     // change のときだけ
    var source: String?         // 見る側で押したときは "viewer"（撮る側で押したときは書かない）
    var by: String?             // 見る側の端末の名前
    var clockCorrected: Bool?   // 見る側：押した瞬間の時刻を、2台の時計のずれを直して記録したか
    var head: String?           // head_turn：新しい向き（front / right / left / hidden / oblique）
    var from: String?           // head_turn：前の向き
    var yawDeg: Double?         // head_turn：なり始めたときの yaw（見えない：見えなくなる直前の yaw）
    var camera: String?         // camera：切り替えたカメラ（wide / ultra_wide / front）
    var count: Int?             // faces：映っている顔の数（0.5秒続いたもの）。faces_limit：探す顔の数
    var baseline: String?       // change：どちらの普段で比べたか（today / saved、v1.2〜）
    var personId: String?       // person：選んだ人の id（名前は書かない）
    var savedCamera: String?    // saved_baseline_skipped：保存した普段のカメラ
    var mirrorCorrected: Bool?  // camera：解析に渡す映像が鏡のようになっていて、記録の値（左右の表情・yaw・roll・顔の枠）を背面と同じ意味に直した（v1.6.1〜）
    var orientationVersion: Int? // camera：解析に渡す映像の向きの決め方（camera_orientation_version、v1.6.1〜は 2）

    enum CodingKeys: String, CodingKey {
        case type, tMs = "t_ms", kind, value, faceReadable = "face_readable", source, by
        case clockCorrected = "clock_corrected", head, from, yawDeg = "yaw_deg", camera, count, baseline, personId = "person_id", savedCamera = "saved_camera", mirrorCorrected = "mirror_corrected", orientationVersion = "camera_orientation_version"
    }
}

/// 普段（最初の30秒／60秒。撮る側の設定）の各指標の n / mean / std
struct BaselineRecord: Encodable {
    struct Stat: Codable, Equatable {
        let n: Int
        let mean: Double?
        let std: Double?
        let insufficient: Bool  // サンプルが足りず、比べるのに使わない
    }

    let type = "baseline"
    let tMs: Int64              // 記録し終えた時刻（保存した普段：使い始めた時刻）
    let startedMs: Int64?       // 記録し始めた時刻（保存した普段には無い）
    let wallS: Double?          // 普段を集めるのにかかった実際の時間
    let validS: Double?         // そのうち数えた時間（顔が読めていて |yaw| < 35°、開いてから5秒より後）
    let yawLimitDeg: Double
    let warmupS: Double         // 開いてからこの秒数は数えない（ポケットに入れる間）
    let minN: Int
    let targetS: Double         // 普段の長さ（数えた時間がこの秒数になったら記録し終える。撮る側の設定、v0.9〜）
    let blinkMasked: Bool       // 目を細めるの普段から、まばたき（と前後0.2秒）のコマを外した（v1.0〜。振り返りレポートは数え直さない）
    let metrics: [String: Stat]
    var source = "today"        // today：今日の30秒 / saved：人ごとに保存した普段（v1.2〜）
    var compared = true         // この普段で「いつもとの違い」を比べたか（false：記録しただけ）
    var savedMs: Int64?         // saved：保存した日時
    var camera: String?         // saved：保存したときのカメラ
    var faceBox: FaceBoxStats?  // 普段の間の顔の位置と大きさ（v1.2〜）
    var part: String?           // face：表情の普段 / voice：声の普段（v1.6〜。無い行は両方）
    var voiceValidS: Double?    // voice：声の普段に数えた本人の声の秒数（v1.6〜）
    var eyesClosedS: Double?    // 普段の間に目を閉じていた秒数（v1.4〜。目を閉じているの決まりで、数えたコマから。保存した普段には無い）

    enum CodingKeys: String, CodingKey {
        case source, compared, savedMs = "saved_ms", camera, faceBox = "face_box", eyesClosedS = "eyes_closed_s", part, voiceValidS = "voice_valid_s"
        case type, tMs = "t_ms", startedMs = "started_ms", wallS = "wall_s", validS = "valid_s"
        case yawLimitDeg = "yaw_limit_deg", warmupS = "warmup_s", minN = "min_n", targetS = "target_s", blinkMasked = "blink_masked", metrics
    }
}

final class SessionLogger {
    private let queue = DispatchQueue(label: "logger")
    private var handle: FileHandle?
    private let encoder = JSONEncoder()
    private(set) var fileName: String?
    private var startedMs = Int64.max   // queue の上でだけ触る
    private var stats = SessionStats()  // queue の上でだけ触る。書いた行から要約を数える

    func start(camera: CameraLens, personId: String?, mirrored: Bool = false) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "ability-cam-\(f.string(from: Date())).jsonl"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        fileName = name

        let header: [String: Any] = [
            "schema": "ability-cam.ios.v0.2",
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "started_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "device": UIDevice.current.model,
            "ios": UIDevice.current.systemVersion,
            // 使ったカメラ。超広角は画角の端で顔が歪み、表情の数値が変わることがある
            "camera": camera.rawValue,
            "camera_label": camera.label,
            // 映像の向きの決め方（v1.6.1〜は 2：向きを組み替えのあとに決め、前面は RotationCoordinator の角度。無い記録は 1）。
            // v1.5〜v1.6 の前面の記録（このキーが無い）は、解析に渡した映像の向きが合っていなかった
            "camera_orientation_version": CameraManager.orientationVersion,
            // 解析に渡す映像が鏡のようになっていて、記録の値（左右の表情・yaw・roll・顔の枠・鍵となる点）を背面と同じ意味に直した
            "mirror_corrected": mirrored,
            // 声の高さ（f0）の求め方（v1.6.2〜は 2：-60dBFS 以上の音で、70〜500Hz、正規化した自己相関の山 0.6 以上、2倍・半分の取り違えを防ぐ。
            // 無い記録は 1：-40dBFS 以上、70〜1000Hz で、小さい声ではほとんど取れず、800Hz のような取り違えが混ざる）
            "f0_version": PitchCriteria.version,
            "f0_floor_db": Double(PitchCriteria.floorDb),
            "f0_range_hz": [Double(PitchCriteria.minHz), Double(PitchCriteria.maxHz)],
            "f0_clarity_min": Double(PitchCriteria.clarityMin),
            // 人の id（名前は書かない。v1.2〜）
            "person_id": personId ?? NSNull(),
            "note": "type=frame|baseline|event / t_ms=撮影時刻・イベントの時刻(epoch ms) / bs=表情の数値52種(0-1) / yaw_deg,pitch_deg,roll_deg=顔の向き(映像で見て右・上・右へ傾くが+) / pts=鍵となる顔の点[x,y,z] / proc_ms=解析時間 / lat_ms=撮影→結果 / camera=使ったカメラ(wide=広角, ultra_wide=超広角, front=前面・自分で試す用。超広角は画角の端で顔が歪み表情の数値が変わることがある) / mirror_corrected=解析の映像が鏡で、記録の値を背面と同じ意味に直した / camera_orientation_version=映像の向きの決め方(2=v1.6.1〜) / f0_version=声の高さの求め方(2=v1.6.2〜、f0_floor_db 以上の音で f0_range_hz の範囲)"
        ]
        let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let ms = header["started_at_ms"] as! Int64
        queue.async {
            self.startedMs = ms
            self.stats = SessionStats()
            self.handle?.write(data + Data("\n".utf8))
        }
    }

    func write<T: Encodable>(_ record: T) {
        queue.async {
            guard let h = self.handle, let d = try? self.encoder.encode(record) else { return }
            h.write(d + Data("\n".utf8))
            self.count(record)
        }
    }

    private func count<T>(_ record: T) {
        if let f = record as? FrameRecord {
            stats.addFrame(tMs: f.tMs, face: f.face, yawDeg: f.yawDeg)
        } else if let e = record as? EventRecord {
            let v: [String]?
            switch e.value {
            case .text(let s): v = [s]
            case .list(let a): v = a
            case nil: v = nil
            }
            stats.addEvent(tMs: e.tMs, kind: e.kind, value: v)
        }
    }

    /// 書いた分を端末に書き出す（このあと終了されても、次に開いたときに読み直せるように）
    func flush() { queue.async { try? self.handle?.synchronize() } }

    /// ファイルを閉じて、このセッションの要約を返す
    func finish() -> SessionSummary? {
        queue.sync {
            guard let h = handle, let name = fileName else { return nil }
            try? h.close()
            handle = nil
            let s = stats.summary(file: name, startedMs: startedMs == .max ? nil : startedMs, recovered: false)
            startedMs = .max
            stats = SessionStats()
            return s
        }
    }

    /// 記録を始める前に撮られたコマは書かない
    func write<T: Encodable>(_ record: T, notBefore tMs: Int64) {
        queue.async {
            guard tMs >= self.startedMs else { return }
            guard let h = self.handle, let d = try? self.encoder.encode(record) else { return }
            h.write(d + Data("\n".utf8))
            self.count(record)
        }
    }

}
