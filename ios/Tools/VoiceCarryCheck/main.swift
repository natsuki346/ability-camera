// 途中まで集めた声の普段（v1.7〜、Baseline.swift の Welford.merged・VoicePartial）を Mac で確かめる。
// analysis/tests の VoiceCarryTest が swiftc でビルドして動かす（アプリには入らない）。合っていれば「OK」と出して 0 を返す
import Foundation

// --pitch 値… を渡すと、声の高さの中央値と四分位範囲（DiffCriteria.robustPitch、v1.9.1〜）を出す（review.robust_pitch と比べる）
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--pitch" {
    let r = DiffCriteria.robustPitch(CommandLine.arguments.dropFirst(2).compactMap(Double.init))!
    print(r.median, r.iqr)
    exit(0)
}

var bad: [String] = []
func check(_ ok: Bool, _ what: String) { if !ok { bad.append(what) } }

// 1. 3つのセッションに分けて集めて足したものが、まとめて集めたものと同じ
var rng = SystemRandomNumberGenerator()
let xs = (0..<300).map { _ in Double.random(in: 150...260, using: &rng) }
var all = Welford()
xs.forEach { all.add($0) }
var parts = [Welford(), Welford(), Welford()]
for (i, x) in xs.enumerated() { parts[i < 40 ? 0 : i < 190 ? 1 : 2].add(x) }
let merged = parts[0].merged(parts[1]).merged(parts[2])
check(merged.n == all.n, "n が違う \(merged.n) / \(all.n)")
check(abs(merged.mean - all.mean) < 1e-9, "平均が違う \(merged.mean) / \(all.mean)")
check(abs(merged.std - all.std) < 1e-9, "標準偏差が違う \(merged.std) / \(all.std)")
check(Welford().merged(parts[1]) == parts[1] && parts[1].merged(Welford()) == parts[1], "空と足すと変わる")

// 2. 集め始めてから14日で捨てる
let day: Int64 = 86_400_000
let p = VoicePartial(startedMs: 0, updatedMs: 0, validS: 9.4, stats: ["f0_hz": merged], sessions: 2, days: ["2026-10-20", "2026-10-28"])
check(!p.expired(now: 14 * day - 1), "14日より前に捨てた")
check(p.expired(now: 14 * day), "14日たっても捨てない")

// 3. persons.json に書く形（キーの名前）と、読み直して同じになること
let data = try! JSONEncoder().encode(p)
let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
check(Set(obj.keys) == ["started_ms", "updated_ms", "valid_s", "stats", "sessions", "days"], "キーが違う \(obj.keys.sorted())")
check((try? JSONDecoder().decode(VoicePartial.self, from: data)) == p, "読み直すと違う")

if bad.isEmpty { print("OK") } else { print(bad.joined(separator: "\n")); exit(1) }
