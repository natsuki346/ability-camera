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
    var yawDeg: Double?         // 顔の向き（度）。本人から見て右・上・右へ傾く が +（v1.7.1〜、direction_version 2。それまでは映像で見て右）
    var pitchDeg: Double?
    var rollDeg: Double?
    var faceCx: Double?         // 本人として使った顔の枠：中心 x・y と幅（0〜1、v1.2〜）
    var faceCy: Double?
    var faceW: Double?
    var voiceSelf = Nullable<Bool>(nil)   // 本人の声か（v1.6〜）：true / false（本人の声と言えない）/ null（声が出ていない）。いつも書く
    // v1.9〜（声が出ているコマだけ）
    var voiceSelfReason: String?  // 本人の声と言えなかった理由：pitch / no_face / no_mouth / timing（本人の声のときは書かない）
    var voiceCorr: Double?        // 本人として選んだ顔の jawOpen と rms_db の相関（直近1秒、0.01 に丸める）
    var voiceCorrOther: Double?   // もう1つの顔の相関（2つ映っているとき）
    var voiceMatch: String?       // どの顔の口と声のタイミングが合っていたか：self / other / none（判定は本人として選んだ顔で）
    var otherJawOpen: Double?     // もう1つの顔の jawOpen（2つ映っているとき。声が出ていなくても書く）

    enum CodingKeys: String, CodingKey {
        case type, tMs = "t_ms", face, bs, pts, rmsDb = "rms_db", f0Hz = "f0_hz", procMs = "proc_ms", latMs = "lat_ms"
        case yawDeg = "yaw_deg", pitchDeg = "pitch_deg", rollDeg = "roll_deg", faceCx = "face_cx", faceCy = "face_cy", faceW = "face_w"
        case voiceSelf = "voice_self", voiceSelfReason = "voice_self_reason", voiceCorr = "voice_corr", voiceCorrOther = "voice_corr_other"
        case voiceMatch = "voice_match", otherJawOpen = "other_jaw_open"
    }
}

/// 映像のコマごと（約33ms）の声の大きさ（v1.9.1〜）。音の塊（約0.1秒）ごとに1行。音声そのものではない
struct AudioRecord: Encodable {
    let type = "audio"
    let tMs: Int64              // 塊の始まりの時刻（epoch ms）
    let blockMs: Double         // 1つの区切りの長さ（ms、約33.3）
    let rmsDb: [Double]         // 区切りごとの声の大きさ（dBFS）
    enum CodingKeys: String, CodingKey { case type, tMs = "t_ms", blockMs = "block_ms", rmsDb = "rms_db" }
}

