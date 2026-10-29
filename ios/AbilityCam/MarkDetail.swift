import Foundation

/// 家族の印。家族が自分の判断を記録するための言葉で、アプリが本人の状態を言っているのではない（docs/wording-guide.md）
enum Mark: String, CaseIterable, Identifiable {
    case pleasant = "快", unpleasant = "不快", unknown = "分からない"
    var id: String { rawValue }
}

/// 家族の印の「詳しい中身」の選択肢（v1.13〜）。家族が人ごとに決める。家族の言葉としてそのまま記録し、アプリが状態として判定・表示には使わない
struct MarkDetails: Codable, Equatable {
    var pleasant: [String]     // 快
    var unpleasant: [String]   // 不快

    /// 初めの選択肢（仮）
    static let initial = MarkDetails(pleasant: ["楽しそう", "落ち着いている", "好きなもの・人", "その他"],
                                     unpleasant: ["お腹がすいた", "トイレ", "痛そう", "暑い・寒い", "姿勢がつらそう", "眠そう", "その他"])

    func options(for m: Mark) -> [String] {
        switch m {
        case .pleasant: pleasant
        case .unpleasant: unpleasant
        case .unknown: []   // 分からないときは詳しい中身を出さない
        }
    }

    /// 記録のヘッダ（mark_details）に書く形：{"快": [...], "不快": [...]}
    var header: [String: [String]] { [Mark.pleasant.rawValue: pleasant, Mark.unpleasant.rawValue: unpleasant] }

    init(pleasant: [String], unpleasant: [String]) { self.pleasant = pleasant; self.unpleasant = unpleasant }

    /// 記録のヘッダから（無い古い記録は nil）
    init?(header: Any?) {
        guard let d = header as? [String: [String]] else { return nil }
        pleasant = d[Mark.pleasant.rawValue] ?? []
        unpleasant = d[Mark.unpleasant.rawValue] ?? []
    }
}


/// 家族の印の「詳しい中身」（v1.13〜）を、記録の印の行（type: "event"、kind: "mark"）に書く。
/// detail：家族が選んだ言葉（家族の言葉としてそのまま。アプリは状態として判定・表示に使わない）、detail_at：付けた時刻（あとから付けたら、その時刻）
enum MarkFile {
    /// 1行（JSON）が、その時刻の家族の印か
    static func isMark(_ o: [String: Any], tMs: Int64) -> Bool {
        (o["type"] as? String) == "event" && (o["kind"] as? String) == "mark" && (o["t_ms"] as? NSNumber)?.int64Value == tMs
    }

    /// 印の1行に detail・detail_at を書く（detail が nil なら消す）。印の行でなければ nil
    static func amendLine(_ line: Data, tMs: Int64, detail: String?, detailAt: Int64) -> Data? {
        guard var o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], isMark(o, tMs: tMs) else { return nil }
        if let detail {
            o["detail"] = detail; o["detail_at"] = detailAt
        } else {
            o["detail"] = nil; o["detail_at"] = nil
        }
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// 記録のファイル全体から、その時刻の印の行（最初の1つ）を書き直したもの。見つからなければ nil
    static func amend(_ data: Data, tMs: Int64, detail: String?, detailAt: Int64) -> Data? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (i, l) in lines.enumerated() where l.range(of: Data("\"mark\"".utf8)) != nil {
            if let new = amendLine(Data(l), tMs: tMs, detail: detail, detailAt: detailAt) {
                lines[i] = new[...]
                return Data(lines.joined(separator: [UInt8(ascii: "\n")]))
            }
        }
        return nil
    }

    /// 閉じた記録のファイル（これまでの記録・見る側で開いた記録）を書き直す。書けなければ投げる
    static func amend(url: URL, tMs: Int64, detail: String?, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let new = amend(data, tMs: tMs, detail: detail, detailAt: now) else { throw AmendError.notFound }
        try new.write(to: url, options: .atomic)
    }

    /// 書き込み中のファイル（記録中）の、offset から始まる印の行を書き直す。そこから後ろを読み、印の行だけ変えて書き戻し、ファイルの終わりに戻す。
    /// 返り値：行の長さの変わり（後ろの行の始まりのずれ）。書けなければ nil
    static func amendInPlace(handle h: FileHandle, url: URL, offset off: UInt64, tMs: Int64, detail: String?, detailAt: Int64) -> Int64? {
        try? h.synchronize()
        guard let r = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? r.close() }
        guard (try? r.seek(toOffset: off)) != nil, let tail = try? r.readToEnd(),
              let nl = tail.firstIndex(of: UInt8(ascii: "\n")),
              let line = amendLine(tail[tail.startIndex..<nl], tMs: tMs, detail: detail, detailAt: detailAt) else { return nil }
        let rest = tail[nl...]   // 改行から後ろ
        do {
            try h.seek(toOffset: off)
            h.write(line + rest)
            try h.truncate(atOffset: off + UInt64(line.count + rest.count))
            try h.seekToEnd()
            return Int64(line.count) - Int64(nl - tail.startIndex)
        } catch { return nil }
    }

    enum AmendError: LocalizedError {
        case notFound
        var errorDescription: String? { "その時刻の家族の印が、記録のファイルに見つかりませんでした" }
    }
}

