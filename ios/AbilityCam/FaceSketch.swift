import SwiftUI

/// 動きを写す顔の絵。blendshape の値に比例して形を変えるだけで、表情の名前・色・誇張は付けない
struct FaceSketch: View {
    /// ならした blendshape の値。nil のときは形を中立に戻して灰色で描く
    let shape: [String: Double]?

    static let keys = ["browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
                       "eyeBlinkLeft", "eyeBlinkRight", "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight",
                       "jawOpen", "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight",
                       "mouthPucker", "mouthStretchLeft", "mouthStretchRight"]

    /// MediaPipe の Left/Right は本人から見た左右。背面カメラで向かい合って見ているので、
    /// 本人の左は画面の右に描く（映像と同じ見え方）。実機で逆なら false にする
    static let subjectLeftOnScreenRight = true

    var body: some View {
        Canvas { ctx, size in
            let s = shape ?? [:]
            func v(_ k: String) -> Double { min(1, max(0, s[k] ?? 0)) }
            /// 画面の左（side = -1）・右（+1）の部品に使う名前
            func sided(_ base: String, _ side: Double) -> Double {
                let screenRight = side > 0
                return v(base + (screenRight == Self.subjectLeftOnScreenRight ? "Left" : "Right"))
            }

            let r = min(size.width, size.height) * 0.45
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y + y * r) }
            let color: Color = shape == nil ? .gray.opacity(0.5) : .primary
            let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)

            // 顔の輪郭
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color), style: style)

            for side in [-1.0, 1.0] {
                // 眉：内側は寄せると下がって内へ、browInnerUp で上がる。外側は browOuterUp で上がる
                let down = sided("browDown", side)
                let inner = p(side * (0.16 - 0.06 * down), -0.42 + 0.16 * down - 0.16 * v("browInnerUp"))
                let outer = p(side * 0.56, -0.44 - 0.16 * sided("browOuterUp", side))
                var brow = Path(); brow.move(to: inner); brow.addLine(to: outer)
                ctx.stroke(brow, with: .color(color), style: style)

                // 目：まばたき・細めると縦に細く、見開くと縦に開く
                let open = (1 - 0.85 * sided("eyeBlink", side)) * (1 - 0.5 * sided("eyeSquint", side)) * (1 + 0.6 * sided("eyeWide", side))
                let w = 0.3 * r, h = max(0.02 * r, 0.16 * r * open)
                let ec = p(side * 0.36, -0.14)
                ctx.stroke(Path(ellipseIn: CGRect(x: ec.x - w / 2, y: ec.y - h / 2, width: w, height: h)), with: .color(color), style: style)
            }

            // 口：口角は smile で上がり frown で下がる。stretch で横に広がり、pucker ですぼむ。jawOpen で下唇が下がる
            let pucker = v("mouthPucker")
            func corner(_ side: Double) -> CGPoint {
                let half = 0.3 * (1 + 0.35 * sided("mouthStretch", side)) * (1 - 0.45 * pucker)
                return p(side * half, 0.45 - 0.14 * sided("mouthSmile", side) + 0.14 * sided("mouthFrown", side))
            }
            let left = corner(-1), right = corner(1)
            let midY = p(0, 0.45).y   // 口の中央は動かさず、口角だけを動かす
            var mouth = Path()
            mouth.move(to: left)
            mouth.addQuadCurve(to: right, control: CGPoint(x: c.x, y: midY))
            mouth.addQuadCurve(to: left, control: CGPoint(x: c.x, y: midY + 0.5 * r * v("jawOpen")))
            ctx.stroke(mouth, with: .color(color), style: style)
        }
        .frame(width: 120, height: 120)
        .accessibilityHidden(true)
    }
}
