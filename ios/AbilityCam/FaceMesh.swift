import AVFoundation
import MediaPipeTasksVision
import SwiftUI

/// 画面に重ねる顔の網目。点の座標は記録しない
struct FaceMesh {
    let points: [CGPoint]           // 0〜1（解析した画像の中での位置）
    let imageSize: CGSize
    let values: [Metric: Double]    // 表情の数値（0〜1）。線の濃さに使う
}

/// MediaPipe が用意している点のつなぎ方
enum MeshTopology {
    typealias Pairs = [(Int, Int)]

    static let tesselation = pairs(FaceLandmarker.tesselationConnections())
    static let faceOval = pairs(FaceLandmarker.faceOvalConnections())
    static let eyebrows = pairs(FaceLandmarker.leftEyebrowConnections() + FaceLandmarker.rightEyebrowConnections())
    static let eyes = pairs(FaceLandmarker.leftEyeConnections() + FaceLandmarker.rightEyeConnections())
    /// 唇の外側（口角を上げる）と内側（口を開ける）に分ける
    static let lipsOuter = pairs(FaceLandmarker.lipsConnections()).filter { !innerLip.contains($0.0) || !innerLip.contains($0.1) }
    static let lipsInner = pairs(FaceLandmarker.lipsConnections()).filter { innerLip.contains($0.0) && innerLip.contains($0.1) }

    private static let innerLip: Set<Int> = [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308,
                                             95, 88, 178, 87, 14, 317, 402, 318, 324]

    private static func pairs(_ c: [Connection]) -> Pairs { c.map { (Int($0.start), Int($0.end)) } }
}

struct MeshOverlay: View {
    let mesh: FaceMesh
    var fill = false    // プレビューが resizeAspectFill のとき

    var body: some View {
        Canvas { ctx, size in
            guard mesh.imageSize.width > 0 else { return }
            // プレビューと同じ置き方（resizeAspect は余白を除いた領域、resizeAspectFill ははみ出す領域）。背面カメラなので左右反転はしない
            let k = fill ? max(size.width / mesh.imageSize.width, size.height / mesh.imageSize.height)
                         : min(size.width / mesh.imageSize.width, size.height / mesh.imageSize.height)
            let w = mesh.imageSize.width * k, h = mesh.imageSize.height * k
            let r = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            let pts = mesh.points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }

            func path(_ c: MeshTopology.Pairs) -> Path {
                var p = Path()
                for (a, b) in c where a < pts.count && b < pts.count {
                    p.move(to: pts[a]); p.addLine(to: pts[b])
                }
                return p
            }
            func stroke(_ c: MeshTopology.Pairs, _ color: Color, _ m: Metric) {
                let v = min(1, max(0, mesh.values[m] ?? 0))
                ctx.stroke(path(c), with: .color(color.opacity(0.25 + 0.75 * v)), lineWidth: 1.5)
            }

            ctx.stroke(path(MeshTopology.tesselation), with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            ctx.stroke(path(MeshTopology.faceOval), with: .color(.white.opacity(0.55)), lineWidth: 1)
            stroke(MeshTopology.eyebrows, .orange, .browDown)
            stroke(MeshTopology.eyes, .yellow, .eyeSquint)
            stroke(MeshTopology.lipsOuter, .green, .mouthSmile)
            stroke(MeshTopology.lipsInner, .blue, .jawOpen)
        }
        .allowsHitTesting(false)
    }
}
