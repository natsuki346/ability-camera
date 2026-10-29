// 記録のファイル（JSONL）を、撮る側・リプレイと同じ判定（ReplayData → DiffEngine）に流し、区間を1行1件の JSON で出す。
// analysis/check_app.py が、振り返りレポート（review.py）の区間と比べるのに使う（Mac で swiftc でビルドする。アプリには入らない）。
// 使い方：diffcheck 記録.jsonl ...      --heads を付けると、区間の代わりに顔の向きの段と head_turn の文を出す（v1.7.1〜）。--co で重なりのできごと（v1.12〜）
import Foundation

// 顔の点の距離（v1.15〜、FaceGeometry）：作り物の点で値・頭の傾き・横を向いたときを確かめる
if CommandLine.arguments.contains("--geo-selftest") {
    var bad: [String] = []
    let base: [Int: (x: Double, y: Double)] = [33: (100, 200), 263: (200, 200), 10: (150, 100), 152: (150, 300),
        105: (125, 170), 334: (175, 170), 159: (125, 190), 386: (175, 190), 145: (125, 200), 374: (175, 200),
        107: (140, 172), 336: (160, 172), 13: (150, 250), 14: (150, 256), 61: (130, 248), 291: (170, 248),
        55: (138, 178), 285: (162, 178), 133: (138, 200), 362: (162, 200)]   // v1.18〜：眉頭（下の縁）・目頭
    let want = ["brow_eye_gap": 0.2, "eye_open": 0.1, "brow_inner_gap": 0.2, "mouth_corner": 0.05, "brow_inner_eye": 0.22, "brow_inner_gap2": 0.24]
    func check(_ pts: [Int: (x: Double, y: Double)], _ label: String) {
        guard let v = FaceGeometry.values(yaw: 0, { pts[$0] }) else { bad.append("\(label)：求まらない"); return }
        for (k, w) in want where abs((v[k] ?? .nan) - w) > 1.5e-3 { bad.append("\(label)：\(k) が \(v[k] ?? .nan)（\(w) のはず）") }
    }
    check(base, "まっすぐ")
    let a = 30 * Double.pi / 180
    check(base.mapValues { p in (150 + (p.x - 150) * cos(a) - (p.y - 200) * sin(a), 200 + (p.x - 150) * sin(a) + (p.y - 200) * cos(a)) }, "30°傾けた")
    check(base.mapValues { ($0.x * 2.5 + 7, $0.y * 2.5 - 3) }, "大きさを変えた")
    if FaceGeometry.values(yaw: 26, { base[$0] }) != nil { bad.append("|yaw| > 25° なのに求めた") }
    if FaceGeometry.values(yaw: nil, { base[$0] }) != nil { bad.append("向きが無いのに求めた") }
    if FaceGeometry.values(yaw: -25, { base[$0] }) == nil { bad.append("|yaw| = 25° で求めない") }
    var smile = base; smile[61] = (130, 240); smile[291] = (170, 240)
    if (FaceGeometry.values(yaw: 0, { smile[$0] })?["mouth_corner"] ?? 0) <= 0.05 { bad.append("口角が上がっても大きくならない") }
    var frown = base; frown[105] = (125, 180); frown[334] = (175, 180)
    if (FaceGeometry.values(yaw: 0, { frown[$0] })?["brow_eye_gap"] ?? 1) >= 0.2 { bad.append("眉が下がっても小さくならない") }
    var inner = base; inner[55] = (142, 184); inner[285] = (158, 184)   // 眉頭が下がって寄る（v1.18〜）
    if let v = FaceGeometry.values(yaw: 0, { inner[$0] }), (v["brow_inner_eye"] ?? 1) < 0.22, (v["brow_inner_gap2"] ?? 1) < 0.24 {} else { bad.append("眉頭が下がって寄っても小さくならない") }
    var old = base; for i in [55, 285, 133, 362] { old[i] = nil }   // 点が足りないときは前の4つだけ
    if let v = FaceGeometry.values(yaw: 0, { old[$0] }), v.count == 4 {} else { bad.append("点 55・285・133・362 が無いと前の4つも求めない") }
    print(bad.isEmpty ? "OK" : bad.joined(separator: "\n"))
    exit(bad.isEmpty ? 0 : 1)
}