/// 見る側の「前に同じ組み合わせのとき、家族が付けた印」（v1.13〜）：同じ人の記録で、出ていた「いつもとの違い」の組み合わせ（change のキー、声が出たは除く）が
/// 今と同じだったときに家族が付けた印の数と、詳しい中身の上位。撮る側がこの端末の記録から数え、見る側へ送る（見る側は保存しない）
struct PastMarks {
    struct Entry { var value: String; var detail: String? }
    private(set) var byCombo: [String: [Entry]] = [:]

    static func key(_ diffKeys: [String]) -> String? {
        let k = diffKeys.filter { !$0.hasPrefix(DiffTarget.voiceOnKey + ":") }.sorted()
        return k.isEmpty ? nil : k.joined(separator: ",")
    }

    mutating func add(combo: String?, value: String, detail: String?) {
        guard let combo else { return }
        byCombo[combo, default: []].append(Entry(value: value, detail: detail))
    }

    /// その時刻に付けた印の詳しい中身を変える（いちばん新しい同じ印）
    mutating func setDetail(combo: String?, value: String, detail: String?) {
        guard let combo, var list = byCombo[combo], let i = list.lastIndex(where: { $0.value == value }) else { return }
        list[i].detail = detail
        byCombo[combo] = list
    }

    /// 見る側へ送る形：印ごとの数と、詳しい中身の上位2つ（数の多い順、同じなら新しく付いた順は問わず名前の順）
    func summary(for combo: String?) -> [LivePastMark] {
        guard let combo, let list = byCombo[combo], !list.isEmpty else { return [] }
        var out: [LivePastMark] = []
        for m in Mark.allCases {
            let xs = list.filter { $0.value == m.rawValue }
            guard !xs.isEmpty else { continue }
            var count: [String: Int] = [:]
            for x in xs { if let d = x.detail { count[d, default: 0] += 1 } }
            let top = count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2)
            out.append(LivePastMark(value: m.rawValue, count: xs.count, details: top.map { LivePastMark.Detail(text: $0.key, count: $0.value) }))
        }
        return out
    }

    /// この端末の記録（同じ人、今の記録を除く）から作る。重いので裏のスレッドで呼ぶ。読むのは header と event の行だけ
    static func load(personID: String, dir: URL, except current: String?) -> PastMarks {
        var out = PastMarks()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("ability-cam-") && $0.hasSuffix(".jsonl") && $0 != current }.sorted()
        for f in files {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f), options: .mappedIfSafe) else { continue }
            var first = true
            var diffs: [String] = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                defer { first = false }
                if first {
                    guard let h = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          (h["person_id"] as? String) == personID else { break }
                    continue
                }
                guard line.range(of: Data("\"event\"".utf8)) != nil,
                      let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                switch o["kind"] as? String {
                case "change": diffs = (o["value"] as? [String]) ?? []
                case "baseline_restart":
                    diffs = BaselinePart.keysAfterRestart(diffs, part: BaselinePart.of(o["part"] as? String))
                case "mark":
                    if let v = o["value"] as? String { out.add(combo: key(diffs), value: v, detail: o["detail"] as? String) }
                default: break
                }
            }
        }
        return out
    }
}

/// 見る側へ送る「前に同じ組み合わせのとき、家族が付けた印」の1つ
struct LivePastMark: Codable, Hashable {
    struct Detail: Codable, Hashable { let text: String; let count: Int }
    let value: String          // 快 / 不快 / 分からない
    let count: Int
    let details: [Detail]      // 詳しい中身の上位2つ

    /// 「不快 3回：姿勢がつらそう 2回・眠そう 1回」
    var text: String {
        "\(value) \(count)回" + (details.isEmpty ? "" : "：" + details.map { "\($0.text) \($0.count)回" }.joined(separator: "・"))
    }
}
