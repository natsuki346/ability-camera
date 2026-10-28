import SwiftUI

/// 絵の色。数値によって色は変えない（気分に見える表現をしない）
enum SketchTone: String, CaseIterable, Identifiable {
    case medium = "中間", light = "明るめ", deep = "濃いめ", none = "肌色なし"
    var id: String { rawValue }

    var palette: SketchPalette {
        switch self {
        case .medium: SketchPalette(skin: 0xE2BE9C, line: 0x6B5448, brow: 0x6E5547, lip: 0xB98577)
        case .light: SketchPalette(skin: 0xF0D9C4, line: 0x75604F, brow: 0x7A6050, lip: 0xC99686)
        case .deep: SketchPalette(skin: 0xA97D5D, line: 0x4E3A30, brow: 0x4A372D, lip: 0x8C5E50, sclera: 0xEFE8DF)
        case .none: SketchPalette(skin: 0xE6E2DC, line: 0x5E5852, brow: 0x625A54, lip: 0xBDB3AA)
        }
    }
}

struct SketchPalette {
    var skin: Color, line: Color, brow: Color, lip: Color
    var iris = Color(hex: 0x6F6258), pupil = Color(hex: 0x2F2926), mouth = Color(hex: 0x7A4E48)
    var sclera = Color(hex: 0xF6F1EA), background = Color(hex: 0xF2EDE7)

    init(skin: UInt32, line: UInt32, brow: UInt32, lip: UInt32, sclera: UInt32 = 0xF6F1EA) {
        self.skin = Color(hex: skin); self.line = Color(hex: line); self.brow = Color(hex: brow); self.lip = Color(hex: lip)
        self.sclera = Color(hex: sclera)
    }

    /// 顔が読めないとき：灰色
    static let unreadable: SketchPalette = {
        var p = SketchPalette(skin: 0xE4E4E4, line: 0xB0B0B0, brow: 0xB5B5B5, lip: 0xCFCFCF, sclera: 0xF0F0F0)
        p.iris = Color(hex: 0xBDBDBD); p.pupil = Color(hex: 0xA8A8A8); p.mouth = Color(hex: 0xC8C8C8)
        p.background = Color(hex: 0xEEEEEE)
        return p
    }()
}

/// 動きを写す顔の絵。blendshape の値に比例して形を変えるだけで、表情の名前・色・誇張は付けない
struct FaceSketch: View {
    /// ならした blendshape の値。nil のときは形を中立に戻して灰色で描く
    let shape: [String: Double]?
    var size: CGFloat = 120
    var tone: SketchTone = .medium

    /// 左右がこれを超えると、表情の数値は当てにならない
    static let sideLimit = 35.0

    // 絵は映像と同じ見え方（向かい合って見る）で描く。値の yaw・roll は本人から見て右が +（v1.7.1〜）なので、描くときは符号を反対にする
    var yaw: Double { -(shape?["yaw"] ?? 0) }
    var pitch: Double { shape?["pitch"] ?? 0 }
    var roll: Double { -(shape?["roll"] ?? 0) }
    var turnedAway: Bool { abs(yaw) > Self.sideLimit }

    /// 「右 25°・下 10°（本人から見て）」のような事実だけ。15°未満は出さず、どれも無ければ「正面」。
    /// 右・左は本人から見た向き（v1.7.1〜）。右・左が入るときは「（本人から見て）」を付ける
    static func directionText(_ shape: [String: Double]) -> String {
        func part(_ v: Double?, _ plus: String, _ minus: String) -> String? {
            guard let v, abs(v) >= 15 else { return nil }
            return "\(v > 0 ? plus : minus) \(Int(abs(v).rounded()))°"
        }
        let parts = [part(shape["yaw"], "右", "左"), part(shape["pitch"], "上", "下"),
                     part(shape["roll"], "右に傾き", "左に傾き")].compactMap { $0 }
        let sided = [shape["yaw"], shape["roll"]].contains { ($0.map(abs) ?? 0) >= 15 }
        return parts.isEmpty ? "正面" : parts.joined(separator: "・") + (sided ? "（\(FaceDirection.note)）" : "")
    }

    static let keys = ["browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
                       "eyeBlinkLeft", "eyeBlinkRight", "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight",
                       "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight",
                       "eyeLookUpLeft", "eyeLookUpRight", "eyeLookDownLeft", "eyeLookDownRight",
                       "noseSneerLeft", "noseSneerRight",
                       "jawOpen", "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight",
                       "mouthPucker", "mouthStretchLeft", "mouthStretchRight"]