// コマが来なかった間の理由（v1.19〜、FrameGap）
if CommandLine.arguments.contains("--gap-selftest") {
    var bad: [String] = []
    func want(_ got: String?, _ w: String?, _ label: String) { if got != w { bad.append("\(label)：\(got ?? "nil")（\(w ?? "nil") のはず）") } }
    want(FrameGap.reason(notes: ["inactive", "inactive"], delivered: 1, dropped: 0, dropReason: nil, submitted: 1, returned: 1),
         "inactive,no_camera_frames", "コントロールセンターでカメラが止まった")
    want(FrameGap.reason(notes: [], delivered: 30, dropped: 0, dropReason: nil, submitted: 30, returned: 1), "no_result", "解析が返らない")
    want(FrameGap.reason(notes: [], delivered: 3, dropped: 20, dropReason: "late", submitted: 3, returned: 3), "camera_drop:late", "カメラが遅れたコマを捨てた")
    want(FrameGap.reason(notes: ["face_reload"], delivered: 15, dropped: 0, dropReason: nil, submitted: 1, returned: 1), "face_reload", "探す顔の数を変えた")
    want(FrameGap.reason(notes: ["rotation"], delivered: 10, dropped: 0, dropReason: nil, submitted: 10, returned: 10), "rotation", "回転の組み直し")
    want(FrameGap.reason(notes: [], delivered: 12, dropped: 0, dropReason: nil, submitted: 12, returned: 12), nil, "分からない")
    print(bad.isEmpty ? "OK" : bad.joined(separator: "\n"))
    exit(bad.isEmpty ? 0 : 1)
}

// 顔の点の距離の計算時間（v1.17〜）：1コマ分（FaceGeometry.values・geo_pts を作る・その2つを JSON にする）を何度も回して、1回あたりの µs を出す。
// Mac で測るので iPhone の値ではないが、1コマ 33ms に対してどのくらいかの目安（docs/validation-log.md）
if CommandLine.arguments.contains("--geo-bench") {
    var pts: [Int: (x: Double, y: Double)] = [:]
    for i in 0..<478 { pts[i] = (Double(i % 23) * 0.03 + 0.2, Double(i / 23) * 0.03 + 0.1) }
    pts[33] = (0.30, 0.40); pts[263] = (0.70, 0.40); pts[10] = (0.50, 0.15); pts[152] = (0.50, 0.85)
    let n = 20000
    let enc = JSONEncoder()
    var bytes = 0
    let t0 = Date()
    for k in 0..<n {
        let y = Double(k % 40) - 20
        let p = { (i: Int) -> (x: Double, y: Double)? in pts[i] }
        if let g = FaceGeometry.values(yaw: y, p) {
            let gp = FaceGeometry.indices.compactMap { i in p(i).map { [Float(($0.x * 10000).rounded() / 10000), Float(($0.y * 10000).rounded() / 10000)] } }
            bytes += ((try? enc.encode(g))?.count ?? 0) + ((try? enc.encode(gp))?.count ?? 0)
        }
    }
    let us = Date().timeIntervalSince(t0) / Double(n) * 1e6
    print(String(format: "1コマあたり %.1f µs（%d 回、JSON 平均 %d バイト）", us, n, bytes / n))
    exit(0)
}

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
        if CommandLine.arguments.contains("--cues") {   // v1.18〜：試すモードの結果（face_check.py --cues --json と比べる）
            let r = try CueTrial.run(data: Data(contentsOf: url), name: url.lastPathComponent)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            print(r.map { String(decoding: try! enc.encode($0), as: UTF8.self) } ?? "null")
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
