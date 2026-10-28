// 記録のファイル（JSONL）を、撮る側・リプレイと同じ判定（ReplayData → DiffEngine）に流し、区間を1行1件の JSON で出す。
// analysis/check_app.py が、振り返りレポート（review.py）の区間と比べるのに使う（Mac で swiftc でビルドする。アプリには入らない）。
// 使い方：diffcheck 記録.jsonl ...
import Foundation

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    do {
        let d = try ReplayData(data: Data(contentsOf: url), name: url.lastPathComponent)
        for s in d.segments {
            var o: [String: Any] = ["file": path, "kind": s.target.key, "above": s.above, "start": s.startT, "end": s.endT]
            if s.peakZ.isFinite { o["peak_z"] = s.peakZ }
            let line = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
            print(String(decoding: line, as: UTF8.self))
        }
    } catch {
        FileHandle.standardError.write(Data("\(path): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