    /// MediaPipe の Left/Right は本人から見た左右。背面カメラで向かい合って見ているので、
    /// 本人の左は画面の右に描く（前面カメラも左右反転せずに解析するので同じ、v1.5〜）（映像と同じ見え方）。実機で逆なら false にする
    static let subjectLeftOnScreenRight = true

    var body: some View {
        let pal = shape == nil ? SketchPalette.unreadable : tone.palette
        Canvas { ctx, sz in
            draw(&ctx, sz, pal)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(roll))   // 頭の上が映像の右へ傾く（本人から見て左へ傾く）＝時計回り
        .background(RoundedRectangle(cornerRadius: size * 0.12).fill(pal.background))
        .accessibilityHidden(true)
    }

    // 座標は顔の大きさ r を 1 とした (x 右, y 下, z 手前)。部品は奥行きを持たせ、yaw・pitch で回して映す
    private func draw(_ ctx: inout GraphicsContext, _ sz: CGSize, _ pal: SketchPalette) {
        let s = shape ?? [:]
        func v(_ k: String) -> Double { min(1, max(0, s[k] ?? 0)) }
        /// 画面の左（side = -1）・右（+1）の部品に使う値
        func sided(_ base: String, _ side: Double) -> Double {
            v(base + ((side > 0) == Self.subjectLeftOnScreenRight ? "Left" : "Right"))
        }

        let r = Double(min(sz.width, sz.height)) * 0.40
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let rad = Double.pi / 180
        let yw = max(-50, min(50, yaw)) * rad, pt = max(-40, min(40, pitch)) * rad
        let cy = cos(yw), sy = sin(yw), cp = cos(pt), sp = sin(pt)
        func P(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            // 奥行きは少し浅く（横を向いても部品が輪郭の外へ出ないように）
            let x1 = x * cy + z * 0.8 * sy, z1 = -x * sy + z * cy
            return CGPoint(x: c.x + x1 * r, y: c.y + (y * cp - z1 * sp) * r)
        }
        func depth(_ x: Double, _ z: Double) -> Double { -x * sy + z * cy }
        /// 輪郭は頭の形（ほぼ球）なので大きくは回さず、あごのあたりだけ少しずらす
        func Q(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            CGPoint(x: c.x + (x + z * sy * 0.35) * r, y: c.y + (y - z * sp * 0.35) * r)
        }
        let lw = r / 45
        func stroke(_ p: Path, _ color: Color, _ w: Double, opacity: Double = 1) {
            ctx.stroke(p, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: w * lw, lineCap: .round, lineJoin: .round))
        }

        let jaw = v("jawOpen")

        // 耳：奥側は顔の後ろに隠れるよう先に、手前側は顔の上に後から描く
        func ear(_ side: Double) {
            let pts = [P(side * 0.80, -0.14, -0.05), P(side * 0.93, -0.12, -0.12), P(side * 0.95, 0.06, -0.14),
                       P(side * 0.88, 0.24, -0.10), P(side * 0.79, 0.27, -0.04)]
            let outer = Self.curve(pts)
            var shapePath = Self.polyline(outer); shapePath.closeSubpath()
            ctx.fill(shapePath, with: .color(pal.skin))
            stroke(Self.polyline(outer), pal.line, 1.1)
            stroke(Self.polyline(Self.curve([P(side * 0.86, -0.06, -0.09), P(side * 0.89, 0.06, -0.11), P(side * 0.84, 0.17, -0.07)])),
                   pal.line, 0.6, opacity: 0.6)
        }
        let earsFront = [-1.0, 1.0].filter { depth($0 * 0.9, -0.1) > 0.15 }
        for side in [-1.0, 1.0] where !earsFront.contains(side) { ear(side) }

        // 輪郭：額からほお、あご（jawOpen で少し下がる）
        var outline: [CGPoint] = []
        let half: [(Double, Double, Double)] = [(0.0, -1.02, 0.0), (0.55, -0.88, 0.1), (0.80, -0.45, 0.15), (0.82, 0.05, 0.2),
                                                (0.74, 0.45, 0.3), (0.50, 0.80 + 0.06 * jaw, 0.5)]
        for (x, y, z) in half { outline.append(Q(x, y, z)) }
        outline.append(Q(0, 0.98 + 0.10 * jaw, 0.7))
        for (x, y, z) in half.dropFirst().reversed() { outline.append(Q(-x, y, z)) }
        var face = Self.polyline(Self.curve(outline, closed: true)); face.closeSubpath()
        ctx.fill(face, with: .color(pal.skin))
        stroke(face, pal.line, 1.3)
        for side in earsFront { ear(side) }

        // 横を向いているときは、表情の部分を薄くする（参考程度）
        if turnedAway { ctx.opacity = 0.3 }

