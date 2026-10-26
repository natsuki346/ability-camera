import AVFoundation
import QuartzCore
import MediaPipeTasksVision

/// MediaPipe Face Landmarker（背面カメラでも52種の表情の数値が取れる）
final class FaceAnalyzer: NSObject, FaceLandmarkerLiveStreamDelegate {
    enum AnalyzerError: LocalizedError {
        case modelMissing
        var errorDescription: String? { "表情解析モデル（face_landmarker.task）がありません。ios/setup.sh を実行してください" }
    }

    /// 顔の向き（度）。映像で見て右を向く＝yaw +、上を向く＝pitch +、頭の上が映像の右へ傾く＝roll +
    struct Pose { let yaw: Double; let pitch: Double; let roll: Double }

    struct Result {
        let captureMs: Int          // 撮影された時刻（端末の起動からの ms、CACurrentMediaTime と同じ時計）
        let face: Bool
        let blendshapes: [String: Float]
        let keyPoints: [[Float]]    // 鍵となる顔の点 [x, y, z]
        let mesh: [CGPoint]         // 全478点の (x, y)、0〜1。画面の網目だけに使い、記録には入れない
        let imageSize: CGSize       // 解析した画像の大きさ（縦向き）
        let pose: Pose?
        let procMs: Double          // 解析に渡してから結果が返るまで
        let latMs: Double           // 撮影されてから結果が返るまで
    }

    /// 鼻先・額・あご・両目尻・両口角（追跡の安定性を後で確かめる用）
    static let keyPointIndices = [1, 10, 152, 33, 263, 61, 291]

    private var landmarker: FaceLandmarker?
    private var sentAt: [Int: CFTimeInterval] = [:]
    private var lastTs = -1
    private var imageSize = CGSize.zero
    private let lock = NSLock()

    /// MediaPipe のスレッドから呼ばれる
    var onResult: ((Result) -> Void)?

    override init() {
        super.init()
    }

    func load() throws {
        guard landmarker == nil else { return }
        guard let path = Bundle.main.path(forResource: "face_landmarker", ofType: "task") else {
            throw AnalyzerError.modelMissing
        }
        let o = FaceLandmarkerOptions()
        o.baseOptions.modelAssetPath = path
        o.runningMode = .liveStream
        o.numFaces = 1
        o.outputFaceBlendshapes = true
        o.outputFacialTransformationMatrixes = true
        o.faceLandmarkerLiveStreamDelegate = self
        landmarker = try FaceLandmarker(options: o)
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let landmarker else { return }
        let ms = Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)
        lock.lock()
        guard ms > lastTs else { lock.unlock(); return }   // 時刻は必ず増えていく必要がある
        lastTs = ms
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            imageSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        }
        sentAt[ms] = CACurrentMediaTime()
        sentAt = sentAt.filter { $0.key > ms - 3000 }      // 返ってこなかったコマの分を掃除
        lock.unlock()

        do {
            let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .up)
            try landmarker.detectAsync(image: image, timestampInMilliseconds: ms)
        } catch {
            lock.lock(); sentAt[ms] = nil; lock.unlock()
        }
    }

    /// 変換行列（標準の顔 → カメラの座標。x 右・y 上・z 手前）から向きを求める
    static func pose(_ m: TransformMatrix) -> Pose? {
        guard m.rows >= 3, m.columns >= 3 else { return nil }
        // 平行移動（顔までの距離）が入っている側で、行と列の並びを見分ける
        let transposed = m.rows == 4 && m.columns == 4 && abs(m.value(atRow: 3, column: 2)) > abs(m.value(atRow: 2, column: 3))
        func r(_ i: Int, _ j: Int) -> Double { Double(transposed ? m.value(atRow: UInt(j), column: UInt(i)) : m.value(atRow: UInt(i), column: UInt(j))) }
        // 顔の正面の向き（標準の顔の +z）と、頭の上の向き（+y）
        let fx = r(0, 2), fy = r(1, 2), fz = r(2, 2)
        let ux = r(0, 1), uy = r(1, 1)
        let deg = 180 / Double.pi
        return Pose(yaw: atan2(fx, fz) * deg,
                    pitch: atan2(fy, (fx * fx + fz * fz).squareRoot()) * deg,
                    roll: atan2(ux, uy) * deg)
    }

    func faceLandmarker(_ faceLandmarker: FaceLandmarker,
                        didFinishDetection result: FaceLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        let now = CACurrentMediaTime()
        lock.lock(); let sent = sentAt.removeValue(forKey: timestampInMilliseconds); let size = imageSize; lock.unlock()

        var bs: [String: Float] = [:]
        var pts: [[Float]] = []
        var mesh: [CGPoint] = []
        var pose: Pose?
        let lms = result?.faceLandmarks.first
        if let lms, !lms.isEmpty {
            for c in result?.faceBlendshapes.first?.categories ?? [] {
                if let name = c.categoryName { bs[name] = (c.score * 1000).rounded() / 1000 }
            }
            pts = Self.keyPointIndices.compactMap { i in
                guard i < lms.count else { return nil }
                let p = lms[i]
                return [p.x, p.y, p.z].map { ($0 * 10000).rounded() / 10000 }
            }
            mesh = lms.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            pose = result?.facialTransformationMatrixes.first.flatMap(Self.pose)
        }
        onResult?(Result(
            captureMs: timestampInMilliseconds,
            face: !(lms?.isEmpty ?? true),
            blendshapes: bs,
            keyPoints: pts,
            mesh: mesh,
            imageSize: size,
            pose: pose,
            procMs: sent.map { (now - $0) * 1000 } ?? -1,
            latMs: now * 1000 - Double(timestampInMilliseconds)
        ))
    }
}
