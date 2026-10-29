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

    /// 短い名前（設定の「人」のカメラごとの普段）
    var shortLabel: String { self == .front ? "前面" : label }

    var position: AVCaptureDevice.Position { self == .front ? .front : .back }

    var available: Bool { AVCaptureDevice.default(deviceType, for: .video, position: position) != nil }

    /// 設定に保存してある値（無い・使えなければ広角）
    static var selected: CameraLens {
        CameraLens(rawValue: UserDefaults.standard.string(forKey: "cameraLens") ?? "") ?? .wide
    }
}

/// カメラの映像を1コマずつ受け取る。映像そのものは保存しない。
/// 映像の向き（v1.6.1〜、camera_orientation_version 2）：
/// - 解析に渡す映像の回転は、カメラの組み替え（入力の付け替え）が終わってから決める（v1.5 は組み替えの途中で決めていて、前面に替えたとき効いていなかった）
/// - 背面は今まで通り 90°（縦持ち）。前面は RotationCoordinator が出す、水平を保つ角度
/// - 届いた映像が横長なら、もう一度回転を決め直す
/// - 左右反転（鏡）は、解析とプレビューで同じにする（どちらもカメラの初めの設定のまま、プレビューを解析に合わせる）。
///   解析に渡す映像が鏡なら、FaceAnalyzer が記録の値（左右の表情・yaw・roll・顔の枠・鍵となる点）を背面と同じ意味に直す
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
    /// 解析に渡す映像が鏡のようになっているか（決めた回転のあとで、つながりから読む）
    private(set) var analysisMirrored = false
    /// 解析に渡す映像の回転（度）
    private(set) var rotationAngle: CGFloat = 90
    static let orientationVersion = 2
    /// 映像の向き・鏡が決まったとき（main スレッド）
    var onOrientation: ((_ mirrored: Bool) -> Void)?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var coordinatorObservation: NSKeyValueObservation?
    private var lastLandscapeFix: CFTimeInterval = 0
    private let previews = NSHashTable<AVCaptureVideoPreviewLayer>.weakObjects()

    /// カメラのスレッドから呼ばれる
    var onFrame: ((CMSampleBuffer) -> Void)?

    // コマが来なくなった理由を見分けるため（v1.19〜、記録の frame_gap）
    private let countLock = NSLock()
    private var delivered = 0, dropped = 0, lastDropReason: String?
    /// 解析に渡す映像の回転が変わった（main スレッド。回転を変えると、つながりが組み直されてコマが抜けることがある）
    var onRotationChange: ((CGFloat) -> Void)?
    /// カメラの割り込み（main スレッド）：始まり（理由の名前）・終わり（nil）
    var onInterruption: ((String?) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// カメラが届けたコマの数・捨てたコマの数（遅れなど）・最後に捨てた理由
    func frameCounts() -> (delivered: Int, dropped: Int, dropReason: String?) {
        countLock.lock(); defer { countLock.unlock() }
        return (delivered, dropped, lastDropReason)
    }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] n in
            let raw = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            self?.onInterruption?(Self.interruptionName(raw))
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.onInterruption?(nil)
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            self?.onInterruption?("runtime_error")
        })
    }

    static func interruptionName(_ raw: Int?) -> String {
        guard let raw, let r = AVCaptureSession.InterruptionReason(rawValue: raw) else { return "unknown" }
        switch r {
        case .videoDeviceNotAvailableInBackground: return "not_available_in_background"
        case .audioDeviceInUseByAnotherClient: return "audio_in_use_by_another_client"
        case .videoDeviceInUseByAnotherClient: return "video_in_use_by_another_client"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "multiple_foreground_apps"
        case .videoDeviceNotAvailableDueToSystemPressure: return "system_pressure"
        default: return "other_\(raw)"
        }
    }

    /// 初めの1回だけ組み立てる。使ったカメラを返す
    @discardableResult
    func configureIfNeeded(lens wanted: CameraLens) throws -> CameraLens {
        guard !configured else { return lens }
        session.beginConfiguration()
        do {
            session.sessionPreset = .hd1280x720
            try setInput(wanted)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true   // 遅れたコマは捨てる（即時性を優先）
            output.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            self.output = output
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        configured = true
        applyRotation()   // 組み替えが終わってから
        return lens
    }

    /// 広角／超広角／前面を切り替える（動いたままでよい）。使ったカメラを返す
    func switchLens(_ wanted: CameraLens) throws -> CameraLens {
        guard configured else { return try configureIfNeeded(lens: wanted) }
        let target = wanted.available ? wanted : .wide
        guard target != lens else { return lens }
        let used: CameraLens = try sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try setInput(target)
            return lens
        }
        applyRotation()   // 入力を替えるとつながりが作り直されるので、組み替えが終わってから向きをもう一度
        return used
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
            // 前面は、水平を保つ回転を RotationCoordinator に求めさせる（背面は今まで通り 90°）
            coordinatorObservation = nil
            coordinator = use == .front ? AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil) : nil
            coordinatorObservation = coordinator?.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            }
        } else if let old = input, session.canAddInput(old) {
            session.addInput(old)   // 替えられなかったら元に戻す
        }
    }

    /// 解析に渡す映像の回転を決め、鏡かどうかを読み、プレビューを同じにする（組み替えが終わってから呼ぶ）
    func applyRotation() {
        guard let c = output?.connection(with: .video) else { return }
        let angle = coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        if c.isVideoRotationAngleSupported(angle) {
            if c.videoRotationAngle != angle {
                c.videoRotationAngle = angle
                let a = angle
                if Thread.isMainThread { onRotationChange?(a) } else { DispatchQueue.main.async { self.onRotationChange?(a) } }
            }
            rotationAngle = angle
        }
        analysisMirrored = c.isVideoMirroringSupported && c.isVideoMirrored
        for p in previews.allObjects { matchPreview(p) }
        let m = analysisMirrored
        if Thread.isMainThread { onOrientation?(m) } else { DispatchQueue.main.async { self.onOrientation?(m) } }
    }

    /// プレビューの回転と鏡を、解析に渡す映像と同じにする（網目が顔に重なるように）
    func matchPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previews.add(layer)
        guard let c = layer.connection else { return }
        if c.isVideoRotationAngleSupported(rotationAngle), c.videoRotationAngle != rotationAngle { c.videoRotationAngle = rotationAngle }
        if c.isVideoMirroringSupported {
            if c.automaticallyAdjustsVideoMirroring { c.automaticallyAdjustsVideoMirroring = false }
            if c.isVideoMirrored != analysisMirrored { c.isVideoMirrored = analysisMirrored }
        }
    }

    /// 届いた映像が横長なら（縦持ちのはずが回転が効いていない）、1秒に1回まで回転を決め直す
    func checkPortrait(_ size: CGSize) {
        guard size.width > size.height, rotationAngle == 90 || rotationAngle == 270 else { return }
        let now = CACurrentMediaTime()
        guard now - lastLandscapeFix > 1 else { return }
        lastLandscapeFix = now
        DispatchQueue.main.async { self.applyRotation() }
    }

    func start() { sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop()  { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        countLock.lock(); delivered += 1; countLock.unlock()
        onFrame?(sampleBuffer)
    }

    /// カメラがコマを捨てた（alwaysDiscardsLateVideoFrames で遅れたコマ・バッファが足りない など。v1.19〜）
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let r = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        let name: String = switch r {
        case String(kCMSampleBufferDroppedFrameReason_FrameWasLate): "late"
        case String(kCMSampleBufferDroppedFrameReason_OutOfBuffers): "out_of_buffers"
        case String(kCMSampleBufferDroppedFrameReason_Discontinuity): "discontinuity"
        default: "unknown"
        }
        countLock.lock(); dropped += 1; lastDropReason = name; countLock.unlock()
    }
}
