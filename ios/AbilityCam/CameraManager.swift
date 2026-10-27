import AVFoundation

/// 撮る側の設定「カメラ」。初めは広角（今まで通り）
enum CameraLens: String, CaseIterable, Identifiable {
    case wide = "wide", ultraWide = "ultra_wide"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .wide: "広角"
        case .ultraWide: "超広角"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide: .builtInWideAngleCamera
        case .ultraWide: .builtInUltraWideCamera
        }
    }

    var available: Bool { AVCaptureDevice.default(deviceType, for: .video, position: .back) != nil }

    /// 設定に保存してある値（無い・使えなければ広角）
    static var selected: CameraLens {
        CameraLens(rawValue: UserDefaults.standard.string(forKey: "cameraLens") ?? "") ?? .wide
    }
}

/// 背面カメラの映像を1コマずつ受け取る。映像そのものは保存しない。
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CameraError: LocalizedError {
        case noCamera
        var errorDescription: String? { "背面カメラが見つかりません" }
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
        guard let device = AVCaptureDevice.default(use.deviceType, for: .video, position: .back) else {
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

    /// 縦持ちの向きで解析する
    private func applyRotation() {
        if let c = output?.connection(with: .video), c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
    }

    func start() { sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop()  { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