/// 話者の区別（v1.10〜）：声が出ている間 0.5秒ごとに1行。声の特徴の数値（埋め込み）は書かない
struct SpeakerRecord: Encodable {
    let type = "speaker"
    let tMs: Int64              // 使った声のまとまりの終わりの時刻（epoch ms）
    let windowMs: Int           // 使った声の長さ（ms。1500 より短いものも書く）
    let scores: [String: Double]   // 声を登録した人（id）ごとの似ている度合い（コサイン類似度、-1〜1）。登録した人がいなければ空
    let calcMs: Double          // 計算にかかった時間
    let model: String
    let f0Ratio: Double?        // そのまとまりで、声が出ていた音の塊のうち f0 が取れていた割合（v1.10.2〜、0.01 に丸める）
    let fbankMs: Double         // calc_ms の内訳：fbank（v1.10.3〜）
    let predictMs: Double       // calc_ms の内訳：Core ML の prediction
    let waitMs: Double          // 声のまとまりが決まってから計算を始めるまで（キューの待ち）
    /// 声紋で本人の声か（v1.10.5〜）：選んでいる人の似ている度合いが speaker_self_threshold 以上なら true、未満なら false、選んでいる人の登録が無ければ null。
    /// 判定（voice_self）・画面には使わない（「本人以外の声」だけは、登録があるときこれで決める）。window_ms が 1500 未満の行は似ている度合いが下がる
    let selfBySpeaker: Nullable<Bool>
    /// 声紋で本人の声か・比べる決め方（v1.11〜）：選んでいる人の似ている度合いが speaker_rel_min_score 以上で、ほかに登録した人のいちばん高い似ている度合いより
    /// speaker_rel_margin 以上高ければ true、そうでなければ false。ほかに登録した人がいなければ self_by_speaker と同じ。選んでいる人の登録が無ければ null。
    /// 「本人以外の声」はこれで決める（判定の voice_self には使わない）
    let selfBySpeakerRel: Nullable<Bool>
    enum CodingKeys: String, CodingKey { case type, tMs = "t_ms", windowMs = "window_ms", scores, calcMs = "calc_ms", model, f0Ratio = "f0_ratio",
        fbankMs = "fbank_ms", predictMs = "predict_ms", waitMs = "wait_ms", selfBySpeaker = "self_by_speaker", selfBySpeakerRel = "self_by_speaker_rel" }
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
    var median: Double?         // voice_pitch_range：声の高さの範囲に使う中央値（Hz）。無ければ範囲を外した（v1.9.4〜）
    var iqr: Double?            // voice_pitch_range：その四分位範囲（Hz）
    var part: String?           // baseline_restart：face＝表情の普段だけ取り直した（カメラを変えたとき、v1.7〜。声の普段は続ける）。無ければ両方
    var collect: String?        // speaker_enroll：何を集めるか（voice_self＝本人の声とされた時間だけ / voiced＝声が出ている時間すべて、v1.10.1〜）
    var validS: Double?         // speaker_enroll_progress：たまった声の秒数（v1.10.1〜）
    var score: Double?          // speaker_enroll_progress：その時点までの登録（平均、最新の声を足す前）と最新の声との似ている度合い
    // speaker_enroll_progress（v1.10.3〜、本人を登録しているとき。この登録を始めてから）：計算した声の秒数と、数えなかった理由ごとの秒数
    // （v1.10.2 の skipped_no_f0_s は no_f0_s に替えた）
    var computedS: Double?
    var notSelfS: Double?       // pitch 以外の理由の voice_self: false があった・pitch の false だけで true が無い
    var noF0S: Double?          // true が無く voice_self: null（f0 が取れない）
    var noFramesS: Double?      // 数える分のコマが無い・来なかった
    var final: Bool?            // speaker_enroll_progress：登録し終えた・止めた・記録を閉じたときの最後の1行（score は無い、v1.10.2〜）
    var gateVersion: Int?       // speaker_enroll：本人の声の数える決まりの版（2＝v1.10.3〜）
    var cached: Bool?           // speaker_model：前に読み込んだモデルを使った（v1.10.3〜）
    var computeUnits: String?   // speaker_model：Core ML に頼んだ計算の場所（v1.10.2〜）
    var loadMs: Double?         // speaker_model：モデルの読み込みにかかった時間
    var plan: [String: Int]?    // speaker_model：演算ごとに動かす予定の場所の数（ne / gpu / cpu。iOS 17.4〜）
    var audio: AudioSessionSummary?   // audio_session：音の設定（v1.10.2〜）
    // co_change（v1.12〜、重なりのできごと。t_ms は始まり）
    var endMs: Int64?           // co_change：終わり（最後に重なっていたコマ）
    var durationS: Double?      // co_change：長さ
    var above: Bool?            // co_change：いつもより上（true）か下（false）
    var metrics: [String]?      // co_change：入っていた指標
    var groups: [String]?       // co_change：入っていたまとまり（brow / orbit / nose_lip / mouth_tense / smile / voice）
    var atEnd: Bool?            // co_change：記録の終わりで打ち切った
    // eyes_closed_ratio（v1.12〜、目を閉じている割合。判定には使わない）
    var ratio: Double?
    var windowS: Double?
    var faceFrames: Int?
    var closedFrames: Int?
    // mark（v1.13〜）：家族の印の詳しい中身（家族の言葉。選んだら同じ行に書き直す）と、付けた時刻
    var detail: String?
    var detailAt: Int64?

    enum CodingKeys: String, CodingKey {
        case type, tMs = "t_ms", kind, value, faceReadable = "face_readable", source, by
        case clockCorrected = "clock_corrected", head, from, yawDeg = "yaw_deg", camera, count, baseline, personId = "person_id", savedCamera = "saved_camera", mirrorCorrected = "mirror_corrected", orientationVersion = "camera_orientation_version", part, median, iqr
        case collect, validS = "valid_s", score, computedS = "computed_s", notSelfS = "not_self_s", noF0S = "no_f0_s", noFramesS = "no_frames_s", final, gateVersion = "gate_version", cached, computeUnits = "compute_units", loadMs = "load_ms", plan, audio
        case endMs = "end_ms", durationS = "duration_s", above, metrics, groups, atEnd = "at_end", ratio, windowS = "window_s", faceFrames = "face_frames", closedFrames = "closed_frames", detail, detailAt = "detail_at"
    }
}

