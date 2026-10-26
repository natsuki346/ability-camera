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

    enum CodingKeys: String, CodingKey {
        case type, tMs = "t_ms", face, bs, pts, rmsDb = "rms_db", f0Hz = "f0_hz", procMs = "proc_ms", latMs = "lat_ms"
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
    let kind: String            // scene / mark / change / baseline_restart
    let value: Value?
    var faceReadable: Bool?     // change のときだけ

    enum CodingKeys: String, CodingKey {
        case type, tMs = "t_ms", kind, value, faceReadable = "face_readable"
    }
}

/// 普段（最初の60秒）の各指標の n / mean / std
struct BaselineRecord: Encodable {
    struct Stat: Encodable {
        let n: Int
        let mean: Double?
        let std: Double?
        let insufficient: Bool  // サンプルが足りず、比べるのに使わない
    }

    let type = "baseline"
    let tMs: Int64              // 記録し終えた時刻
    let startedMs: Int64        // 記録し始めた時刻
    let durationS: Double
    let minN: Int
    let metrics: [String: Stat]

    enum CodingKeys: String, CodingKey {
        case type, tMs = "t_ms", startedMs = "started_ms", durationS = "duration_s", minN = "min_n", metrics
    }
}

final class SessionLogger {
    private let queue = DispatchQueue(label: "logger")
    private var handle: FileHandle?
    private let encoder = JSONEncoder()
    private(set) var fileName: String?

    func start() throws {
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
            "note": "type=frame|baseline|event / t_ms=撮影時刻・イベントの時刻(epoch ms) / bs=表情の数値52種(0-1) / pts=鍵となる顔の点[x,y,z] / proc_ms=解析時間 / lat_ms=撮影→結果"
        ]
        let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        queue.async { self.handle?.write(data + Data("\n".utf8)) }
    }

    func write<T: Encodable>(_ record: T) {
        queue.async {
            guard let h = self.handle, let d = try? self.encoder.encode(record) else { return }
            h.write(d + Data("\n".utf8))
        }
    }

    func stop() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }
}