        for side in [-1.0, 1.0] {
            // 眉：眉頭は browDown で下がって内へ、browInnerUp で上がる。眉尻は browOuterUp で上がる。眉頭が太く眉尻へ細く
            let down = sided("browDown", side), innerUp = v("browInnerUp"), outerUp = sided("browOuterUp", side)
            let head = (x: side * (0.13 - 0.03 * down), y: -0.30 + 0.07 * down - 0.08 * innerUp, z: 0.72)
            let mid = (x: side * 0.30, y: -0.37 + 0.03 * down - 0.03 * innerUp - 0.04 * outerUp, z: 0.68)
            let tail = (x: side * 0.47, y: -0.31 - 0.08 * outerUp, z: 0.52)
            let top = Self.curve([P(head.x, head.y - 0.022, head.z), P(mid.x, mid.y - 0.017, mid.z), P(tail.x, tail.y, tail.z)])
            let bottom = Self.curve([P(tail.x, tail.y + 0.006, tail.z), P(mid.x, mid.y + 0.016, mid.z), P(head.x, head.y + 0.020, head.z)])
            var brow = Self.polyline(top + bottom); brow.closeSubpath()
            ctx.fill(brow, with: .color(pal.brow))
            // 眉頭の毛の流れ（短い斜めの線）
            for k in 0..<4 {
                let f = Double(k) / 3 * 0.35
                let bx = head.x + (mid.x - head.x) * f, by = head.y + (mid.y - head.y) * f
                var hair = Path()
                hair.move(to: P(bx, by + 0.018, head.z))
                hair.addLine(to: P(bx + side * 0.03, by - 0.03, head.z))
                stroke(hair, pal.brow, 0.7, opacity: 0.8)
            }

            // 目：上まぶたと下まぶたの弧。まばたき・細めは弧が閉じる形で、見開きで開く
            let blink = sided("eyeBlink", side), squint = sided("eyeSquint", side), wide = sided("eyeWide", side)
            let upH = 0.085 * (1 - 0.92 * blink) * (1 - 0.35 * squint) * (1 + 0.45 * wide)
            let loH = 0.045 * (1 - 0.92 * blink) * (1 - 0.55 * squint) * (1 + 0.2 * wide)
            let ex = side * 0.31, ey = -0.10, ez = 0.72
            let inner = (x: side * 0.19, y: ey + 0.012), outer = (x: side * 0.43, y: ey - 0.008)
            let upper = Self.curve([P(inner.x, inner.y, 0.74), P(side * 0.25, ey - upH * 0.9, ez + 0.03),
                                    P(side * 0.34, ey - upH, ez + 0.02), P(outer.x, outer.y, 0.64)])
            let lower = Self.curve([P(outer.x, outer.y, 0.64), P(side * 0.33, ey + loH, ez),
                                    P(side * 0.24, ey + loH * 0.85, ez + 0.02), P(inner.x, inner.y, 0.74)])
            var opening = Self.polyline(upper + lower); opening.closeSubpath()
            if upH > 0.006 {
                ctx.fill(opening, with: .color(pal.sclera))
                // 視線：eyeLookOut は目の外側（鼻から遠い側）へ、In は内側へ。Up/Down は上下へ
                let gx = side * (sided("eyeLookOut", side) - sided("eyeLookIn", side)) * 0.055
                let gy = (sided("eyeLookDown", side) - sided("eyeLookUp", side)) * 0.04
                let ic = P(ex + gx, ey - 0.01 + gy, ez + 0.03)
                var inside = ctx
                inside.clip(to: opening)
                let ir = 0.058 * r, pr = 0.026 * r
                inside.fill(Path(ellipseIn: CGRect(x: ic.x - ir, y: ic.y - ir, width: 2 * ir, height: 2 * ir)), with: .color(pal.iris))
                inside.fill(Path(ellipseIn: CGRect(x: ic.x - pr, y: ic.y - pr, width: 2 * pr, height: 2 * pr)), with: .color(pal.pupil))
                let hr = 0.011 * r
                inside.fill(Path(ellipseIn: CGRect(x: ic.x + ir * 0.3 - hr, y: ic.y - ir * 0.35 - hr, width: 2 * hr, height: 2 * hr)),
                            with: .color(.white.opacity(0.8)))
                // 二重のしわ（うすく）
                stroke(Self.polyline(Self.curve([P(side * 0.22, ey - upH - 0.012, ez), P(side * 0.32, ey - upH - 0.035, ez),
                                                  P(side * 0.41, ey - upH * 0.6 - 0.02, 0.65)])), pal.line, 0.6, opacity: 0.35)
            }
            stroke(Self.polyline(upper), pal.line, 1.5)
            stroke(Self.polyline(lower), pal.line, 0.7, opacity: 0.6)
        }

