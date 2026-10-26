import AVFoundation
import QuartzCore
import MediaPipeTasksVision

/// MediaPipe Face Landmarker（背面カメラでも52種の表情の数値が取れる）
final class FaceAnalyzer: NSObject, FaceLandmarkerLiveStreamDelegate {
    enum AnalyzerError: LocalizedError {
        case modelMissing
        var errorDescription: String? { "表情解析モデル（face_landmarker.task）がありません。ios/setup.sh を実行してください" }
    }

    struct Result {
        let captureMs: Int          // 撮影された時刻（端末の起動からの ms、CACurrentMediaTime と同じ時計）
        let face: Bool
        let blendshapes: [String: Float]
        let keyPoints: [[Float]]    // 鍵となる顔の点 [x, y, z]
        let mesh: [CGPoint]         // 全478点の (x, y)、0〜1。画面の網目だけに使い、記録には入れない
        let imageSize: CGSize       // 解析した画像の大きさ（縦向き）
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

    func faceLandmarker(_ faceLandmarker: FaceLandmarker,
                        didFinishDetection result: FaceLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        let now = CACurrentMediaTime()
        lock.lock(); let sent = sentAt.removeValue(forKey: timestampInMilliseconds); let size = imageSize; lock.unlock()

        var bs: [String: Float] = [:]
        var pts: [[Float]] = []
        var mesh: [CGPoint] = []
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
        }
        onResult?(Result(
            captureMs: timestampInMilliseconds,
            face: !(lms?.isEmpty ?? true),
            blendshapes: bs,
            keyPoints: pts,
            mesh: mesh,
            imageSize: size,
            procMs: sent.map { (now - $0) * 1000 } ?? -1,
            latMs: now * 1000 - Double(timestampInMilliseconds)
        ))
    }
}
