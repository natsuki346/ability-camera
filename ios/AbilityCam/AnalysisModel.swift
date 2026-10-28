import AVFoundation
import QuartzCore
import SwiftUI

enum CareScene: String, CaseIterable, Identifiable {
    case meal = "食事", posture = "姿勢を変える", bath = "入浴・着替え", visitor = "人が来た", other = "その他"
    var id: String { rawValue }
}

enum Mark: String, CaseIterable, Identifiable {
    case pleasant = "快", unpleasant = "不快", unknown = "分からない"
    var id: String { rawValue }
}

/// どちらの普段で比べているか（v1.2〜）
enum BaselineSource: String { case today, saved }

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
    @Published var meterZ: [Metric: Double] = [:]          // 「いま」の小さいメーター：指標ごとの今の z
    @Published var diffMetrics: [Metric: Bool] = [:]       // 違いとして出ている指標（値は「上」か）
    @Published var baselineStats: [Metric: DiffEngine.Stat]?   // 今の普段（いつもの範囲を描く。下限をかけた標準偏差）
    let graph = GraphStore()                                 // 「グラフ」のページ（メモリだけ、直近5分）
    private var lastGraphHost: CFTimeInterval = 0

    @Published var baselineSec: Int?          // 今日の普段を記録中の経過秒（記録中でなければ nil）
    @Published var baselineReady = false      // 今日の普段を記録し終えた
    @Published var comparing: BaselineSource? // いつもとの違いを比べている普段（nil：まだ比べていない）
    @Published var savedFromMs: Int64?        // 保存した普段で比べているとき、その普段を保存した日時
    @Published var askResave = false          // 「この普段で保存し直しますか？」を聞く（画面に出して取った今日の普段を、取り終えたとき）
    @Published var maxFaces = 2               // 一度に探す顔の数（解析コマ/秒が落ちたら1）
    @Published var analyzedRatio: Double?     // 直近10秒で、カメラから解析に渡したコマのうち解析できた割合
    @Published var baselineTarget = AnalysisModel.selectedBaselineSeconds   // 今の普段の長さ（数えた時間の目標）
    @Published var baselineWait: String?      // 普段を数えていない理由（数えている間は nil）
    @Published var baselineEyesClosedLong = false   // 普段の間に目を閉じていた時間が、数えた時間の2割を超えた（v1.4〜）
    @Published var voiceSec: Int?             // 声の普段を集めている：本人の声の秒数（画面に出すときだけ。v1.6〜）
    @Published var otherVoice = false         // 本人以外の声（と言えない声）だけが入っている（直近1秒）
    @Published var insufficient: [Metric] = []  // データ不足で比べない指標
    @Published var differences: [String] = []
    @Published var faceReadable = true
    @Published var scene: CareScene?
    @Published var markMessage: String?
    @Published var meshEnabled = true
    @Published var mesh: FaceMesh?           // 顔が読めないときは nil（古い網目を残さない）
    @Published var faceShape: [String: Double]?   // 顔の絵用に約0.2秒でならした値。読めないときは nil
    @Published var meshLagMs: Double?        // 撮影→網目を出すまで（解析の遅れ＋画面の間引き）
    @Published var lensInUse: CameraLens?    // 今使っているカメラ（設定で超広角を選んでも、無い端末では広角）

    let camera = CameraManager()
    private let face = FaceAnalyzer()
    private let audio = AudioAnalyzer()
    private let logger = SessionLogger()
    let link = CameraLink()                  // 見る側（iPad / Mac）へ状態を送る
    private let video = VideoSender()        // 見る側へ映像（設定でオンのときだけ）
    private var lastLiveSent: CFTimeInterval = 0
    private var videoSending = false
    private var frameTimes: [CFTimeInterval] = []   // 直近2秒の解析コマ（映像を送る間隔を決める）
    private var fpsWithoutVideo: Double?
    private var videoInterval = VideoSender.fastest
    private var lastVideoAdjust: CFTimeInterval = 0

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
    private var baselineValidS = 0.0          // 普段に数えた時間の合計
    private var baselineLastT: Double?        // 前に見たコマの撮影時刻（数えた時間の幅を出す）
    private var lastValidHost: CFTimeInterval = -.infinity
    private var sessionStartHost: CFTimeInterval = 0
    private var sessionStartMs: Int64 = 0
    private var stats: [Metric: Welford] = [:]
    private var engine = DiffEngine()                         // いつもとの違い（振り返りレポートと同じ決まり）
    private var lastAudioAtEngine: CFTimeInterval = 0         // 違いの判定に入れた最後の音
    private var lastBlinkT = -Double.infinity                 // 最後にまばたき（eyeBlink ≥ 0.3）があった撮影時刻
    private var squintPending: [(t: Double, x: Double)] = []  // 普段に数える前の目を細めるの値（後ろ 0.2秒にまばたきが無いか待つ）
    private var recentFace: [(t: Double, face: Bool)] = []   // 直近1秒のコマ
    private var lastChange: (diffs: [String], faceReadable: Bool)?
    private var liveZ: [String: Double] = [:]                 // 見る側へ：指標ごとの今の z
    private var liveDiffs: [LiveDiff] = []                    // 見る側へ：違いの一覧（指標・向き・秒数）
    private var diffCount = 0                                 // このセッションで違いが出た回数（segments と同じ数え方）
    private var head = HeadTurnTracker()                      // 顔を向ける・そむける（0.5秒続いたら記録）
    private var boxStats = (cx: Welford(), cy: Welford(), w: Welford())   // 普段の間の顔の位置と大きさ
    private var baselineClosed = DiffEngine.ClosedDetector()  // 普段の間に目を閉じていたか（判定と同じ決まり）
    private var baselineClosedS = 0.0                         // 普段の間に目を閉じていた秒数（終わったものの合計）
    static let baselineEyesClosedRatio = 0.2                  // 目を閉じていた時間がこれを超えたら「取り直せます」と出す
    private var todayBaseline: SavedBaseline?                 // このセッションで記録し終えた今日の普段（保存・保存し直し用）
    private var todayVoice: SavedVoice?                       // このセッションで集め終えた声の普段
    private var resaveAccepted = false                        // このセッションで「保存し直す」を選んだ（あとで集め終えた声の普段も保存し直す）
    private var comparingVoice: BaselineSource?               // 声を比べている普段（nil：まだ集めている）
    private var usedFace: (startedMs: Int64, metrics: [String: BaselineRecord.Stat])?   // 今比べている表情の普段
    private var usedVoice: [String: BaselineRecord.Stat]?     // 今比べている声の普段
    private var voiceStats: [Metric: Welford] = [:]           // 声の普段（本人の声のコマだけ）
    private var voiceValidS = 0.0, voicePrevT: Double?, voiceStartMs: Int64 = 0, voiceDone = false
    private var lastSelfVoiceT = -Double.infinity, lastOtherVoiceT = -Double.infinity
    private let voiceBox = VoiceSelfBox()                     // MediaPipe のスレッドの上でだけ触る
    private var todayShown = false                            // 今日の普段を画面に出して取った（保存した普段で比べながら、うしろで黙って取ったのではない）
    private var faceCount: Int?                               // 映っている顔の数（0.5秒続いたもの）
    private var faceCountPending: (n: Int, tMs: Int64)?
    private var facesCheck: (host: CFTimeInterval, submitted: Int, analyzed: Int)?   // 2つ探して解析コマ/秒が落ちていないか
    private var analyzedFrames = 0

    static let baselineChoices = [30, 60] // 普段の長さ（数えた時間。時計の時間ではない）。撮る側の設定で選ぶ
    static let defaultBaselineSeconds = 30   // 2026-10-27 に60秒から変えた（docs/validation-log.md）
    /// 設定で選んだ普段の長さ（秒）
    static var selectedBaselineSeconds: Double {
        let v = UserDefaults.standard.integer(forKey: "baselineSeconds")
        return Double(baselineChoices.contains(v) ? v : defaultBaselineSeconds)
    }
    static let baselineYawLimit = 35.0
    static let baselineWarmup = 5.0       // 開いてから最初の5秒は数えない（ポケットに入れる間）
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
        link.start()
        if !recoveryDone {
            recoveryDone = true
            recoverMissing()
        }
    }

    /// アプリが裏に回った：カメラとマイクを止め、5秒たっても戻らなければファイルを閉じて要約する
    func appEnteredBackground() {
        link.stop()   // 裏に回るとつながりは切れる。戻ったら、見る側が自動でつなぎ直す
        video.configure(enabled: false, interval: VideoSender.fastest)
        videoSending = false
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

    /// 役割を「見る側」に変えたとき：すぐ止めて、記録を閉じて要約する
    func shutdown() {
        link.stop()
        stopCamera()
        if running, micOn { audio.stop() }
        finalizeSession()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func startSession() async {
        guard await startCamera() else { return }
        do {
            try logger.start(camera: camera.lens, personId: PersonStore.shared.selectedID)
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
        diffCount = 0
        graph.reset()
        link.headTurns = []   // 見る側の「直近の顔の向き」は、セッションごと
        sessionStartHost = CACurrentMediaTime()
        todayBaseline = nil; todayVoice = nil; resaveAccepted = false
        sessionStartMs = Self.nowMs()
        face.setPreferred(nil)
        resetBaseline()   // 普段（設定の長さ）も自動で始める
        applySaved()   // 保存した普段があれば、その普段ですぐ比べ始める（今日の普段はうしろで黙って記録する）
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
            comparing = nil; savedFromMs = nil; askResave = false; todayBaseline = nil; todayShown = false
            todayVoice = nil; resaveAccepted = false; comparingVoice = nil; usedFace = nil; usedVoice = nil; voiceSec = nil; otherVoice = false
            liveZ = [:]; liveDiffs = []; link.baseline = nil; link.headTurns = []
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
            lensInUse = try camera.configureIfNeeded(lens: CameraLens.selected)
        } catch {
            status = "カメラを使えませんでした: \(error.localizedDescription)"
            return false
        }

        let face = self.face, audio = self.audio, logger = self.logger, voiceBox = self.voiceBox
        face.onResult = { [weak self] r in
            let a = audio.current
            // 撮影時刻（端末の起動からの時計）を、epoch ms に直す
            let ageSec = CACurrentMediaTime() - Double(r.captureMs) / 1000
            let tMs = Int64((Date().timeIntervalSince1970 - ageSec) * 1000)
            let round1 = { (x: Double) in (x * 10).rounded() / 10 }
            let round4 = { (x: Double) in (x * 10000).rounded() / 10000 }
            // 本人の声か（記録に書いた値と同じもので決める：表情の数値は 0.001、yaw は 0.1 に丸めたもの）
            let bsD = r.face ? r.blendshapes.mapValues { (Double($0) * 1000).rounded() / 1000 } : [:]
            let (voiceSelf, voiceFaceValid) = voiceBox.add(t: Double(tMs) / 1000, face: r.face, yaw: r.pose.map { round1($0.yaw) },
                                                           bs: bsD, voiced: a.f0Hz != nil)
            // ファイルが開いていないとき・記録の開始より前のコマは書かれない
            logger.write(FrameRecord(tMs: tMs, face: r.face,
                                     bs: r.face ? r.blendshapes : nil, pts: r.face ? r.keyPoints : nil,
                                     rmsDb: a.rmsDb, f0Hz: a.f0Hz, procMs: r.procMs, latMs: r.latMs,
                                     yawDeg: r.pose.map { round1($0.yaw) }, pitchDeg: r.pose.map { round1($0.pitch) },
                                     rollDeg: r.pose.map { round1($0.roll) },
                                     faceCx: r.box.map { round4($0.cx) }, faceCy: r.box.map { round4($0.cy) },
                                     faceW: r.box.map { round4($0.w) }, voiceSelf: Nullable(voiceSelf)),
                         notBefore: tMs)
            Task { @MainActor in self?.update(r, audio: a, tMs: tMs, voiceSelf: voiceSelf, voiceFaceValid: voiceFaceValid) }
        }
        let video = self.video, link = self.link
        video.onJPEG = { [weak link] d in link?.sendVideo(d) }
        camera.onFrame = { [weak face, weak video] sb in
            face?.process(sb)
            video?.offer(sb)
        }
        if link.onViewerEvent == nil {
            link.onViewerEvent = { [weak self] e, name, corrected in self?.applyViewerEvent(e, by: name, clockCorrected: corrected) }
        }

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
        startHost = CACurrentMediaTime()
        lastAudioAtEngine = 0; recentFace = []
        lastBlinkT = -.infinity; squintPending = []
        faceReadable = true
        faceCount = nil; faceCountPending = nil; facesCheck = nil; analyzedRatio = nil
        head.reset()   // カメラを止めていた間の向きは分からないので、今から数え直す（最初に決まった向きは記録しない）
    }

    /// 設定で「カメラ」を変えた。記録中なら、切り替えたことを記録し、普段を取り直す
    /// （広角と超広角では顔の大きさ・歪みが違い、表情の数値が変わるので、前の普段とは比べない）
    func applyLens() {
        guard cameraActive else { return }   // 止まっているときは、次にカメラを始めるときに使う
        do {
            let before = lensInUse
            let used = try camera.switchLens(CameraLens.selected)
            lensInUse = used
            guard used != before, running else { return }
            var e = EventRecord(tMs: Self.nowMs(), kind: "camera", value: .text(used.label))
            e.camera = used.rawValue
            e.mirrorCorrected = used == .front
            logger.write(e)
            head.reset()
            restartBaseline()
            showMessage("カメラを\(used.label)にしました。普段を取り直しています")
        } catch {
            status = "カメラを切り替えられませんでした: \(error.localizedDescription)"
        }
    }

    /// 設定で普段の長さを変えた。普段を記録している途中なら、今の記録にすぐ使う（数えた分はそのまま）。
    /// 記録し終えていれば、次に普段を記録するとき（取り直す・次のセッション）から使う
    func applyBaselineLength() {
        guard running, !baselineReady else { return }
        baselineTarget = Self.selectedBaselineSeconds
    }

    /// 普段を取り直す：保存した普段で比べていても、それをやめて今日の普段を画面に出して取り直す。
    /// 取り終えたら、選んだ人に保存した普段があれば「この普段で保存し直しますか？」と聞く
    func restartBaseline() {
        guard running else { return }
        logger.write(EventRecord(tMs: Self.nowMs(), kind: "baseline_restart", value: nil))
        resetBaseline()
    }

    /// 同じ場面をもう一度押すと「場面なし」
    func tapScene(_ s: CareScene) {
        guard running else { return }
        scene = scene == s ? nil : s
        let t = Self.nowMs(), v = scene?.rawValue ?? "なし"
        logger.write(EventRecord(tMs: t, kind: "scene", value: .text(v)))
        graph.addEvent(t: Double(t) / 1000, label: "場面：\(v)", isMark: false)
        link.send(LiveEvent(tMs: t, kind: "scene", value: v))
    }

    /// 見る側で押された印・場面。撮る側で押したのと同じく記録し、だれが押したかも書く
    private func applyViewerEvent(_ e: LiveEvent, by name: String, clockCorrected: Bool) {
        guard running else { return }
        var r: EventRecord
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let time = f.string(from: Date(timeIntervalSince1970: Double(e.tMs) / 1000))
        switch e.kind {
        case "mark":
            guard let m = Mark(rawValue: e.value) else { return }
            r = EventRecord(tMs: e.tMs, kind: "mark", value: .text(m.rawValue))
            showMessage("\(name)が家族の印を付けました：\(m.rawValue)（\(time)）")
        case "scene":
            let s = CareScene(rawValue: e.value)
            guard s != nil || e.value == "なし" else { return }
            scene = s
            r = EventRecord(tMs: e.tMs, kind: "scene", value: .text(s?.rawValue ?? "なし"))
            showMessage("\(name)が場面を選びました：\(s?.rawValue ?? "なし")（\(time)）")
        default: return
        }
        r.source = "viewer"; r.by = name; r.clockCorrected = clockCorrected
        logger.write(r)
        graph.addEvent(t: Double(e.tMs) / 1000, label: e.kind == "mark" ? "家族の印：\(e.value)" : "場面：\(e.value)", isMark: e.kind == "mark")
        var out = e
        out.by = name
        link.send(out)
    }

    private func showMessage(_ msg: String) {
        markMessage = msg
        Task {
            try? await Task.sleep(for: .seconds(5))
            if markMessage == msg { markMessage = nil }
        }
    }

    func tapMark(_ m: Mark) {
        guard running else { return }
        let now = Date()
        logger.write(EventRecord(tMs: Int64(now.timeIntervalSince1970 * 1000), kind: "mark", value: .text(m.rawValue)))
        graph.addEvent(t: now.timeIntervalSince1970, label: "家族の印：\(m.rawValue)", isMark: true)
        link.send(LiveEvent(tMs: Int64(now.timeIntervalSince1970 * 1000), kind: "mark", value: m.rawValue))
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        showMessage("家族の印を記録しました：\(m.rawValue)（\(f.string(from: now))）")
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func resetBaseline() {
        baselineStartHost = CACurrentMediaTime()
        baselineStartMs = Self.nowMs()
        stats = [:]
        baselineValidS = 0; baselineLastT = nil; lastValidHost = -.infinity
        baselineTarget = Self.selectedBaselineSeconds
        baselineSec = 0; baselineReady = false; baselineWait = nil; insufficient = []; differences = []
        lastChange = nil
        squintPending = []
        engine.setBaseline(nil)   // 普段が無い間は比べない
        engine.finished = []
        liveZ = [:]; liveDiffs = []
        link.baseline = nil   // 見る側の「いつもの範囲」も消す（記録し終えたら、また送る）
        meterZ = [:]; diffMetrics = [:]; baselineStats = nil
        comparing = nil; savedFromMs = nil; askResave = false
        boxStats = (Welford(), Welford(), Welford())
        baselineClosed = DiffEngine.ClosedDetector(); baselineClosedS = 0; baselineEyesClosedLong = false
        // 声の普段も、表情とは別に初めから集め直す（v1.6〜）
        voiceStats = [:]; voiceValidS = 0; voicePrevT = nil; voiceStartMs = Self.nowMs(); voiceDone = false
        voiceSec = 0; comparingVoice = nil; usedFace = nil; usedVoice = nil; todayVoice = nil
    }

    /// 今比べている表情と声の普段を合わせて、画面（いつもの範囲・データ不足）と見る側に出す
    private func publishBaseline(tMs: Int64) {
        guard let f = usedFace else { return }
        var merged = f.metrics.filter { Metric(rawValue: $0.key)?.isFace ?? false }
        for (k, v) in usedVoice ?? [:] { merged[k] = v }
        let b = Self.engineBaseline(merged)
        baselineStats = b
        // 声の普段を集めている間は、声を「データ不足」には入れない（集めていると別に出す）
        insufficient = Metric.allCases.filter { m in (m.isFace || usedVoice != nil) && b[m] == nil }
        link.baseline = LiveBaseline(startedMs: f.startedMs, tMs: tMs, metrics: merged)   // 見る側へ（名前は送らない）
    }

    /// 普段の間に目を閉じていた秒数（続いている分も入れる）
    private var baselineEyesClosedS: Double {
        baselineClosedS + (baselineClosed.seg.map { $0.end - $0.start } ?? 0)
    }

    /// 選んだ人の保存した普段があり、カメラが同じなら、セッションの始めに source: "saved" の baseline 行（compared: true）を書き、
    /// その普段ですぐ比べ始める（v1.3〜、設定は無い）。今日の普段はうしろで黙って記録し、compared: false で書く（画面には出さない）。
    /// カメラが保存した普段と違うときは書かず、理由を event（kind: "saved_baseline_skipped"）に残す（今日の普段を画面に出して取る）
    private func applySaved() {
        guard let p = PersonStore.shared.selected, let sv = p.saved else { return }
        let lens = (lensInUse ?? camera.lens).rawValue
        let now = Self.nowMs()
        guard sv.camera == lens else {
            var e = EventRecord(tMs: now, kind: "saved_baseline_skipped",
                                value: .text("カメラが保存した普段と違うため、保存した普段の行を書きませんでした"))
            e.camera = lens
            e.savedCamera = sv.camera
            logger.write(e)
            return
        }
        // 表情の部分（v1.5 までに保存した普段の声の数値は、本人以外の声も入っているので使わない）
        let faceMetrics = sv.metrics.filter { Metric(rawValue: $0.key)?.isFace ?? false }
        var row = BaselineRecord(tMs: now, startedMs: nil, wallS: nil, validS: nil,
                                 yawLimitDeg: Self.baselineYawLimit, warmupS: Self.baselineWarmup,
                                 minN: Self.minSamples, targetS: sv.targetS, blinkMasked: true, metrics: faceMetrics)
        row.source = BaselineSource.saved.rawValue; row.compared = true; row.part = BaselinePart.face.rawValue
        row.savedMs = sv.savedMs; row.camera = sv.camera; row.faceBox = sv.faceBox
        logger.write(row)
        engine.setBaseline(Self.engineBaseline(faceMetrics), part: .face)
        comparing = .saved
        savedFromMs = sv.savedMs
        usedFace = (sv.savedMs, faceMetrics)
        // 声の部分（v1.6〜に保存したものがあれば、すぐ声も比べ始める。今日の声の普段はうしろで集める）
        if let v = sv.voice {
            var vr = BaselineRecord(tMs: now, startedMs: nil, wallS: nil, validS: nil,
                                    yawLimitDeg: Self.baselineYawLimit, warmupS: Self.baselineWarmup,
                                    minN: Self.minSamples, targetS: DiffCriteria.voiceBaselineS, blinkMasked: true, metrics: v.metrics)
            vr.source = BaselineSource.saved.rawValue; vr.compared = true; vr.part = BaselinePart.voice.rawValue
            vr.savedMs = v.savedMs; vr.voiceValidS = v.validS
            logger.write(vr)
            engine.setBaseline(Self.engineBaseline(v.metrics), part: .voice)
            comparingVoice = .saved
            usedVoice = v.metrics
            voiceSec = nil
        }
        publishBaseline(tMs: now)
        face.setPreferred(sv.faceBox)
    }

    /// 「この普段で保存し直しますか？」で「保存し直す」
    func overwriteSaved() {
        askResave = false
        guard var t = todayBaseline, let p = PersonStore.shared.selected else { return }
        t.voice = todayVoice ?? p.saved?.voice   // 声の普段がまだなら、集め終えたときに保存し直す
        resaveAccepted = true
        PersonStore.shared.setSaved(p.id, t)
        showMessage("\(p.displayName)の普段を保存し直しました")
    }

    /// 上の帯で人を変えた：記録に id を書く（名前は書かない）。今日の普段があれば、その人に保存する（あれば保存し直すか聞く）
    func personChanged() {
        let id = PersonStore.shared.selectedID
        if running {
            var e = EventRecord(tMs: Self.nowMs(), kind: "person", value: nil)
            e.personId = id ?? ""
            logger.write(e)
        }
        saveTodayIfNew()
    }

    /// 保存した普段がまだ無ければ自動で保存する。あるときは、今日の普段を画面に出して取ったときだけ保存し直すか聞く
    /// （うしろで黙って取った今日の普段は、記録に書くだけで保存しない）
    private func saveTodayIfNew() {
        askResave = false
        guard var t = todayBaseline, let p = PersonStore.shared.selected else { return }
        if p.saved == nil {
            t.voice = todayVoice
            PersonStore.shared.setSaved(p.id, t)
            showMessage("\(p.displayName)の普段を保存しました")
        } else if todayShown {
            askResave = true
        }
    }

    private func finishBaseline(now: CFTimeInterval) {
        squintPending = []   // 後ろ 0.2秒を確かめられなかった分は数えない
        var out: [String: BaselineRecord.Stat] = [:]
        for m in Metric.allCases where m.isFace {   // 声の普段は別に集める（v1.6〜）
            let w = stats[m] ?? Welford()
            out[m.rawValue] = BaselineRecord.Stat(n: w.n,
                                                  mean: w.n > 0 ? (w.mean * 10000).rounded() / 10000 : nil,
                                                  std: w.n > 0 ? (w.std * 10000).rounded() / 10000 : nil,
                                                  insufficient: w.n < Self.minSamples)
        }
        func box(_ w: Welford) -> FaceBoxStats.S {
            FaceBoxStats.S(n: w.n, mean: (w.mean * 10000).rounded() / 10000, std: (w.std * 10000).rounded() / 10000)
        }
        let faceBox = boxStats.cx.n > 0 ? FaceBoxStats(cx: box(boxStats.cx), cy: box(boxStats.cy), w: box(boxStats.w)) : nil
        let useToday = comparing == nil   // 保存した普段で比べているときは、比べる相手を自動では切り替えない
        var row = BaselineRecord(tMs: Self.nowMs(), startedMs: baselineStartMs,
                                 wallS: ((now - baselineStartHost) * 10).rounded() / 10,
                                 validS: (baselineValidS * 10).rounded() / 10,
                                 yawLimitDeg: Self.baselineYawLimit, warmupS: Self.baselineWarmup,
                                 minN: Self.minSamples, targetS: baselineTarget, blinkMasked: true, metrics: out)
        row.source = BaselineSource.today.rawValue; row.compared = useToday; row.faceBox = faceBox
        row.part = BaselinePart.face.rawValue
        row.eyesClosedS = (baselineEyesClosedS * 10).rounded() / 10
        row.camera = (lensInUse ?? camera.lens).rawValue
        logger.write(row)
        if useToday {
            engine.setBaseline(Self.engineBaseline(out), part: .face)
            comparing = .today
            usedFace = (baselineStartMs, out)
            publishBaseline(tMs: Self.nowMs())   // 見る側へ1回
            face.setPreferred(faceBox)
        }
        baselineSec = nil; baselineWait = nil
        baselineReady = true
        todayShown = useToday
        todayBaseline = SavedBaseline(metrics: out, camera: (lensInUse ?? camera.lens).rawValue, targetS: baselineTarget,
                                      savedMs: Self.nowMs(), faceBox: faceBox)
        saveTodayIfNew()   // 人を選んでいて、保存した普段がまだ無ければ保存する（あれば、画面に出して取ったときだけ保存し直すか聞く）
    }

    /// 声の普段：本人の声のコマが合計 10秒たまったら（v1.6〜）。表情の普段とは別の baseline 行（part: "voice"）
    private func collectVoice(tMs: Int64, voiceSelf: Bool?, audio a: AudioAnalyzer.Snapshot) {
        guard running, !voiceDone else { return }
        let t = Double(tMs) / 1000
        let warm = t - Double(sessionStartMs) / 1000 >= Self.baselineWarmup
        let counted = voiceSelf == true && warm
        if counted, let p = voicePrevT, t > p { voiceValidS += min(t - p, 0.5) }
        voicePrevT = t
        if counted {
            if let db = a.rmsDb { voiceStats[.rmsDb, default: Welford()].add(Double(db)) }
            if let f0 = a.f0Hz { voiceStats[.f0Hz, default: Welford()].add(Double(f0)) }
        }
        if voiceValidS >= DiffCriteria.voiceBaselineS {
            finishVoice(tMs: tMs)
        } else if comparingVoice == nil, voiceSec != Int(voiceValidS) {
            voiceSec = Int(voiceValidS)
        }
    }

    private func finishVoice(tMs: Int64) {
        voiceDone = true
        var out: [String: BaselineRecord.Stat] = [:]
        for m in Metric.allCases where !m.isFace {
            let w = voiceStats[m] ?? Welford()
            out[m.rawValue] = BaselineRecord.Stat(n: w.n,
                                                  mean: w.n > 0 ? (w.mean * 10000).rounded() / 10000 : nil,
                                                  std: w.n > 0 ? (w.std * 10000).rounded() / 10000 : nil,
                                                  insufficient: w.n < Self.minSamples)
        }
        let useToday = comparingVoice == nil   // 保存した声の普段で比べているときは切り替えない
        var row = BaselineRecord(tMs: tMs, startedMs: voiceStartMs, wallS: (Double(tMs - voiceStartMs) / 100).rounded() / 10,
                                 validS: nil, yawLimitDeg: Self.baselineYawLimit, warmupS: Self.baselineWarmup,
                                 minN: Self.minSamples, targetS: DiffCriteria.voiceBaselineS, blinkMasked: true, metrics: out)
        row.source = BaselineSource.today.rawValue; row.compared = useToday; row.part = BaselinePart.voice.rawValue
        row.voiceValidS = (voiceValidS * 10).rounded() / 10
        logger.write(row)
        if useToday {
            engine.setBaseline(Self.engineBaseline(out), part: .voice)
            comparingVoice = .today
            usedVoice = out
            publishBaseline(tMs: tMs)
        }
        voiceSec = nil
        let v = SavedVoice(metrics: out, validS: row.voiceValidS ?? voiceValidS, savedMs: tMs)
        todayVoice = v
        // 人の保存した普段に声の普段が無ければ足す（「保存し直す」を選んだあとなら置き換える）。うしろで集めたものは置き換えない
        if let p = PersonStore.shared.selected, var sv = p.saved, sv.voice == nil || resaveAccepted {
            sv.voice = v
            PersonStore.shared.setSaved(p.id, sv)
            showMessage("\(p.displayName)の声の普段を保存しました")
        }
    }

    /// 記録の baseline 行（と同じもの）から、判定に使う平均と標準偏差（下限をかけたもの）。データ不足の指標は入れない
    static func engineBaseline(_ metrics: [String: BaselineRecord.Stat]) -> [Metric: DiffEngine.Stat] {
        var b: [Metric: DiffEngine.Stat] = [:]
        for m in Metric.allCases {
            guard let st = metrics[m.rawValue] else { continue }
            b[m] = DiffEngine.stat(for: m, mean: st.mean, std: st.std, insufficient: st.insufficient)
        }
        return b
    }

    private func update(_ r: FaceAnalyzer.Result, audio a: AudioAnalyzer.Snapshot, tMs: Int64, voiceSelf: Bool?, voiceFaceValid: Bool) {
        guard cameraActive else { return }
        collectVoice(tMs: tMs, voiceSelf: voiceSelf, audio: a)
        let tNow = Double(tMs) / 1000
        if voiceSelf == true { lastSelfVoiceT = tNow }
        if voiceSelf == false, voiceFaceValid { lastOtherVoiceT = tNow }   // 顔が読めていて口が動いていない声
        let other = running && tNow - lastOtherVoiceT <= 1 && tNow - lastSelfVoiceT > 1
        if otherVoice != other { otherVoice = other }
        // 顔を向ける・そむける：0.5秒以上続いたときだけ記録する（全コマで見る）
        if let c = head.add(tMs: tMs, face: r.face, yaw: r.pose?.yaw) {
            var e = EventRecord(tMs: c.tMs, kind: "head_turn", value: .text(c.value))
            e.head = c.to.rawValue; e.from = c.from.rawValue
            e.yawDeg = c.yawDeg.map { ($0 * 10).rounded() / 10 }
            logger.write(e)
            // 見る側へも（記録に書くのと同じもの。記録していないときは書かないので送らない）
            if running { link.addHeadTurn(LiveEvent(tMs: c.tMs, kind: "head_turn", value: c.value, head: c.to.rawValue)) }
        }
        trackFaceCount(r.faceCount, tMs: tMs)
        analyzedFrames += 1
        frames += 1
        if r.face { faceFrames += 1 }
        if r.procMs >= 0 { procSum += r.procMs; procN += 1 }
        latSum += r.latMs

        let captureT = Double(r.captureMs) / 1000
        let hostNow = CACurrentMediaTime()
        frameTimes.append(hostNow)
        if let i = frameTimes.firstIndex(where: { $0 >= hostNow - 2 }), i > 0 { frameTimes.removeFirst(i) }
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

        // いつもとの違い：全コマで判定する（振り返りレポートと同じ。目を細めるのまばたきを外すため 0.2秒遅れて進む）
        let blink = r.face ? Double(((r.blendshapes["eyeBlinkLeft"] ?? 0) + (r.blendshapes["eyeBlinkRight"] ?? 0)) / 2) : nil
        let epochT = Double(tMs) / 1000
        if (blink ?? 0) >= DiffCriteria.blinkThreshold {
            lastBlinkT = epochT
            squintPending.removeAll { $0.t >= epochT - DiffCriteria.blinkPadS }   // 前 0.2秒の値も普段に数えない
        }
        if !squintPending.isEmpty {   // 後ろ 0.2秒にまばたきが無かった値だけ、普段に数える
            let ready = squintPending.filter { $0.t < epochT - DiffCriteria.blinkPadS }
            if !ready.isEmpty {
                for p in ready { stats[.eyeSquint, default: Welford()].add(p.x) }
                squintPending.removeFirst(ready.count)
            }
        }
        var engineVoice: [Metric: Double] = [:]
        if a.at > lastAudioAtEngine {   // 同じ音の結果を二度入れない
            lastAudioAtEngine = a.at
            if let db = a.rmsDb { engineVoice[.rmsDb] = Double(db) }
            if let f0 = a.f0Hz { engineVoice[.f0Hz] = Double(f0) }
        }
        engine.add(DiffInput(t: epochT, face: r.face, yaw: r.pose?.yaw, faceValues: Self.faceValues(r), blink: blink,
                             voice: engineVoice, voiceSelf: voiceSelf))

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
        let faceValues = Self.faceValues(r)

        let faceCount = recentFace.filter(\.face).count
        let readable = faceCount * 2 >= recentFace.count

        // 普段に数えるのは、ちゃんと映っていたコマだけ（顔が読めていて |yaw| < 35°、開いてから5秒より後）。
        // 声も同じ間のものだけ数える（ポケットに入れる音などを入れないため）
        let collecting = running && !baselineReady
        let warmingUp = now - sessionStartHost < Self.baselineWarmup
        let facing = r.pose.map { abs($0.yaw) < Self.baselineYawLimit } ?? false
        let valid = collecting && !warmingUp && readable && r.face && facing
        if collecting {
            // 前に見たコマからの幅を、今のコマの状態として数える（0.5秒より空いた分は数えない）
            if valid, let last = baselineLastT, captureT > last { baselineValidS += min(captureT - last, 0.5) }
            baselineLastT = captureT
            if valid { lastValidHost = now }
            // 目を閉じていた時間：普段に数えるのと同じコマで、判定と同じ決まり（顔の無いコマは何も変えない）
            let judgeable = !warmingUp && readable && (r.face ? facing : true)
            let (_, ended) = baselineClosed.step(t: captureT, judgeable: judgeable,
                                                 closed: blink.map { $0 >= DiffCriteria.eyesClosedThreshold })
            if let e = ended { baselineClosedS += e.end - e.start }
            let long = baselineValidS > 0 && baselineEyesClosedS > baselineValidS * Self.baselineEyesClosedRatio
            if baselineEyesClosedLong != long { baselineEyesClosedLong = long }
        }
        if valid {
            for (m, x) in faceValues {
                if m == .eyeSquint {
                    // まばたき（と前後 0.2秒）のコマは普段に数えない。後ろ 0.2秒を確かめてから数える
                    if epochT - lastBlinkT > DiffCriteria.blinkPadS { squintPending.append((epochT, x)) }
                } else {
                    stats[m, default: Welford()].add(x)
                }
            }
            if let b = r.box { boxStats.cx.add(b.cx); boxStats.cy.add(b.cy); boxStats.w.add(b.w) }
        }
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
            let sec = Int(baselineValidS)
            if baselineValidS >= baselineTarget {
                finishBaseline(now: now)
            } else {
                if baselineSec != sec { baselineSec = sec }
                // ちらつかないよう、0.5秒数えられなかったら「待っています」にする
                let wait: String? = warmingUp ? "開いてから\(Int(Self.baselineWarmup))秒は数えません"
                    : now - lastValidHost > 0.5 ? "顔が映るのを待っています" : nil
                if baselineWait != wait { baselineWait = wait }
            }
        }
        if running && comparing != nil { updateDifferences(latestT: epochT, faceReadable: readable) }
        checkFaceLimit(now: now)
        sendLive(r, now: now, readable: readable, values: faceValues, audio: a)
        adjustVideo(now: now)

        // グラフ：1秒に10回まで（解析のコマ/秒を落とさないため）。z は判定に使ったもの（約0.2秒前のコマ）
        if now - lastGraphHost >= 0.1, engine.processedT.isFinite {
            lastGraphHost = now
            graph.append(t: engine.processedT, z: running && comparing != nil ? engine.z : [:], values: engine.value,
                         baseline: running && comparing != nil ? baselineStats : nil)
        }
    }

    /// 見る側へ（1秒に10回まで）。映像・音声・顔の点は送らない
    /// 映像を送るかと、その間隔。送っていないときの解析コマ/秒を覚えておき、送っていて1割より落ちたら間隔を広げる
    private func adjustVideo(now: CFTimeInterval) {
        let on = UserDefaults.standard.bool(forKey: "sendVideo") && !link.viewers.isEmpty
        if videoSending != on { videoSending = on }
        guard now - lastVideoAdjust >= 1 else { return }
        lastVideoAdjust = now
        let recent = Double(frameTimes.count) / 2
        if !on {
            if now - startHost > 3 { fpsWithoutVideo = recent }
            videoInterval = VideoSender.fastest
        } else if let ref = fpsWithoutVideo {
            if recent < ref * 0.9 {
                videoInterval = min(videoInterval * 1.5, VideoSender.slowest)
            } else if recent >= ref * 0.97 {
                videoInterval = max(videoInterval / 1.2, VideoSender.fastest)
            }
        }
        video.configure(enabled: on, interval: videoInterval)
    }

    private func sendLive(_ r: FaceAnalyzer.Result, now: CFTimeInterval, readable: Bool,
                          values: [Metric: Double], audio a: AudioAnalyzer.Snapshot) {
        guard !link.viewers.isEmpty, now - lastLiveSent >= 0.09 else { return }
        lastLiveSent = now
        let captureMs = Int64((Date().timeIntervalSince1970 - (now - Double(r.captureMs) / 1000)) * 1000)
        let r1 = { (x: Double) in (x * 10).rounded() / 10 }
        let shape = faceShape?.mapValues { ($0 * 1000).rounded() / 1000 }
        link.send(LiveState(
            captureMs: captureMs, sentMs: Self.nowMs(), faceReadable: readable,
            yaw: r.pose.map { r1($0.yaw) }, pitch: r.pose.map { r1($0.pitch) }, roll: r.pose.map { r1($0.roll) },
            shape: shape,
            values: r.face ? Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, ($0.value * 1000).rounded() / 1000) }) : nil,
            rmsDb: a.rmsDb.map(Double.init), f0Hz: a.f0Hz.map(Double.init),
            differences: differences,
            baselineSec: comparing == nil ? baselineSec : nil, baselineTotal: Int(baselineTarget), baselineReady: comparing != nil,
            baselineWait: baselineWait, insufficient: insufficient.map(\.label),
            recording: running, sessionStartedMs: sessionStartedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            scene: scene?.rawValue,
            faceRatio: faceRatio, fps: fps,
            z: comparing != nil ? liveZ : nil, diffs: comparing != nil ? liveDiffs : nil, diffCount: running ? diffCount : nil,
            head: head.state?.rawValue,
            eyesClosed: comparing != nil && engine.eyesJudgeable ? engine.active[.eyesClosed] != nil : nil,
            voiceSec: running ? voiceSec : nil, voiceTotal: Int(DiffCriteria.voiceBaselineS), otherVoice: running ? otherVoice : nil))
    }

    /// 映っている顔の数が変わって0.5秒続いたら、event（kind: "faces"、count）を書く。最初に決まった数は書かない
    private func trackFaceCount(_ n: Int, tMs: Int64) {
        guard n != faceCount else { faceCountPending = nil; return }
        if faceCountPending?.n != n { faceCountPending = (n, tMs) }
        guard let p = faceCountPending, tMs - p.tMs >= 500 else { return }
        let first = faceCount == nil
        faceCount = n; faceCountPending = nil
        guard !first, running else { return }
        var e = EventRecord(tMs: p.tMs, kind: "faces", value: nil)
        e.count = n
        logger.write(e)
    }

    /// 10秒ごとに、カメラから解析に渡したコマのうち解析できた割合を数える（顔を1つ探しているときも。「数字」のページに出す）。
    /// 顔を2つまで探していて9割を下回ったら、1つに戻して記録に書く。映像を送っている間は、そちらで落ちることがあるので戻さない
    private func checkFaceLimit(now: CFTimeInterval) {
        guard cameraActive else { facesCheck = nil; return }
        let submitted = face.submittedCount()
        guard let c = facesCheck else { facesCheck = (now, submitted, analyzedFrames); return }
        guard now - c.host >= 10 else { return }
        let sent = submitted - c.submitted, done = analyzedFrames - c.analyzed
        facesCheck = (now, submitted, analyzedFrames)
        guard sent > 30 else { return }
        analyzedRatio = min(1, Double(done) / Double(sent))
        guard maxFaces > 1, !videoSending, Double(done) < Double(sent) * 0.9 else { return }
        do { try face.setNumFaces(1) } catch { return }
        maxFaces = 1
        let msg = String(format: "解析コマ/秒が落ちたため、探す顔の数を1にしました（カメラ %.1f → 解析 %.1f コマ/秒）",
                         Double(sent) / (now - c.host), Double(done) / (now - c.host))
        var e = EventRecord(tMs: Self.nowMs(), kind: "faces_limit", value: .text(msg))
        e.count = 1
        logger.write(e)
        status = msg
    }

    /// アプリと同じ式（左右の平均）。顔が無いときは空
    static func faceValues(_ r: FaceAnalyzer.Result) -> [Metric: Double] {
        guard r.face else { return [:] }
        func avg(_ a: String, _ b: String) -> Double {
            Double(((r.blendshapes[a] ?? 0) + (r.blendshapes[b] ?? 0)) / 2)
        }
        return [.mouthSmile: avg("mouthSmileLeft", "mouthSmileRight"),
                .browDown: avg("browDownLeft", "browDownRight"),
                .eyeSquint: avg("eyeSquintLeft", "eyeSquintRight"),
                .jawOpen: Double(r.blendshapes["jawOpen"] ?? 0)]
    }

    /// DiffEngine が判定した違いを、画面・見る側・記録の change に出す。
    /// z =（0.3秒でならした今の値 − 普段の平均）÷ max(普段の標準偏差, 下限)。|z| ≥ 2 が 0.5秒続いたら違い、|z| < 1.5 が 0.5秒で終わり
    private func updateDifferences(latestT: Double, faceReadable: Bool) {
        // グラフの「目を閉じていた時間」の薄い帯（終わったものと、続いているもの）
        for s in engine.finished where s.target == .eyesClosed { graph.setClosed(s) }
        if let s = engine.active[.eyesClosed] { graph.setClosed(s) }
        engine.finished.removeAll()
        let shown = DiffTarget.all.compactMap { engine.active[$0] }.filter(\.shown)
        let messages = shown.map { "\($0.message)（\(Int(max(0, latestT - $0.startT)))秒）" }
        let keys = shown.map(\.key)
        if differences != messages { differences = messages }
        if meterZ != engine.z { meterZ = engine.z }
        let dm = Dictionary(uniqueKeysWithValues: shown.compactMap { s in s.metric.map { ($0, s.above) } })
        if diffMetrics != dm { diffMetrics = dm }
        liveZ = Dictionary(uniqueKeysWithValues: engine.z.map { ($0.key.rawValue, ($0.value * 100).rounded() / 100) })
        liveDiffs = shown.map { LiveDiff(metric: $0.target.key, above: $0.above, seconds: Int(max(0, latestT - $0.startT))) }

        if lastChange == nil || lastChange!.diffs != keys || lastChange!.faceReadable != faceReadable {
            diffCount += Set(keys).subtracting(lastChange?.diffs ?? []).count
            lastChange = (keys, faceReadable)
            var e = EventRecord(tMs: Self.nowMs(), kind: "change", value: .list(keys))
            e.faceReadable = faceReadable
            e.baseline = comparing?.rawValue   // どちらの普段で比べたか
            logger.write(e)
        }
    }
}

/// 本人の声を決める追跡（MediaPipe の結果のスレッドから呼ぶ。念のためロックする）
final class VoiceSelfBox: @unchecked Sendable {
    private var tracker = VoiceSelfTracker()
    private let lock = NSLock()

    /// 返り値：(本人の声か, 顔が読めているか)
    func add(t: Double, face: Bool, yaw: Double?, bs: [String: Double], voiced: Bool) -> (Bool?, Bool) {
        lock.lock(); defer { lock.unlock() }
        let v = tracker.add(t: t, face: face, yaw: yaw, bs: bs, voiced: voiced)
        return (v, tracker.faceValid)
    }
}
