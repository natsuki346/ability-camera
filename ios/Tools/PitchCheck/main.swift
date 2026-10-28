import Foundation

// 声の高さの求め方（ios/AbilityCam/Pitch.swift）を、Mac で WAV（16bit・1ch）に流す。analysis/pitch_check.py から使う。
// アプリと同じように、hop サンプルごとの塊の先頭 n サンプル（4096 まで）で音量と f0 を求める。
// 出力：1塊1行の JSON {"t": 秒, "rms_db": .., "f0_hz": ..（取れなければ null）, "clarity": ..}
// 使い方：PitchCheck 音.wav [hop]

func readWav(_ path: String) -> (samples: [Float], sr: Float)? {
    guard let d = FileManager.default.contents(atPath: path), d.count > 44 else { return nil }
    let b = [UInt8](d)
    func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
    func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    var i = 12, sr = 0, ch = 1, bits = 16
    while i + 8 <= b.count {
        let id = String(bytes: b[i..<i + 4], encoding: .ascii) ?? "", size = u32(i + 4)
        if id == "fmt " { ch = u16(i + 10); sr = u32(i + 12); bits = u16(i + 22) }
        if id == "data" {
            guard bits == 16 else { return nil }
            let start = i + 8, count = min(size, b.count - start) / 2 / ch
            var out = [Float](repeating: 0, count: count)
            for k in 0..<count { out[k] = Float(Int16(bitPattern: UInt16(u16(start + k * 2 * ch)))) / 32768 }
            return (out, Float(sr))
        }
        i += 8 + size + (size & 1)
    }
    return nil
}

let args = CommandLine.arguments
guard args.count >= 2, let (x, sr) = readWav(args[1]) else {
    FileHandle.standardError.write("使い方：PitchCheck 音.wav [hop]（16bit の WAV）\n".data(using: .utf8)!)
    exit(2)
}
let hop = args.count >= 3 ? Int(args[2]) ?? 4800 : Int(sr / 10)
var tracker = PitchTracker()
var pos = 0
x.withUnsafeBufferPointer { p in
    while pos + 512 <= x.count {
        let n = min(hop, 4096, x.count - pos)
        let base = p.baseAddress! + pos
        var sq: Float = 0
        for k in 0..<n { sq += base[k] * base[k] }
        let rms = (sq / Float(n)).squareRoot()
        let db = rms > 0 ? 20 * log10(rms) : -100
        let t = Double(pos) / Double(sr)
        var f0: Float? = nil, clarity: Float = 0
        if db >= (Float(ProcessInfo.processInfo.environment["PITCH_FLOOR_DB"] ?? "") ?? PitchCriteria.floorDb) {
            let r = tracker.estimate(base, n: n, sampleRate: sr, t: t)
            f0 = r.f0; clarity = r.clarity
        }
        let f = f0.map { String(format: "%.1f", $0) } ?? "null"
        print("{\"t\":\(String(format: "%.3f", t)),\"rms_db\":\(String(format: "%.1f", db)),\"f0_hz\":\(f),\"clarity\":\(String(format: "%.3f", clarity))}")
        pos += hop
    }
}
