import Foundation

/// コマが来なかった間（v1.19〜、記録の event kind: "frame_gap"）。前のコマから minMs 以上空いたら、次のコマが来たときに書く
enum FrameGap {
    static let minMs: Int64 = 300

    /// 分かった理由（カンマ区切り。無ければ nil）。notes：その間にあったこと（inactive / background / camera_interrupted:… / rotation / face_reload）。
    /// 数は前のコマとこのコマの間（このコマの分を含む）：カメラが届けた・捨てた・解析に渡した・結果が返ったコマ
    static func reason(notes: [String], delivered: Int, dropped: Int, dropReason: String?, submitted: Int, returned: Int) -> String? {
        var out: [String] = []
        for n in notes where !out.contains(n) { out.append(n) }
        if dropped > 0 { out.append("camera_drop:\(dropReason ?? "unknown")") }       // カメラが捨てた（遅れ・バッファ不足）
        if delivered <= 1 && dropped == 0 { out.append("no_camera_frames") }          // カメラがコマを届けていない（止まっていた・割り込み）
        else if submitted > 2 && returned <= 1 { out.append("no_result") }            // 解析に渡したのに結果が返らない（MediaPipe が捨てた）
        return out.isEmpty ? nil : out.joined(separator: ",")
    }
}
