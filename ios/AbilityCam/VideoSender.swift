import AVFoundation
import CoreImage
import QuartzCore

/// 見る側に送る映像（設定でオンにしたときだけ）。長い辺 480px の JPEG を、毎秒5コマまで。
/// 保存はしない。解析のコマ/秒が落ちたら、送る間隔を広げる（解析を優先）
final class VideoSender {
    static let longSide: CGFloat = 480
    static let fastest = 0.2            // 毎秒5コマ
    static let slowest = 2.0

    /// できた JPEG（エンコードのスレッドから呼ばれる）
    var onJPEG: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "video.encode", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var enabled = false
    private var interval = fastest
    private var busy = false
    private var lastSent: CFTimeInterval = 0

    /// main から：送るかどうかと、送る間隔
    func configure(enabled: Bool, interval: Double) {
        lock.lock(); self.enabled = enabled; self.interval = interval; lock.unlock()
    }

    /// カメラのスレッドから毎コマ呼ばれる。送らないコマはすぐ返す
    func offer(_ sb: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard enabled, !busy, now - lastSent >= interval else { lock.unlock(); return }
        busy = true; lastSent = now
        lock.unlock()
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { done(); return }
        let image = CIImage(cvPixelBuffer: pb)
        queue.async { [weak self] in
            guard let self else { return }
            let e = image.extent
            let scale = min(1, Self.longSide / max(e.width, e.height))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cs = CGColorSpace(name: CGColorSpace.sRGB),
               let jpeg = self.context.jpegRepresentation(of: small, colorSpace: cs,
                                                          options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.5]) {
                self.onJPEG?(jpeg)
            }
            self.done()
        }
    }

    private func done() { lock.lock(); busy = false; lock.unlock() }
}
