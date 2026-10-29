// 記録のファイル（JSONL）を、撮る側・リプレイと同じ判定（ReplayData → DiffEngine）に流し、区間を1行1件の JSON で出す。
// analysis/check_app.py が、振り返りレポート（review.py）の区間と比べるのに使う（Mac で swiftc でビルドする。アプリには入らない）。
// 使い方：diffcheck 記録.jsonl ...      --heads を付けると、区間の代わりに顔の向きの段と head_turn の文を出す（v1.7.1〜）。--co で重なりのできごと（v1.12〜）
import Foundation

// 家族の印の詳しい中身（v1.13〜）：記録の印の行の書き直しと、前に同じ組み合わせのときの印の数え方を確かめる
if CommandLine.arguments.contains("--mark-selftest") {
    var bad: [String] = []
    let lines = [#"{"schema":"ability-cam.ios.v0.2","person_id":"p1"}"#,
                 #"{"type":"event","t_ms":1000,"kind":"change","value":["brow_down:above","voice_on:on"]}"#,
                 #"{"type":"event","t_ms":2000,"kind":"mark","value":"不快"}"#,
                 #"{"type":"frame","t_ms":2001,"face":true}"#,
                 #"{"type":"event","t_ms":3000,"kind":"mark","value":"不快","source":"viewer","by":"iPad"}"#]
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    if let a = MarkFile.amend(data, tMs: 3000, detail: "姿勢がつらそう", detailAt: 9000) {
        let out = String(decoding: a, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if out.count != lines.count + 1 { bad.append("行の数が変わった") }
        if !out[4].contains(#""detail":"姿勢がつらそう""#) || !out[4].contains(#""detail_at":9000"#) || !out[4].contains(#""by":"iPad""#) { bad.append("印の行に書けていない \(out[4])") }
        if out[2] != Substring(lines[2]) || out[3] != Substring(lines[3]) { bad.append("ほかの行が変わった") }
        if let c = MarkFile.amend(a, tMs: 3000, detail: nil, detailAt: 9100), String(decoding: c, as: UTF8.self).contains("detail") { bad.append("消せない") }
    } else { bad.append("印が見つからない") }
    if MarkFile.amend(data, tMs: 2500, detail: "x", detailAt: 1) != nil { bad.append("無い時刻なのに書いた") }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("markcheck-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let amended = MarkFile.amend(data, tMs: 2000, detail: "姿勢がつらそう", detailAt: 9000)!
    try? amended.write(to: dir.appendingPathComponent("ability-cam-1.jsonl"))
    try? Data(lines.joined(separator: "\n").replacingOccurrences(of: "p1", with: "p2").utf8).write(to: dir.appendingPathComponent("ability-cam-2.jsonl"))
    let pm = PastMarks.load(personID: "p1", dir: dir, except: nil)
    let sum = pm.summary(for: PastMarks.key(["brow_down:above", "voice_on:on"]))
    if sum.map(\.text) != ["不快 2回：姿勢がつらそう 1回"] { bad.append("前に同じ組み合わせの数が違う \(sum.map(\.text))") }
    if !pm.summary(for: PastMarks.key(["rms_db:above"])).isEmpty { bad.append("違う組み合わせなのに出た") }
    if PastMarks.key(["voice_on:on"]) != nil { bad.append("声が出ただけで組み合わせになった") }
    // 記録中のファイル（v1.13〜、SessionLogger.amendMark）：書いている途中で印の行を書き直し、そのあとも続きを書ける
    let live = dir.appendingPathComponent("live.jsonl")
    FileManager.default.createFile(atPath: live.path, contents: nil)
    if let h = try? FileHandle(forUpdating: live) {
        h.write(Data((lines[0] + "\n" + lines[1] + "\n").utf8))
        let off = (try? h.offset()) ?? 0
        h.write(Data((lines[2] + "\n" + lines[3] + "\n").utf8))
        let shift = MarkFile.amendInPlace(handle: h, url: live, offset: off, tMs: 2000, detail: "トイレ", detailAt: 5000)
        h.write(Data((lines[4] + "\n").utf8))
        try? h.close()
        let text = (try? String(contentsOf: live, encoding: .utf8)) ?? ""
        let ls = text.split(separator: "\n")
        if shift == nil || ls.count != 5 || !ls[2].contains("トイレ") || ls[3] != Substring(lines[3]) || ls[4] != Substring(lines[4]) {
            bad.append("記録中のファイルの書き直しが違う：\(text)")
        }
    } else { bad.append("live.jsonl を開けない") }
    try? FileManager.default.removeItem(at: dir)
    print(bad.isEmpty ? "OK" : bad.joined(separator: "\n"))
    exit(bad.isEmpty ? 0 : 1)
}

let heads = CommandLine.arguments.contains("--heads")
let voice = CommandLine.arguments.contains("--voice")   // v1.9〜：声が出ていたコマの本人の声の判定（決め直したもの）
for path in CommandLine.arguments.dropFirst() where !path.hasPrefix("--") {
    let url = URL(fileURLWithPath: path)
    do {
        let d = try ReplayData(data: Data(contentsOf: url), name: url.lastPathComponent)
        if voice {
            for v in d.voiceDetail {
                var o: [String: Any] = ["t": v.t, "voice_self": v.voiceSelf]
                if let r = v.reason { o["reason"] = r }
                if let c = v.corr { o["corr"] = c }
                if let c = v.corrOther { o["corr_other"] = c }
                if let m = v.match { o["match"] = m }
                let line = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
                print(String(decoding: line, as: UTF8.self))
            }
            continue
        }
        if CommandLine.arguments.contains("--co") {   // v1.12〜：重なりのできごと
            for c in d.coChanges {
                let o: [String: Any] = ["start": c.startT, "end": c.endT, "above": c.above, "metrics": c.metricKeys, "groups": c.groupKeys]
                let line = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
                print(String(decoding: line, as: UTF8.self))
            }
            continue
        }
        if heads {
            var rows: [[String: Any]] = d.heads.map { ["kind": "head", "value": $0.value.rawValue, "start": $0.start, "end": $0.end] }
            rows += d.events.filter { $0.kind == .head }.map { ["kind": "head_text", "text": $0.text, "t": $0.t] }
            for o in rows {
                let line = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
                print(String(decoding: line, as: UTF8.self))
            }
            continue
        }
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