/// 普段（最初の30秒／60秒。撮る側の設定）の各指標の n / mean / std
struct BaselineRecord: Encodable {
    struct Stat: Codable, Equatable {
        let n: Int
        let mean: Double?
        let std: Double?
        let insufficient: Bool  // サンプルが足りず、比べるのに使わない
        var median: Double? = nil   // 声の高さ（f0_hz）だけ：中央値と四分位範囲（v1.9.1〜。声の高さの範囲に使う）
        var iqr: Double? = nil
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
    var pose: [String: Stat]?   // 普段の間の顔の向き（yaw_deg・pitch_deg・roll_deg の n・平均・標準偏差、本人から見て。v1.8〜。アプリは比べるのに使わず、振り返りレポートだけ）
    var part: String?           // face：表情の普段 / voice：声の普段（v1.6〜。無い行は両方）
    var voiceValidS: Double?    // voice：声の普段に数えた本人の声の秒数（v1.6〜）
    var voiceSessions: Int?     // voice：声の普段を集めたセッションの数（v1.7〜。前のセッションから続けて集めたら 2 以上）
    var voiceDays: Int?         // voice：集めた日の数（v1.7〜）
    var voiceCarriedS: Double?  // voice：前のセッションまでに集めていた本人の声の秒数（v1.7〜）
    var eyesClosedS: Double?    // 普段の間に目を閉じていた秒数（v1.4〜。目を閉じているの決まりで、数えたコマから。保存した普段には無い）
    var asym: [String: Stat]?   // 左右の差（左 − 右、本人から見て）の普段（v1.12〜。brow_down・orbit・mouth_smile。判定には使わず、振り返りレポートで比べる）

    enum CodingKeys: String, CodingKey {
        case source, compared, savedMs = "saved_ms", camera, faceBox = "face_box", pose, eyesClosedS = "eyes_closed_s", part, voiceValidS = "voice_valid_s"
        case voiceSessions = "voice_sessions", voiceDays = "voice_days", voiceCarriedS = "voice_carried_s", asym
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

    func start(camera: CameraLens, personId: String?, mirrored: Bool = false, extra: [String: Any] = [:]) throws {
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
            // 顔の向きの左右（v1.7.1〜は 2：本人から見た右・左が +。無い記録は 1：映像で見て右が +。読むときに左右を入れ替える）
            "direction_version": FaceDirection.version,
            "f0_version": PitchCriteria.version,
            "f0_floor_db": Double(PitchCriteria.floorDb),
            "f0_range_hz": [Double(PitchCriteria.minHz), Double(PitchCriteria.maxHz)],
            "f0_clarity_min": Double(PitchCriteria.clarityMin),
            // 人の id（名前は書かない。v1.2〜）
            "person_id": personId ?? NSNull(),
            "note": "type=frame|baseline|event / t_ms=撮影時刻・イベントの時刻(epoch ms) / bs=表情の数値52種(0-1) / yaw_deg,pitch_deg,roll_deg=顔の向き(本人から見て右・上・右へ傾くが+。direction_version=2、head_turn の右・左も本人から見て) / pts=鍵となる顔の点[x,y,z] / proc_ms=解析時間 / lat_ms=撮影→結果 / camera=使ったカメラ(wide=広角, ultra_wide=超広角, front=前面・自分で試す用。超広角は画角の端で顔が歪み表情の数値が変わることがある) / mirror_corrected=解析の映像が鏡で、記録の値を背面と同じ意味に直した / camera_orientation_version=映像の向きの決め方(2=v1.6.1〜) / f0_version=声の高さの求め方(2=v1.6.2〜、f0_floor_db 以上の音で f0_range_hz の範囲)"
        ]
        let data = try JSONSerialization.data(withJSONObject: header.merging(extra) { a, _ in a }, options: [.sortedKeys])
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
            stats.addEvent(tMs: e.tMs, kind: e.kind, value: v, part: e.part)
        }
    }

    /// 家族の印の行がファイルのどこから始まるか（v1.13〜、詳しい中身を書き直すため。queue の上でだけ触る）
    private var markOffsets: [Int64: UInt64] = [:]

    /// 家族の印を書く（あとで詳しい中身を同じ行に書き直せるように、行の始まりを覚えておく）
    func writeMark(_ e: EventRecord) {
        queue.async {
            guard let h = self.handle, let d = try? self.encoder.encode(e) else { return }
            if let off = try? h.offset() { self.markOffsets[e.tMs] = off }
            h.write(d + Data("\n".utf8))
            self.count(e)
        }
    }

    /// 記録中のファイルの家族の印の行に、詳しい中身を書き直す（v1.13〜）。そこから後ろの行を読み、印の行だけ変えて書き戻す。
    /// 返り値は queue の上で決まるので、done で知らせる（書けたか）
    func amendMark(tMs: Int64, detail: String?, detailAt: Int64, done: @escaping (Bool) -> Void = { _ in }) {
        queue.async {
            guard let h = self.handle, let name = self.fileName, let off = self.markOffsets[tMs] else { done(false); return }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
            guard let shift = MarkFile.amendInPlace(handle: h, url: url, offset: off, tMs: tMs, detail: detail, detailAt: detailAt) else { done(false); return }
            for (k, v) in self.markOffsets where v > off { self.markOffsets[k] = UInt64(Int64(v) + shift) }   // 後ろの印の行の始まりもずれる
            done(true)
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
            markOffsets = [:]
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
