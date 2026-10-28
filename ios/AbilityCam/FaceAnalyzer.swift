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

    /// 顔の枠：中心 x・y と幅（解析した画像の中で 0〜1）
    struct Box { let cx: Double; let cy: Double; let w: Double }

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
        let faceCount: Int          // 映っていた顔の数（numFaces まで）
        let box: Box?               // 本人として使った顔の枠
    }

    /// 鼻先・額・あご・両目尻・両口角（追跡の安定性を後で確かめる用）
    static let keyPointIndices = [1, 10, 152, 33, 263, 61, 291]

    private var landmarker: FaceLandmarker?
    /// 一度に探す顔の数（v1.2〜は2。解析コマ/秒が落ちるときは1に戻す）
    private(set) var numFaces = 2
    /// 2つ映ったときに本人として選ぶ、普段の顔の位置と大きさ（無いときは大きいほう）
    private var preferred: (box: Box, sd: Box)?
    private var sentAt: [Int: CFTimeInterval] = [:]
    private var lastTs = -1
    private var submitted = 0      // 解析に渡したコマの数（解析コマ/秒が落ちていないか見る）
    private var imageSize = CGSize.zero
    private var mirrored = false   // 解析に渡す映像が鏡（前面カメラ）。記録の値を背面と同じ意味に直す（v1.6.1〜）
    private let lock = NSLock()

    /// 届いた映像の大きさ（横長なら、カメラに回転を決め直させる）
    var onImageSize: ((CGSize) -> Void)?

    /// MediaPipe のスレッドから呼ばれる
    var onResult: ((Result) -> Void)?

    override init() {
        super.init()
    }

    func submittedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return submitted
    }

    /// 普段の顔の位置と大きさ（標準偏差には下限 0.05 をかける）
    func setPreferred(_ s: FaceBoxStats?) {
        lock.lock(); defer { lock.unlock() }
        preferred = s.map { (Box(cx: $0.cx.mean, cy: $0.cy.mean, w: $0.w.mean),
                             Box(cx: max($0.cx.std, 0.05), cy: max($0.cy.std, 0.05), w: max($0.w.std, 0.05))) }
    }

    func setMirrored(_ m: Bool) {
        lock.lock(); mirrored = m; lock.unlock()
    }

    /// 鏡の映像で取れた値を、背面（鏡でない映像）と同じ意味に直す：左右の表情の名前を入れ替える
    static func unmirrorBlendshapes(_ bs: [String: Float]) -> [String: Float] {
        var out: [String: Float] = [:]
        for (k, v) in bs {
            if k.hasSuffix("Left") { out[String(k.dropLast(4)) + "Right"] = v }
            else if k.hasSuffix("Right") { out[String(k.dropLast(5)) + "Left"] = v }
            else { out[k] = v }
        }
        return out
    }

    /// 探す顔の数を変える（作り直す）
    func setNumFaces(_ n: Int) throws {
        lock.lock()
        let changed = n != numFaces
        numFaces = n
        if changed { landmarker = nil }
        lock.unlock()
        if changed { try load() }
    }

    func load() throws {
        lock.lock()
        let has = landmarker != nil, n = numFaces
        lock.unlock()
        guard !has else { return }
        guard let path = Bundle.main.path(forResource: "face_landmarker", ofType: "task") else {
            throw AnalyzerError.modelMissing
        }
        let o = FaceLandmarkerOptions()
        o.baseOptions.modelAssetPath = path
        o.runningMode = .liveStream
        o.numFaces = n
        o.outputFaceBlendshapes = true
        o.outputFacialTransformationMatrixes = true
        o.faceLandmarkerLiveStreamDelegate = self
        let lm = try FaceLandmarker(options: o)
        lock.lock(); landmarker = lm; lock.unlock()
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        let ms = Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)
        lock.lock()
        guard let landmarker else { lock.unlock(); return }
        guard ms > lastTs else { lock.unlock(); return }   // 時刻は必ず増えていく必要がある
        lastTs = ms
        submitted += 1
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            imageSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        }
        let size = imageSize
        sentAt[ms] = CACurrentMediaTime()
        sentAt = sentAt.filter { $0.key > ms - 3000 }      // 返ってこなかったコマの分を掃除
        lock.unlock()
        onImageSize?(size)

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
        lock.lock()
        let sent = sentAt.removeValue(forKey: timestampInMilliseconds), size = imageSize, pref = preferred, mir = mirrored
        lock.unlock()

        // 顔が2つ映ったら、普段の位置・大きさに近いほうを本人として使う（普段がまだ無ければ大きいほう）
        let faces = result?.faceLandmarks ?? []
        let boxes: [Box?] = faces.map { lms in
            guard !lms.isEmpty else { return nil }
            let xs = lms.map { Double($0.x) }, ys = lms.map { Double($0.y) }
            let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
            let cx = (x0 + x1) / 2
            return Box(cx: mir ? 1 - cx : cx, cy: (y0 + y1) / 2, w: x1 - x0)   // 鏡なら、背面と同じ向きの位置にする
        }
        var pick = 0
        if boxes.count > 1 {
            func dist(_ b: Box?) -> Double {
                guard let b else { return .infinity }
                guard let p = pref else { return -b.w }
                let dx = (b.cx - p.box.cx) / p.sd.cx, dy = (b.cy - p.box.cy) / p.sd.cy, dw = (b.w - p.box.w) / p.sd.w
                return dx * dx + dy * dy + dw * dw
            }
            pick = boxes.indices.min { dist(boxes[$0]) < dist(boxes[$1]) } ?? 0
        }

        var bs: [String: Float] = [:]
        var pts: [[Float]] = []
        var mesh: [CGPoint] = []
        var pose: Pose?
        let lms = faces.indices.contains(pick) ? faces[pick] : nil   // 網目（画面だけ）は映像のままの座標（プレビューも同じ鏡）
        if let lms, !lms.isEmpty {
            let blend = result?.faceBlendshapes ?? []
            for c in (blend.indices.contains(pick) ? blend[pick] : blend.first)?.categories ?? [] {
                if let name = c.categoryName { bs[name] = (c.score * 1000).rounded() / 1000 }
            }
            pts = Self.keyPointIndices.compactMap { i in
                guard i < lms.count else { return nil }
                let p = lms[i]
                return [mir ? 1 - p.x : p.x, p.y, p.z].map { ($0 * 10000).rounded() / 10000 }
            }
            if mir, pts.count == Self.keyPointIndices.count {   // 両目尻・両口角の左右を入れ替える（背面と同じ並び）
                pts.swapAt(3, 4); pts.swapAt(5, 6)
            }
            if mir { bs = Self.unmirrorBlendshapes(bs) }
            mesh = lms.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            let mats = result?.facialTransformationMatrixes ?? []
            pose = (mats.indices.contains(pick) ? mats[pick] : mats.first).flatMap(Self.pose)
            if mir, let p = pose { pose = Pose(yaw: -p.yaw, pitch: p.pitch, roll: -p.roll) }   // 鏡の映像の左右を直す
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
            latMs: now * 1000 - Double(timestampInMilliseconds),
            faceCount: boxes.compactMap { $0 }.count,
            box: boxes.indices.contains(pick) ? boxes[pick] : nil
        ))
    }
}
