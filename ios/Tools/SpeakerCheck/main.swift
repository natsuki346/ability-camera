// 話者の区別（v1.10〜、Speaker.swift）を Mac で確かめる。analysis/speaker_check.py から使う（アプリには入らない）。
// WAV（16bit・1ch）を 16kHz にして輪のバッファに入れ、声の途中で、長さ span 秒の声のまとまりの埋め込みを求める。
// 出力：1つ1行の JSON {"file", "t", "span", "calc_ms", "embedding": [...]}（埋め込みはこの道具の中だけ。アプリの記録には書かない）
// 使い方：SpeakerCheck モデル.mlmodelc 音.wav[@開始秒] ... --span 3 --step 1.5
import CoreML
import Foundation

func readWav(_ path: String) -> (samples: [Float], sr: Int)? {
    guard let d = FileManager.default.contents(atPath: path), d.count > 44 else { return nil }
    let b = [UInt8](d)
    func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
    func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    var i = 12, sr = 0, ch = 1
    while i + 8 <= b.count {
        let id = String(bytes: b[i..<i + 4], encoding: .ascii) ?? "", size = u32(i + 4)
        if id == "fmt " { ch = u16(i + 10); sr = u32(i + 12) }
        if id == "data" {
            let start = i + 8, count = min(size, b.count - start) / 2 / ch
            return ((0..<count).map { Float(Int16(bitPattern: UInt16(u16(start + $0 * 2 * ch)))) / 32768 }, sr)
        }
        i += 8 + size + (size & 1)
    }
    return nil
}

func resample16k(_ x: [Float], from sr: Int) -> [Float] {
    guard sr != SpeakerCriteria.sampleRate else { return x }
    let ratio = Double(sr) / Double(SpeakerCriteria.sampleRate)
    let n = Int(Double(x.count) / ratio)
    return (0..<n).map { k in
        let p = Double(k) * ratio, i = Int(p), f = Float(p - Double(i))
        return i + 1 < x.count ? x[i] * (1 - f) + x[i + 1] * f : x[min(i, x.count - 1)]
    }
}

var args = Array(CommandLine.arguments.dropFirst())

// --selftest：モデルを使わない計算（使うフレームの印・登録の平均・似ている度合い）を確かめる。合っていれば「OK」
if args.first == "--selftest" {
    var bad: [String] = []
    let m3 = SpeakerMath.mask(spanS: 3), m05 = SpeakerMath.mask(spanS: 0.5)
    if m3.count != SpeakerCriteria.maskFrames || Int(m3.reduce(0, +)) != 177 { bad.append("3秒の印が違う \(m3.reduce(0, +))") }
    if Int(m05.reduce(0, +)) != 30 || m05.last != 1 || m05.first != 0 { bad.append("0.5秒の印が違う") }
    var p = SpeakerEnrollPartial(model: SpeakerCriteria.model, sum: [], embeddings: 0, validS: 0, startedMs: 0, consentBy: "x", consentMs: 0)
    SpeakerMath.add(&p, embedding: [3, 4], spanS: 0.5)
    SpeakerMath.add(&p, embedding: [0, 2], spanS: 0.5)
    let f = SpeakerMath.finish(p, now: 1)
    if abs(SpeakerMath.cosine(f.embedding, [0.6, 1.8]) - 1) > 1e-6 { bad.append("登録の平均が違う \(f.embedding)") }
    if f.n != 2 || abs(f.validS - 1) > 1e-9 { bad.append("数・長さが違う") }
    if abs((f.spread ?? -1) - 0.2) > 1e-3 { bad.append("ばらつきが違う \(String(describing: f.spread))") }
    if abs(SpeakerMath.cosine([1, 0], [0, 1])) > 1e-9 || abs(SpeakerMath.cosine([1, 1], [2, 2]) - 1) > 1e-6 { bad.append("似ている度合いが違う") }
    if !p.expired(now: 14 * 86_400_000) || p.expired(now: 14 * 86_400_000 - 1) { bad.append("14日で捨てない") }
    var r = SpeakerRing()
    let one = [Float](repeating: 0.1, count: 1600)
    one.withUnsafeBufferPointer { r.append($0.baseAddress!, count: 1600) }
    r.mark(voiced: true, at: 0.0); r.mark(voiced: true, at: 0.1)
    if abs((r.span(now: 0.1) ?? -1) - 0.1) > 1e-9 { bad.append("声の長さが違う \(String(describing: r.span(now: 0.1)))") }
    r.mark(voiced: false, at: 0.5)
    if r.span(now: 0.5) != nil { bad.append("声が途切れても長さがある") }
    if r.window().count != SpeakerCriteria.windowSamples || r.window().last != 0.1 { bad.append("輪のバッファの並びが違う") }
    print(bad.isEmpty ? "OK" : bad.joined(separator: "\n"))
    exit(bad.isEmpty ? 0 : 1)
}
func opt(_ name: String, _ d: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return d }
    args.removeSubrange(i...(i + 1)); return v
}
let span = opt("--span", 3), step = opt("--step", 1.5)
guard args.count >= 2, let emb = SpeakerEmbedder(url: URL(fileURLWithPath: args[0]), computeUnits: .all) else {
    FileHandle.standardError.write("使い方：SpeakerCheck モデル.mlmodelc 音.wav ... [--span 秒] [--step 秒]\n".data(using: .utf8)!)
    exit(2)
}
for path in args.dropFirst() {
    guard let (x0, sr) = readWav(path) else { continue }
    let x = resample16k(x0, from: sr)
    var ring = SpeakerRing()
    let hop = SpeakerCriteria.sampleRate / 10
    var t = 0.0, last = -Double.infinity, i = 0
    while i + hop <= x.count {
        x.withUnsafeBufferPointer { ring.append($0.baseAddress! + i, count: hop) }
        i += hop; t = Double(i) / Double(SpeakerCriteria.sampleRate)
        ring.mark(voiced: true, at: t)   // 作り物の声なので、ずっと声が出ているとみなす（span で長さを決める）
        guard t >= span, t - last >= step - 1e-9 else { continue }
        last = t
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let e = emb.embed(window: ring.window(), spanS: span) else { continue }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let o: [String: Any] = ["file": (path as NSString).lastPathComponent, "t": t, "span": span, "calc_ms": ms, "embedding": e.map(Double.init)]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self))
    }
}
