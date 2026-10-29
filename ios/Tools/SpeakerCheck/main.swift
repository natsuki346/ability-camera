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
    if m3.count != SpeakerCriteria.maskFrames || Int(m3.reduce(0, +)) != 38 { bad.append("3秒の印が違う \(m3.reduce(0, +))") }
    if Int(m05.reduce(0, +)) != 7 || m05.last != 1 || m05.first != 0 { bad.append("0.5秒の印が違う \(m05.reduce(0, +))") }
    // 声が出ているか（v1.10.2〜）：f0 がある、または -52dB 以上
    if !SpeakerMath.voiced(f0: true, rmsDb: -70) || !SpeakerMath.voiced(f0: false, rmsDb: -52) || SpeakerMath.voiced(f0: false, rmsDb: -52.1)
        || SpeakerMath.voiced(f0: false, rmsDb: nil) { bad.append("声が出ているかの決め方が違う") }
    var fr = SpeakerRing()
    for k in 0..<10 { fr.mark(voiced: true, f0: k % 4 == 0, at: Double(k) * 0.1) }   // 0.0〜0.9秒、f0 は 0・0.4・0.8
    if abs((fr.f0Ratio(spanS: 0.5, now: 0.9) ?? -1) - 0.2) > 1e-9 { bad.append("f0 の割合が違う \(String(describing: fr.f0Ratio(spanS: 0.5, now: 0.9)))") }
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
    // 5秒ごとの似ている度合い（v1.10.1〜）：0.5秒ずつ足すと 5・10秒で1回ずつ、足す前の平均と比べる
    var q = SpeakerEnrollPartial(model: SpeakerCriteria.model, sum: [], embeddings: 0, validS: 0, startedMs: 0, consentBy: "x", consentMs: 0)
    var marks: [(Double, Double)] = []
    for k in 0..<20 {
        let e: [Float] = k == 9 ? [0, 1] : [1, 0]
        if let s = SpeakerMath.addWithProgress(&q, embedding: e, spanS: 0.5) { marks.append((q.validS, s)) }
    }
    if marks.map(\.0) != [5, 10] { bad.append("5秒ごとに書かない \(marks)") }
    if abs((marks.first?.1 ?? -1) - 0) > 1e-9 || abs((marks.last?.1 ?? -1) - 0.998) > 1e-9 { bad.append("足す前の平均と比べていない \(marks)") }
    var q2 = SpeakerEnrollPartial(model: SpeakerCriteria.model, sum: [], embeddings: 0, validS: 4.8, startedMs: 0, consentBy: "x", consentMs: 0)
    if SpeakerMath.addWithProgress(&q2, embedding: [1, 0], spanS: 0.5) != nil { bad.append("初めの1つで書いた") }
    if SpeakerMath.addWithProgress(&q2, embedding: [1, 0], spanS: 0.5) != nil { bad.append("区切りを越えないのに書いた") }
    // 本人を登録するときの決め方（v1.10.4〜 gate 3：数える 0.5秒だけを見る。声の高さの範囲（pitch）は見ない）
    func gate(_ vs: [(Int64, Bool?, String?)], end: Int64, span: Double) -> SpeakerSelfGate<Int>.Outcome? {
        var g = SpeakerSelfGate<Int>()
        g.embedding(endMs: end, spanS: span, item: 1)
        for (t, v, r) in vs { g.frame(tMs: t, voiceSelf: v, reason: r) }
        return g.ready(nowMs: end).first?.outcome
    }
    let allTrue: [(Int64, Bool?, String?)] = stride(from: Int64(0), through: 3000, by: 33).map { ($0, true, nil) }
    func with(_ f: @escaping (Int64) -> (Bool?, String?)?) -> [(Int64, Bool?, String?)] { allTrue.map { x in f(x.0).map { (x.0, $0.0, $0.1) } ?? x } }
    let inCount = { (t: Int64) in t >= 2470 }   // 終わり 2970 から 0.5秒
    if gate(allTrue, end: 2970, span: 3) != .counted { bad.append("本人の声だけなのに数えない") }
    if gate(with { $0 == 1023 ? (false, "no_mouth") : nil }, end: 2970, span: 3) != .counted { bad.append("数える分の外の false で数えなかった（まとまり全体は見ない）") }
    if gate(with { inCount($0) && $0 % 2 == 0 ? (false, "pitch") : nil }, end: 2970, span: 3) != .counted { bad.append("false が pitch だけなのに数えない") }
    if gate(with { $0 == 2706 ? (false, "no_mouth") : nil }, end: 2970, span: 3) != .notSelf { bad.append("数える分に no_mouth の false があっても数えた") }
    if gate(with { $0 == 2706 ? (false, "no_face") : nil }, end: 2970, span: 3) != .notSelf { bad.append("数える分に no_face の false があっても数えた") }
    if gate(with { inCount($0) ? (false, "pitch") : nil }, end: 2970, span: 3) != .counted { bad.append("pitch の false だけ（声の高さの範囲の外の本人の声）で数えない") }
    if gate(with { inCount($0) ? ($0 % 2 == 0 ? (false, "pitch") : (false, "no_mouth")) : nil }, end: 2970, span: 3) != .notSelf { bad.append("pitch と no_mouth があるのに数えた") }
    if gate(with { $0 > 2700 ? (nil, nil) : nil }, end: 2970, span: 3) != .counted { bad.append("true があるのに null が混じって数えない") }
    if gate(with { inCount($0) ? (nil, nil) : nil }, end: 2970, span: 3) != .noF0 { bad.append("数える分が全部 null なのに noF0 でない") }
    if gate(with { inCount($0) ? ($0 % 2 == 0 ? (nil, nil) : (false, "pitch")) : nil }, end: 2970, span: 3) != .counted { bad.append("null と pitch だけで数えない") }
    if gate(allTrue.filter { $0.0 < 2900 }, end: 2970, span: 3) != nil { bad.append("終わりのコマを待たない") }
    var g = SpeakerSelfGate<Int>()
    g.embedding(endMs: 1000, spanS: 0.5, item: 7)
    if let r = g.ready(nowMs: 1000 + SpeakerCriteria.selfGateWaitMs + 1).first, r.outcome != .noFrames || r.item != 7 { bad.append("待ちすぎたのに数えた") }
    // 登録の途中の数え（v1.10.3〜）：計算した声が 5秒の区切りを越えたら true、理由ごとに足す
    var tally = SpeakerEnrollTally()
    var hits: [Double] = []
    let outs: [SpeakerSelfGate<Int>.Outcome] = [.counted, .notSelf, .noF0, .noFrames]
    for k in 0..<24 { if tally.add(outs[k % 4], seconds: 0.5) { hits.append(tally.computedS) } }
    if hits != [5, 10] { bad.append("計算した声の 5秒ごとが違う \(hits)") }
    if tally != SpeakerEnrollTally(computedS: 12, notSelfS: 3, noF0S: 3, noFramesS: 3) { bad.append("理由ごとの秒数が違う \(tally)") }
    print(bad.isEmpty ? "OK" : bad.joined(separator: "\n"))
    exit(bad.isEmpty ? 0 : 1)
}
// --gate 入力.json：本人の登録の数える決まり（SpeakerSelfGate.decide）。{"frames": [[t_ms, voice_self, reason], ...], "chunks": [[end_ms, span_s], ...]}
// → 1行に1つ counted / not_self / no_f0 / no_frames（analysis/enroll_check.py と同じかをテストで確かめる）
if args.first == "--gate", args.count >= 2, let d = FileManager.default.contents(atPath: args[1]),
   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
    let frames: [(Int64, Bool?, String?)] = ((o["frames"] as? [[Any]]) ?? []).map { f in
        ((f[0] as! NSNumber).int64Value, f[1] is NSNull ? nil : (f[1] as! Bool), f[2] as? String)
    }
    for c in (o["chunks"] as? [[NSNumber]]) ?? [] {
        switch SpeakerSelfGate<Int>.decide(frames, endMs: c[0].int64Value, spanS: c[1].doubleValue) {
        case .counted: print("counted"); case .notSelf: print("not_self"); case .noF0: print("no_f0"); case .noFrames: print("no_frames")
        }
    }
    exit(0)
}
// --fbank 音.wav：fbank（SpeakerFbank）を JSON で出す（analysis のテストで torchaudio の値と比べる）
if args.first == "--fbank", args.count >= 2, let (x0, sr) = readWav(args[1]) {
    let x = resample16k(x0, from: sr)
    let f = SpeakerFbank().compute(x)
    let o: [String: Any] = ["frames": SpeakerFbank.frames(samples: x.count), "bins": SpeakerFbank.bins, "fbank": f.map(Double.init)]
    print(String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self))
    exit(0)
}
// --plan モデル.mlmodelc：演算ごとに動かす予定の場所の数（Neural Engine で動くかを確かめる）
if args.first == "--plan", args.count >= 2 {
    let url = URL(fileURLWithPath: args[1])
    let sem = DispatchSemaphore(value: 0)
    Task {
        for (name, cu) in [("cpuAndNeuralEngine", MLComputeUnits.cpuAndNeuralEngine), ("all", .all)] {
            let p = await SpeakerEmbedder.computePlan(url: url, computeUnits: cu)
            print(name, (p ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
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
        guard let e = emb.embed(window: ring.window(), spanS: span)?.embedding else { continue }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let o: [String: Any] = ["file": (path as NSString).lastPathComponent, "t": t, "span": span, "calc_ms": ms, "embedding": e.map(Double.init)]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self))
    }
}
