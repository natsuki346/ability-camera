import AVFoundation

/// 撮る側の設定「カメラ」。初めは広角（今まで通り）。前面は自分で試す用（胸に着けて使うのは背面、v1.5〜）
enum CameraLens: String, CaseIterable, Identifiable {
    case wide = "wide", ultraWide = "ultra_wide", front = "front"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .wide: "広角"
        case .ultraWide: "超広角"
        case .front: "前面（自分で試す用）"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide, .front: .builtInWideAngleCamera
        case .ultraWide: .builtInUltraWideCamera
        }
    }

    var position: AVCaptureDevice.Position { self == .front ? .front : .back }

    var available: Bool { AVCaptureDevice.default(deviceType, for: .video, position: position) != nil }

    /// 設定に保存してある値（無い・使えなければ広角）
    static var selected: CameraLens {
        CameraLens(rawValue: UserDefaults.standard.string(forKey: "cameraLens") ?? "") ?? .wide
    }
}

/// カメラの映像を1コマずつ受け取る。映像そのものは保存しない。
/// 前面カメラでも左右反転（鏡の見え方）はしない：背面で向かい合った人を撮ったときと同じ向き（本人の左＝映像の右）で解析し、
/// 画面の映像も同じ向きにする。顔の絵・顔の向き（yaw）・左右の表情の数値が、背面のときと同じ意味になる（v1.5〜）
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CameraError: LocalizedError {
        case noCamera
        var errorDescription: String? { "カメラが見つかりません" }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private var configured = false
    private var output: AVCaptureVideoDataOutput?
    private var input: AVCaptureDeviceInput?
    /// 今使っているカメラ（超広角が無い端末では、選んでいても広角）
    private(set) var lens = CameraLens.wide

    /// カメラのスレッドから呼ばれる
    var onFrame: ((CMSampleBuffer) -> Void)?

    /// 初めの1回だけ組み立てる。使ったカメラを返す
    @discardableResult
    func configureIfNeeded(lens wanted: CameraLens) throws -> CameraLens {
        guard !configured else { return lens }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        try setInput(wanted)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true   // 遅れたコマは捨てる（即時性を優先）
        output.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        self.output = output
        applyRotation()
        configured = true
        return lens
    }

    /// 広角／超広角を切り替える（動いたままでよい）。使ったカメラを返す
    func switchLens(_ wanted: CameraLens) throws -> CameraLens {
        guard configured else { return try configureIfNeeded(lens: wanted) }
        let target = wanted.available ? wanted : .wide
        guard target != lens else { return lens }
        return try sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try setInput(target)
            applyRotation()   // 入力を替えるとつながりが作り直されるので、向きをもう一度
            return lens
        }
    }

    private func setInput(_ wanted: CameraLens) throws {
        let use = wanted.available ? wanted : .wide
        guard let device = AVCaptureDevice.default(use.deviceType, for: .video, position: use.position) else {
            throw CameraError.noCamera
        }
        let new = try AVCaptureDeviceInput(device: device)
        if let old = input { session.removeInput(old) }
        if session.canAddInput(new) {
            session.addInput(new)
            input = new
            lens = use
        } else if let old = input, session.canAddInput(old) {
            session.addInput(old)   // 替えられなかったら元に戻す
        }
    }

    /// 縦持ちの向きで解析する。前面でも左右反転しない（背面と同じ向き）
    private func applyRotation() {
        guard let c = output?.connection(with: .video) else { return }
        if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        Self.unmirror(c)
    }

    /// 左右反転を切る（前面カメラは、自動にしておくと鏡の見え方になることがある）
    static func unmirror(_ c: AVCaptureConnection) {
        guard c.isVideoMirroringSupported else { return }
        if c.automaticallyAdjustsVideoMirroring { c.automaticallyAdjustsVideoMirroring = false }
        if c.isVideoMirrored { c.isVideoMirrored = false }
    }

    func start() { sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop()  { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
