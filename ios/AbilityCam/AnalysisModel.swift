import AVFoundation
import QuartzCore
import SwiftUI

struct ChartPoint: Identifiable {
    let id = UUID()
    let t: Double        // 開始からの秒
    let series: String
    let value: Double    // 0〜1 に正規化
}

enum CareScene: String, CaseIterable, Identifiable {
    case meal = "食事", posture = "姿勢を変える", bath = "入浴・着替え", visitor = "人が来た", other = "その他"
    var id: String { rawValue }
}

enum Mark: String, CaseIterable, Identifiable {
    case pleasant = "快", unpleasant = "不快", unknown = "分からない"
    var id: String { rawValue }
}

@MainActor
final class AnalysisModel: ObservableObject {
    @Published var running = false           // セッションの記録中（ファイルが開いている。裏に回って5秒以内も含む）
    @Published var cameraActive = false
    @Published var sessionStartedAt: Date?   // 画面の上の経過時間
    @Published var sessions: [SessionSummary] = []   // これまでの記録（新しい順）
    @Published var status = "記録の準備中…"
    @Published var faceRatio: Double?
    @Published var fps: Double?
    @Published var procMs: Double?
    @Published var latMs: Double?
    @Published var rmsDb: Float?
    @Published var f0Hz: Float?
    @Published var points: [ChartPoint] = []

    @Published var baselineSec: Int?          // 普段を記録中の経過秒（記録中でなければ nil）
    @Published var baselineReady = false
    @Published var insufficient: [Metric] = []  // データ不足で比べない指標
    @Published var differences: [String] = []
    @Published var faceReadable = true
    @Published var scene: CareScene?
    @Published var markMessage: String?
    @Published var meshEnabled = true
    @Published var mesh: FaceMesh?           // 顔が読めないときは nil（古い網目を残さない）
    @Published var faceShape: [String: Double]?   // 顔の絵用に約0.2秒でならした値。読めないときは nil
    @Published var meshLagMs: Double?        // 撮影→網目を出すまで（解析の遅れ＋画面の間引き）

    let camera = CameraManager()
    private let face = FaceAnalyzer()
    private let audio = AudioAnalyzer()
    private let logger = SessionLogger()

    private var frames = 0, faceFrames = 0, procSum = 0.0, procN = 0, latSum = 0.0
    private var startHost: CFTimeInterval = 0
    private var activating = false
    private var micOn = false
    private var finalizeTask: Task<Void, Never>?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var recoveryDone = false
    private var meshLagSum = 0.0, meshN = 0
    private var shapeSmooth: [String: Double] = [:], lastShapeT = -Double.infinity

    // 普段といつもとの違い
    private var baselineStartHost: CFTimeInterval = 0
    private var baselineStartMs: Int64 = 0
    private var stats: [Metric: Welford] = [:]
    private var smooth: [Metric: Smoother] = [:]
    private var lastAudioAt: CFTimeInterval = 0
    private var recentFace: [(t: Double, face: Bool)] = []   // 直近1秒のコマ
    private var lastChange: (diffs: [String], faceReadable: Bool)?
    private var diffSince: [String: CFTimeInterval] = [:]     // 違いが出ている間の開始時刻（続いている秒数を出す）

    static let chartWindow = 20.0
    static let baselineSeconds = 60.0
    static let minSamples = 30
    static let resumeGraceSeconds = 5.0   // 裏に回ってからこの秒数以内に戻れば、同じセッションを続ける

    // MARK: セッション（開いている間は記録し、裏に回ったら閉じて要約する）

    /// アプリが前に出た
    func appBecameActive() async {
        guard !activating else { return }
        activating = true
        defer { activating = false }
        if let t = finalizeTask {   // 5秒以内に戻った（通知を見た、など）→ 同じセッションを続ける
            t.cancel(); finalizeTask = nil
            endBackgroundTask()
        }
        if running { await resumeSession() } else { await startSession() }
        if !recoveryDone {
            recoveryDone = true
            recoverMissing()
        }
    }

