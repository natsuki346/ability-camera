import AVFoundation
import QuartzCore
import SwiftUI

struct ChartPoint: Identifiable {
    let id = UUID()
    let t: Double        // 開始からの秒
    let series: String
    let value: Double    // 0〜1 に正規化
}

@MainActor
final class AnalysisModel: ObservableObject {
    @Published var running = false
    @Published var status = "「開始」を押すと解析を始めます"
    @Published var faceRatio: Double?
    @Published var fps: Double?
    @Published var procMs: Double?
    @Published var latMs: Double?
    @Published var rmsDb: Float?
    @Published var f0Hz: Float?
    @Published var points: [ChartPoint] = []

    let camera = CameraManager()
    private let face = FaceAnalyzer()
    private let audio = AudioAnalyzer()
    private let logger = SessionLogger()

    private var frames = 0, faceFrames = 0, procSum = 0.0, procN = 0, latSum = 0.0
    private var startHost: CFTimeInterval = 0

    static let chartWindow = 20.0

    func toggle() async {
        running ? stop() : await start()
    }

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { status = "カメラの許可がありません（設定アプリから許可してください）"; return }
        guard await AVAudioApplication.requestRecordPermission() else { status = "マイクの許可がありません（設定アプリから許可してください）"; return }
        do {
            try face.load()
            try camera.configureIfNeeded()
            try logger.start()
            try audio.start()
        } catch {
            status = "開始できませんでした: \(error.localizedDescription)"
            return
        }

        frames = 0; faceFrames = 0; procSum = 0; procN = 0; latSum = 0
        points = []
        startHost = CACurrentMediaTime()

        let face = self.face, audio = self.audio, logger = self.logger
        face.onResult = { [weak self] r in
            let a = audio.current
            // 撮影時刻（端末の起動からの時計）を、epoch ms に直す
            let ageSec = CACurrentMediaTime() - Double(r.captureMs) / 1000
            let tMs = Int64((Date().timeIntervalSince1970 - ageSec) * 1000)
            logger.write(FrameRecord(tMs: tMs, face: r.face,
                                     bs: r.face ? r.blendshapes : nil, pts: r.face ? r.keyPoints : nil,
                                     rmsDb: a.rmsDb, f0Hz: a.f0Hz, procMs: r.procMs, latMs: r.latMs))
            Task { @MainActor in self?.update(r, audio: a) }
        }
        camera.onFrame = { [weak face] sb in face?.process(sb) }
        camera.start()

        UIApplication.shared.isIdleTimerDisabled = true
        running = true
        status = "解析中…"
    }

    func stop() {
        camera.stop()
        camera.onFrame = nil
        face.onResult = nil
        audio.stop()
        logger.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        running = false
        status = "保存しました: \(logger.fileName ?? "-")（\(frames)コマ）"
    }

    private func update(_ r: FaceAnalyzer.Result, audio a: AudioAnalyzer.Snapshot) {
        guard running else { return }
        frames += 1
        if r.face { faceFrames += 1 }
        if r.procMs >= 0 { procSum += r.procMs; procN += 1 }
        latSum += r.latMs

        let t = Double(r.captureMs) / 1000 - startHost
        guard frames % 3 == 0 else { return }   // 画面の更新は 1/3 に間引く（記録は全コマ）

        let elapsed = CACurrentMediaTime() - startHost
        faceRatio = Double(faceFrames) / Double(frames)
        fps = Double(frames) / max(elapsed, 0.001)
        procMs = procN > 0 ? procSum / Double(procN) : nil
        latMs = latSum / Double(frames)
        rmsDb = a.rmsDb
        f0Hz = a.f0Hz

        func avg(_ a: String, _ b: String) -> Double {
            Double(((r.blendshapes[a] ?? 0) + (r.blendshapes[b] ?? 0)) / 2)
        }
        var new: [ChartPoint] = []
        if r.face {
            new.append(ChartPoint(t: t, series: "口角を上げる", value: avg("mouthSmileLeft", "mouthSmileRight")))
            new.append(ChartPoint(t: t, series: "眉を寄せる", value: avg("browDownLeft", "browDownRight")))
            new.append(ChartPoint(t: t, series: "目を細める", value: avg("eyeSquintLeft", "eyeSquintRight")))
            new.append(ChartPoint(t: t, series: "口を開ける", value: Double(r.blendshapes["jawOpen"] ?? 0)))
        }
        if let db = a.rmsDb {
            new.append(ChartPoint(t: t, series: "音量", value: min(1, max(0, Double(db + 60) / 60))))
        }
        if let f0 = a.f0Hz {
            new.append(ChartPoint(t: t, series: "声の高さ", value: min(1, max(0, log(Double(f0) / 70) / log(1000.0 / 70)))))
        }
        points.append(contentsOf: new)
        points.removeAll { $0.t < t - Self.chartWindow }
    }
}