        // 鼻：控えめな線。noseSneer で小鼻が少し上がる
        stroke(Self.polyline(Self.curve([P(0.04, -0.04, 0.88), P(0.06, 0.10, 0.97), P(0.03, 0.20, 1.0)])), pal.line, 0.8, opacity: 0.45)
        for side in [-1.0, 1.0] {
            let sneer = sided("noseSneer", side)
            stroke(Self.polyline(Self.curve([P(side * 0.09, 0.19 - 0.03 * sneer, 0.86), P(side * 0.085, 0.24 - 0.015 * sneer, 0.9),
                                              P(side * 0.035, 0.25, 0.97)])), pal.line, 0.9, opacity: 0.7)
        }
        stroke(Self.polyline(Self.curve([P(-0.03, 0.25, 0.98), P(0, 0.262, 1.0), P(0.03, 0.25, 0.98)])), pal.line, 0.7, opacity: 0.5)

        // 口：上唇と下唇。口角は smile で上がり frown で下がる。stretch で横に、pucker ですぼむ。jawOpen で開く
        let pucker = v("mouthPucker")
        let y0 = 0.50, open = 0.20 * jaw
        let upTh = 0.035 * (1 + 0.4 * pucker), loTh = 0.045 * (1 + 0.4 * pucker)
        func corner(_ side: Double) -> CGPoint {
            let x = side * 0.20 * (1 + 0.3 * sided("mouthStretch", side)) * (1 - 0.35 * pucker)
            return P(x, y0 - 0.06 * sided("mouthSmile", side) + 0.06 * sided("mouthFrown", side) + 0.03 * jaw, 0.72)
        }
        let L = corner(-1), R = corner(1)
        let zc = 0.86 + 0.05 * pucker
        let w = 1 - 0.35 * pucker
        let upperIn = Self.curve([L, P(-0.08 * w, y0 - 0.004, zc), P(0, y0, zc), P(0.08 * w, y0 - 0.004, zc), R])
        let lowerIn = Self.curve([L, P(-0.09 * w, y0 + open * 0.85, zc), P(0, y0 + open, zc), P(0.09 * w, y0 + open * 0.85, zc), R])
        let upperOut = Self.curve([L, P(-0.10 * w, y0 - upTh * 0.9, zc), P(-0.035 * w, y0 - upTh * 1.15, zc + 0.01),
                                   P(0, y0 - upTh * 0.8, zc + 0.01), P(0.035 * w, y0 - upTh * 1.15, zc + 0.01),
                                   P(0.10 * w, y0 - upTh * 0.9, zc), R])
        let lowerOut = Self.curve([L, P(-0.10 * w, y0 + open + loTh * 0.9, zc), P(0, y0 + open + loTh * 1.15, zc + 0.01),
                                   P(0.10 * w, y0 + open + loTh * 0.9, zc), R])
        if open > 0.004 {
            var inside = Self.polyline(upperIn + lowerIn.reversed()); inside.closeSubpath()
            ctx.fill(inside, with: .color(pal.mouth))
        }
        var upLip = Self.polyline(upperOut + upperIn.reversed()); upLip.closeSubpath()
        var loLip = Self.polyline(lowerIn + lowerOut.reversed()); loLip.closeSubpath()
        ctx.fill(upLip, with: .color(pal.lip))
        ctx.fill(loLip, with: .color(pal.lip))
        stroke(Self.polyline(upperOut), pal.line, 0.5, opacity: 0.35)
        stroke(Self.polyline(lowerOut), pal.line, 0.5, opacity: 0.3)
        stroke(Self.polyline(upperIn), pal.line, 1.2, opacity: 0.85)
        if open > 0.004 { stroke(Self.polyline(lowerIn), pal.line, 0.8, opacity: 0.6) }
    }

    /// 点を滑らかにつなぐ（Catmull-Rom を細かく区切った点の列）
    private static func curve(_ pts: [CGPoint], closed: Bool = false, steps: Int = 8) -> [CGPoint] {
        let n = pts.count
        guard n > 2 else { return pts }
        var out: [CGPoint] = []
        let segs = closed ? n : n - 1
        for i in 0..<segs {
            let p0 = pts[closed ? (i - 1 + n) % n : max(i - 1, 0)], p1 = pts[i]
            let p2 = pts[(i + 1) % n], p3 = pts[closed ? (i + 2) % n : min(i + 2, n - 1)]
            for k in 0..<steps {
                let t = Double(k) / Double(steps), t2 = t * t, t3 = t2 * t
                func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        if !closed { out.append(pts[n - 1]) }
        return out
    }

    private static func polyline(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        return p
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