    /// アプリが裏に回った：カメラとマイクを止め、5秒たっても戻らなければファイルを閉じて要約する
    func appEnteredBackground() {
        stopCamera()
        guard running else { return }
        if micOn { audio.stop() }
        rmsDb = nil; f0Hz = nil
        logger.flush()
        UIApplication.shared.isIdleTimerDisabled = false
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "finish-session") { [weak self] in
            // 裏で動ける時間が尽きそうなら、待たずに閉じる（main スレッドで呼ばれる）
            MainActor.assumeIsolated { self?.finalizeSession() }
        }
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.resumeGraceSeconds))
            guard !Task.isCancelled else { return }
            self?.finalizeSession()
        }
    }

    private func startSession() async {
        guard await startCamera() else { return }
        do {
            try logger.start()
        } catch {
            status = "記録を始められませんでした: \(error.localizedDescription)"
            return
        }
        var note = ""
        micOn = await AVAudioApplication.requestRecordPermission()
        if micOn {
            do { try audio.start() } catch { micOn = false; note = "（マイクを使えませんでした。声は記録していません）" }
        } else {
            note = "（マイクの許可がないため、声は記録していません）"
        }
        resetLive()
        scene = nil; markMessage = nil
        resetBaseline()   // 普段の60秒も自動で始める
        running = true
        sessionStartedAt = Date()
        status = "記録しています: \(logger.fileName ?? "-")" + note
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func resumeSession() async {
        guard !cameraActive, await startCamera() else { return }
        if micOn { try? audio.start() }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// ファイルを閉じて、要約を sessions.jsonl に足す
    private func finalizeSession() {
        finalizeTask?.cancel(); finalizeTask = nil
        if running {
            running = false
            sessionStartedAt = nil
            baselineSec = nil; baselineReady = false; differences = []; insufficient = []
            scene = nil; markMessage = nil
            if let s = logger.finish() {
                do {
                    try SessionStore.append(s)
                    status = "記録を整理しました: \(s.file)"
                } catch {
                    status = "記録の要約を保存できませんでした: \(error.localizedDescription)"
                }
            }
            sessions = SessionStore.load()
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    /// 前回、要約を作る前に終了されたファイルを整理する（重いので裏のスレッドで）
    private func recoverMissing() {
        sessions = SessionStore.load()
        let current = logger.fileName
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) {
                SessionStore.recoverMissing(except: current) > 0 ? SessionStore.load() : nil
            }.value
            if let list { self?.sessions = list }
        }
    }

    private func startCamera() async -> Bool {
        if cameraActive { return true }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "カメラの許可がありません（設定アプリから許可してください）"
            return false
        }
        do {
            try face.load()
            try camera.configureIfNeeded()
        } catch {
            status = "カメラを使えませんでした: \(error.localizedDescription)"
            return false
        }

        let face = self.face, audio = self.audio, logger = self.logger
        face.onResult = { [weak self] r in
            let a = audio.current
            // 撮影時刻（端末の起動からの時計）を、epoch ms に直す
            let ageSec = CACurrentMediaTime() - Double(r.captureMs) / 1000
            let tMs = Int64((Date().timeIntervalSince1970 - ageSec) * 1000)
            let round1 = { (x: Double) in (x * 10).rounded() / 10 }
            // ファイルが開いていないとき・記録の開始より前のコマは書かれない
            logger.write(FrameRecord(tMs: tMs, face: r.face,
                                     bs: r.face ? r.blendshapes : nil, pts: r.face ? r.keyPoints : nil,
                                     rmsDb: a.rmsDb, f0Hz: a.f0Hz, procMs: r.procMs, latMs: r.latMs,
                                     yawDeg: r.pose.map { round1($0.yaw) }, pitchDeg: r.pose.map { round1($0.pitch) },
                                     rollDeg: r.pose.map { round1($0.roll) }),
                         notBefore: tMs)
            Task { @MainActor in self?.update(r, audio: a) }
        }
        camera.onFrame = { [weak face] sb in face?.process(sb) }

        resetLive()
        camera.start()
        cameraActive = true
        return true
    }

    private func stopCamera() {
        guard cameraActive else { return }
        camera.stop()
        cameraActive = false
        mesh = nil; faceShape = nil; faceReadable = true
    }

    /// 画面の数字・網目・顔の絵・グラフを、今から数え直す
    private func resetLive() {
        frames = 0; faceFrames = 0; procSum = 0; procN = 0; latSum = 0; meshLagSum = 0; meshN = 0
        faceRatio = nil; fps = nil; procMs = nil; latMs = nil
        mesh = nil; meshLagMs = nil
        faceShape = nil; shapeSmooth = [:]; lastShapeT = -.infinity
        points = []
        startHost = CACurrentMediaTime()
        smooth = [:]; lastAudioAt = 0; recentFace = []
        faceReadable = true
    }

    /// 普段を取り直す
    func restartBaseline() {
        guard running else { return }
        logger.write(EventRecord(tMs: Self.nowMs(), kind: "baseline_restart", value: nil))
        resetBaseline()
    }

    /// 同じ場面をもう一度押すと「場面なし」
    func tapScene(_ s: CareScene) {
        guard running else { return }
        scene = scene == s ? nil : s
        logger.write(EventRecord(tMs: Self.nowMs(), kind: "scene", value: .text(scene?.rawValue ?? "なし")))
    }

    func tapMark(_ m: Mark) {
        guard running else { return }
        let now = Date()
        logger.write(EventRecord(tMs: Int64(now.timeIntervalSince1970 * 1000), kind: "mark", value: .text(m.rawValue)))
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let msg = "家族の印を記録しました：\(m.rawValue)（\(f.string(from: now))）"
        markMessage = msg
        Task {
            try? await Task.sleep(for: .seconds(3))
            if markMessage == msg { markMessage = nil }
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func resetBaseline() {
        baselineStartHost = CACurrentMediaTime()
        baselineStartMs = Self.nowMs()
        stats = [:]
        baselineSec = 0; baselineReady = false; insufficient = []; differences = []
        lastChange = nil
        diffSince = [:]
    }

    private func finishBaseline(now: CFTimeInterval) {
        var out: [String: BaselineRecord.Stat] = [:]
        for m in Metric.allCases {
            let w = stats[m] ?? Welford()
            out[m.rawValue] = BaselineRecord.Stat(n: w.n,
                                                  mean: w.n > 0 ? (w.mean * 10000).rounded() / 10000 : nil,
                                                  std: w.n > 0 ? (w.std * 10000).rounded() / 10000 : nil,
                                                  insufficient: w.n < Self.minSamples)
        }
        logger.write(BaselineRecord(tMs: Self.nowMs(), startedMs: baselineStartMs,
                                    durationS: ((now - baselineStartHost) * 10).rounded() / 10,
                                    minN: Self.minSamples, metrics: out))
        insufficient = Metric.allCases.filter { (stats[$0]?.n ?? 0) < Self.minSamples }
        baselineSec = nil
        baselineReady = true
    }

    private func update(_ r: FaceAnalyzer.Result, audio a: AudioAnalyzer.Snapshot) {
        guard cameraActive else { return }
        frames += 1
        if r.face { faceFrames += 1 }
        if r.procMs >= 0 { procSum += r.procMs; procN += 1 }
        latSum += r.latMs

        let captureT = Double(r.captureMs) / 1000
        recentFace.append((captureT, r.face))
        recentFace.removeAll { $0.t < captureT - 1 }

        // 顔の絵：毎コマ、約0.2秒の移動平均でならす（間が1秒以上空いたら今の値から）
        if r.face {
            let a = captureT - lastShapeT > 1 ? 1 : 1 - exp(-max(captureT - lastShapeT, 0) / 0.2)
            for k in FaceSketch.keys {
                let x = Double(r.blendshapes[k] ?? 0)
                shapeSmooth[k] = (shapeSmooth[k] ?? x) + a * (x - (shapeSmooth[k] ?? x))
            }
            if let p = r.pose {
                for (k, x) in [("yaw", p.yaw), ("pitch", p.pitch), ("roll", p.roll)] {
                    shapeSmooth[k] = (shapeSmooth[k] ?? x) + a * (x - (shapeSmooth[k] ?? x))
                }
            }
            lastShapeT = captureT
        }

        let t = captureT - startHost
        guard frames % 3 == 0 else { return }   // 画面の更新は 1/3 に間引く（記録は全コマ）

        let now = CACurrentMediaTime()
        let elapsed = now - startHost
        faceRatio = Double(faceFrames) / Double(frames)
        fps = Double(frames) / max(elapsed, 0.001)
        procMs = procN > 0 ? procSum / Double(procN) : nil
        latMs = latSum / Double(frames)
        rmsDb = a.rmsDb
        f0Hz = a.f0Hz

        // 今の値
        func avg(_ a: String, _ b: String) -> Double {
            Double(((r.blendshapes[a] ?? 0) + (r.blendshapes[b] ?? 0)) / 2)
        }
        var faceValues: [Metric: Double] = [:]
        if r.face {
            faceValues[.mouthSmile] = avg("mouthSmileLeft", "mouthSmileRight")
            faceValues[.browDown] = avg("browDownLeft", "browDownRight")
            faceValues[.eyeSquint] = avg("eyeSquintLeft", "eyeSquintRight")
            faceValues[.jawOpen] = Double(r.blendshapes["jawOpen"] ?? 0)
        }
        var voiceValues: [Metric: Double] = [:]
        if a.at > lastAudioAt {   // 同じ音の結果を二度数えない
            lastAudioAt = a.at
            if let db = a.rmsDb { voiceValues[.rmsDb] = Double(db) }
            if let f0 = a.f0Hz { voiceValues[.f0Hz] = Double(f0) }
        }

        let collecting = running && !baselineReady   // 普段を記録するのはセッションの記録中だけ
        for (m, x) in faceValues {
            smooth[m, default: Smoother()].add(x, at: captureT)
            if collecting { stats[m, default: Welford()].add(x) }
        }
        for (m, x) in voiceValues {
            smooth[m, default: Smoother()].add(x, at: a.at)
            if collecting { stats[m, default: Welford()].add(x) }
        }

        let faceCount = recentFace.filter(\.face).count
        let readable = faceCount * 2 >= recentFace.count
        if faceReadable != readable { faceReadable = readable }
        faceShape = readable && !shapeSmooth.isEmpty ? shapeSmooth : nil

        if meshEnabled, readable, r.face, !r.mesh.isEmpty {
            mesh = FaceMesh(points: r.mesh, imageSize: r.imageSize, values: faceValues)
            meshLagSum += (now - captureT) * 1000; meshN += 1
            meshLagMs = meshLagSum / Double(meshN)
        } else if mesh != nil {
            mesh = nil
        }

        if collecting {
            let sec = Int(now - baselineStartHost)
            if now - baselineStartHost >= Self.baselineSeconds {
                finishBaseline(now: now)
            } else if baselineSec != sec {
                baselineSec = sec
            }
        }
        if running && baselineReady { updateDifferences(now: now, faceReadable: readable) }

        // グラフ
        var new: [ChartPoint] = []
        if r.face {
            new.append(ChartPoint(t: t, series: "口角を上げる", value: faceValues[.mouthSmile]!))
            new.append(ChartPoint(t: t, series: "眉を寄せる", value: faceValues[.browDown]!))
            new.append(ChartPoint(t: t, series: "目を細める", value: faceValues[.eyeSquint]!))
            new.append(ChartPoint(t: t, series: "口を開ける", value: faceValues[.jawOpen]!))
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

    /// z =（ならした今の値 − 普段の平均）÷ max(普段の標準偏差, 下限)
    private func updateDifferences(now: CFTimeInterval, faceReadable: Bool) {
        var messages: [String] = [], keys: [String] = []
        for m in Metric.allCases {
            if m.isFace && !faceReadable { continue }
            guard let w = stats[m], w.n >= Self.minSamples,
                  let s = smooth[m], s.fresh(now: now), let v = s.value else { continue }
            let z = (v - w.mean) / max(w.std, m.stdFloor)
            if let msg = m.message(z: z), let key = m.diffKey(z: z) {
                let since = diffSince[key] ?? now
                diffSince[key] = since
                messages.append("\(msg)（\(Int(now - since))秒）"); keys.append(key)
            }
        }
        diffSince = diffSince.filter { keys.contains($0.key) }
        if differences != messages { differences = messages }

        if lastChange == nil || lastChange!.diffs != keys || lastChange!.faceReadable != faceReadable {
            lastChange = (keys, faceReadable)
            var e = EventRecord(tMs: Self.nowMs(), kind: "change", value: .list(keys))
            e.faceReadable = faceReadable
            logger.write(e)
        }
    }
}
