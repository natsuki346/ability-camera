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
    @Published var otherVoiceBySpeaker = false   // 「本人以外の声」を声紋で決めている（選んでいる人の声の登録があるとき、v1.10.5〜）
    @Published var speakerLast: (score: Double, other: Double?, windowMs: Int)?   // 「数字」：選んでいる人との直近の似ている度合い・ほかに登録した人のいちばん高い似ている度合い（v1.11〜）・使った声の長さ（v1.10.5〜）
    @Published var voiceRetaking = false      // 声の普段だけを取り直している（v1.9.3〜：この間は声の高さの範囲を使わず、口の動きだけで本人の声を数える）
    @Published var voiceSpreadWide = false    // 比べている保存した声の普段の声の高さのばらつきが大きい（v1.9.1〜、取り直せます）
    @Published var speakerEnrollNote: String?  // 撮る側の「いま」：声の登録の進み具合・登録した（v1.10.1〜）
    @Published var voiceWait: String?         // 声の普段の進み具合が3秒増えていない理由（v1.6.2〜、VoiceWaitTracker）
    @Published var pitchRatio: Double?        // 「数字」：声の高さが取れた割合（直近10秒、声が出ていたときのうち。v1.6.2〜）
    @Published var insufficient: [Metric] = []  // データ不足で比べない指標
    @Published var differences: [String] = []
    @Published var diffTargets: [DiffTarget] = []    // differences と同じ順の種類（文字の印の色、v1.10.5〜）
    @Published var faceReadable = true
    @Published var scene: CareScene?
    @Published var markMessage: String?
    @Published var meshEnabled = true
    @Published var mesh: FaceMesh?           // 顔が読めないときは nil（古い網目を残さない）
    @Published var faceShape: [String: Double]?   // 顔の絵用に約0.2秒でならした値。読めないときは nil
    @Published var meshLagMs: Double?        // 撮影→網目を出すまで（解析の遅れ＋画面の間引き）
    @Published var lensInUse: CameraLens?    // 今使っているカメラ（設定で超広角を選んでも、無い端末では広角）
    @Published var startNote: String?        // 記録を始められなかった理由（「だれを記録しますか」の下に出す、v1.11〜）
    @Published var previewFace: Bool?        // 記録を始める前の画面：顔が映っているか（v1.11.1〜。カメラが動いていなければ nil）
    private var lastPreviewFaceHost: CFTimeInterval = -.infinity
    /// 記録中か（MediaPipe のスレッドから読む）。記録を始める前は、コマを記録・判定・見る側に流さず、顔が映っているかだけを見る
    private let recordingFlag = LockedFlag()

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
    private var poseStats: [String: Welford] = [:]            // 普段の間の顔の向き（yaw_deg・pitch_deg・roll_deg、本人から見て。v1.8〜。記録と振り返りレポートだけ）
    private var baselineClosed = DiffEngine.ClosedDetector()  // 普段の間に目を閉じていたか（判定と同じ決まり）
    private var baselineClosedS = 0.0                         // 普段の間に目を閉じていた秒数（終わったものの合計）
    static let baselineEyesClosedMinS = 10.0                  // 数えた時間がこれを超えてから
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
    private var voiceWaitTracker = VoiceWaitTracker()
    // 途中まで集めた声の普段（v1.7〜）：前のセッションまでの分（voiceCarry）に、このセッションの分（voiceStats・voiceValidS）を足す。
    // 人に保存するのは、その人に声の普段がまだ無いときだけ
    private var voiceCarry: VoicePartial?                     // このセッションの始め（・人を選んだとき）に読んだもの
    private var voiceCarryOwner: String?                      // voiceCarry を読んだ人（人を変えたら、その人の分を元に戻す）
    private var voiceSessionFirstMs: Int64?                   // このセッションで初めて本人の声を数えた時刻
    // 話者の区別（v1.10〜、記録に書くだけ）
    private var speakerOn = false
    private var speakerEnroll: (id: String, partial: SpeakerEnrollPartial, retake: Bool, collect: SpeakerEnrollCollect)?
    private var speakerEnrollSavedSec = -1
    private var speakerOther = SpeakerOtherVoice()        // 「本人以外の声」を声紋で（v1.10.5〜）
    private var otherVoiceSourceLogged: String?           // 記録に書いた other_voice_source（変わったら書く）
    private var speakerTally = SpeakerEnrollTally()   // 登録を始めてから計算した声と、数えなかった理由ごとの秒数（v1.10.3〜、speaker_enroll_progress）
    private var speakerGate = SpeakerSelfGate<(endMs: Int64, spanS: Double, embedding: [Float])>()   // 本人を登録するとき（v1.10.1〜）
    private var voiceRetake = false                           // 声の普段だけを取り直した（集め終えたら、その人の声の普段を置き換える。v1.9.2〜）
    private var voiceF0Values: [Double] = []                  // このセッションで数えた声の高さ（v1.9.1〜、中央値・四分位範囲を求める）
    private var voiceSavedSec = -1                            // 最後に保存した秒（1秒ごとに保存する）
    private var pitchCoverage = PitchCoverage()
    private var lastAudioAtCoverage: CFTimeInterval = 0
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

    // MARK: セッション（開いたら人を選んで記録し、裏に回ったら閉じて要約する）

    init() {
        #if DEBUG
        if Self.uiPreviewStart { PersonStore.shared.fillPreview(count: Self.previewPeopleCount) }
        #endif
        // 記録する人（v1.11〜）：選んだらその人で始める。記録中なら今の記録を閉じてから新しく始める（1本の記録には1人だけ）
        PersonStore.shared.onStartRecording = { [weak self] id in self?.startRecording(personID: id) }
        PersonStore.shared.onCloseRecording = { [weak self] in self?.closeRecording() }
    }

    /// 人を選んだ：その人で記録を始める。記録中なら、今の記録を閉じてから（カメラは止めずに）新しい記録にする
    func startRecording(personID id: String) {
        Task {
            while activating { try? await Task.sleep(for: .milliseconds(50)) }
            activating = true
            defer { activating = false }
            if running {
                if micOn { audio.stop() }   // startSession でつなぎ直す
                finalizeSession()
            }
            PersonStore.shared.selectedID = id
            PersonStore.shared.awaitingPerson = false
            startNote = nil
            await startSession()
            if !running {   // カメラ・記録を始められなかった
                startNote = status
                PersonStore.shared.awaitingPerson = true
            }
        }
    }

    /// 記録している人を消した：記録を閉じ、マイクを止めて、人を選ぶのを待つ
    func closeRecording() {
        guard running else { return }
        if micOn { audio.stop() }
        finalizeSession()   // カメラは止めない（「だれを記録しますか」の映像に使う）
        UIApplication.shared.isIdleTimerDisabled = false
        PersonStore.shared.awaitingPerson = true
    }

    /// アプリが前に出た
    #if DEBUG
    /// シミュレーターで撮る側の「いま」の見た目を撮る用（v1.10.5〜。起動引数 -uiPreview、Debug ビルドだけ）。カメラ・マイク・記録は動かさず、作り物の値を入れる
    static let uiPreview = ProcessInfo.processInfo.arguments.contains("-uiPreview")
    /// 撮る側の最初の画面（だれを記録しますか）の見た目を撮る用（v1.11.1〜。起動引数 -uiPreviewStart と -previewPeople 0/1/3）。
    /// カメラは動かさず、映像の代わりに灰色の地に顔の絵を出す。人は作り物で、persons.json には保存しない
    static let uiPreviewStart = ProcessInfo.processInfo.arguments.contains("-uiPreviewStart")
    static var previewPeopleCount: Int { UserDefaults.standard.integer(forKey: "previewPeople") }

    func fillPreview() {
        running = true; cameraActive = true
        sessionStartedAt = Date().addingTimeInterval(-754)
        comparing = .today; baselineReady = true; faceReadable = true
        faceShape = ["yaw": 24, "pitch": -4, "roll": 2]
        differences = ["眉を寄せる動きが、いつもより強い（4秒）", "目を閉じている（3秒）", "声が、いつもより大きい（2秒）"]
        diffTargets = [.metric(.browDown), .eyesClosed, .metric(.rmsDb)]
        diffMetrics = [.browDown: true, .rmsDb: true]
        meterZ = [.mouthSmile: 0.3, .browDown: 2.6, .eyeSquint: -0.4, .jawOpen: 0.8, .rmsDb: 2.2, .f0Hz: -0.6]
        baselineStats = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, DiffEngine.Stat(mean: 0, sd: 1)) })
        voiceSec = 6; voiceWait = "口が動いていません"
        speakerEnrollNote = "自分の声を集めています（8/15秒）。黙っている間は数えません"
        otherVoice = true; otherVoiceBySpeaker = true
        speakerLast = (0.21, 0.52, 2600)
        fps = 29.8; procMs = 11; latMs = 43; faceRatio = 0.96; rmsDb = -41; f0Hz = 182; pitchRatio = 0.62
        lensInUse = .wide; analyzedRatio = 0.99
    }
    #endif

    func appBecameActive() async {
        #if DEBUG
        if Self.uiPreview { fillPreview(); return }
        if Self.uiPreviewStart { PersonStore.shared.awaitingPerson = true; previewFace = true; return }
        #endif
        guard !activating else { return }
        activating = true
        defer { activating = false }
        if let t = finalizeTask {   // 5秒以内に戻った（通知を見た、など）→ 同じセッションを続ける
            t.cancel(); finalizeTask = nil
            endBackgroundTask()
        }
        // 5秒以内なら同じセッション。そうでなければ、記録は自動で始めず「だれを記録しますか」を出す（v1.11〜。人を選ぶと startRecording）
        if running {
            await resumeSession()
        } else {
            PersonStore.shared.awaitingPerson = true
            status = "だれを記録するか選んでください"
            // 映り方を始める前に確かめられるよう、カメラだけ先に動かす（v1.11.1〜。記録・送信はしない。記録を始めてもカメラは止めずに使い続ける）
            startNote = await startCamera() ? nil : status
        }
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
        // 登録している途中なら、裏に回った時点の数えを書いておく（v1.10.3〜。このあと閉じられずに終わっても、取りこぼしが分かるように）
        if let en = speakerEnroll { writeEnrollProgress(en, tMs: Self.nowMs(), score: nil) }
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

    /// 話者の区別のヘッダ（v1.10〜）：使ったか・モデルの版・声を登録した人の id と役割（本人として撮る人か家族か）。名前・埋め込みは書かない
    private func speakerHeader() -> [String: Any] {
        // speaker_setting：設定「話者の区別を記録する」（v1.10.2〜。オンでもモデルが無ければ speaker_on は false）
        let setting = UserDefaults.standard.bool(forKey: "speakerRecord")
        guard speakerOn else { return ["speaker_on": false, "speaker_setting": setting] }
        let selected = PersonStore.shared.selectedID
        let enrolled = PersonStore.shared.people.filter { $0.speaker?.model == SpeakerCriteria.model }
            .map { ["id": $0.id, "role": $0.id == selected ? "self" : "family"] }
        return ["speaker_on": true, "speaker_setting": setting, "speaker_model": SpeakerCriteria.model, "speaker_voiced_floor_db": Double(SpeakerCriteria.voicedFloorDb), "speaker_enrolled": enrolled,
                "speaker_hop_s": SpeakerCriteria.hopS, "speaker_max_span_s": SpeakerCriteria.maxSpanS,
                "speaker_self_threshold": SpeakerCriteria.selfThreshold, "speaker_short_window_ms": SpeakerCriteria.shortWindowMs,
                "speaker_rel_min_score": SpeakerCriteria.relMinScore, "speaker_rel_margin": SpeakerCriteria.relMargin,   // self_by_speaker_rel（v1.11〜）
                "speaker_qos": audio.speaker?.qosName ?? "", "speaker_compute_units": audio.speaker?.unitsName ?? ""]   // 確かめる用の切り替え（v1.10.3〜）
    }

    private func startSession() async {
        guard await startCamera() else { return }
        // 話者の区別（v1.10〜）：設定でオンで、モデルがあるときだけ
        audio.speaker = UserDefaults.standard.bool(forKey: "speakerRecord") ? SpeakerFeed() : nil
        speakerOn = audio.speaker != nil
        PersonStore.shared.speakerInSession = speakerOn
        audio.speaker?.onEmbedding = { [weak self] endMs, span, timing, f0r, e in
            Task { @MainActor in self?.speakerResult(endMs: endMs, spanS: span, timing: timing, f0Ratio: f0r, embedding: e) }
        }
        // モデルを読み込んだら、どこで動かす予定かを記録に書く（v1.10.2〜、iPhone で Neural Engine を使っているかを確かめる）
        // v1.10.3〜：モデルはアプリの中で1回だけ読み込む。cached：前に読み込んだものを使った（load_ms はそのときの読み込みにかかった時間）
        audio.speaker?.onModel = { [weak self] plan, units, loadMs, cached in
            Task { @MainActor in
                guard let self, self.running else { return }
                var e = EventRecord(tMs: Self.nowMs(), kind: "speaker_model", value: .text(SpeakerCriteria.model))
                e.computeUnits = units; e.loadMs = loadMs.map { ($0 * 10).rounded() / 10 }; e.plan = plan; e.cached = cached
                self.logger.write(e)
            }
        }
        PersonStore.shared.onSpeakerEnroll = { [weak self] id, consent in self?.startSpeakerEnroll(id, consentBy: consent) ?? false }
        PersonStore.shared.onSpeakerEnrollStop = { [weak self] in self?.stopSpeakerEnroll() }
        do {
            try logger.start(camera: camera.lens, personId: PersonStore.shared.selectedID, mirrored: camera.analysisMirrored,
                             extra: speakerHeader())
        } catch {
            status = "記録を始められませんでした: \(error.localizedDescription)"
            return
        }
        recordingFlag.set(true)   // ここからのコマを記録・判定する
        previewFace = nil
        var note = ""
        micOn = await AVAudioApplication.requestRecordPermission()
        if micOn {
            do {
                try audio.start()
                // 音の設定（v1.10.2〜）：同じ端末やスピーカーの音を打ち消していないかを記録から確かめるため
                var e = EventRecord(tMs: Self.nowMs(), kind: "audio_session", value: .text(audio.sessionSummary.category))
                e.audio = audio.sessionSummary
                logger.write(e)
            } catch { micOn = false; note = "（マイクを使えませんでした。声は記録していません）" }
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
        voiceCarry = nil; voiceCarryOwner = nil
        PersonStore.shared.onVoiceRestart = { [weak self] id in self?.restartVoiceFromSettings(id) ?? false }
        voiceBox.setPitchRange(median: nil, iqr: nil, fromT: 0)   // 保存した声の普段の範囲は、applySaved で使い始める
        resetBaseline()   // 普段（設定の長さ）も自動で始める
        loadVoiceCarry()  // 途中まで集めた声の普段があれば、続きから（v1.7〜）
        applySaved()   // 保存した普段があれば、その普段ですぐ比べ始める（今日の普段はうしろで黙って記録する）
        running = true
        PersonStore.shared.inSession = true
        sessionStartedAt = Date()
        // 記録していないときに設定の「人」で「声の普段を取り直す」を押していたら、このセッションで集め直す（1回だけ。途中で閉じたら古い声の普段のまま）
        if let p = PersonStore.shared.selected, p.voiceRetakePending {
            PersonStore.shared.setVoiceRetakePending(p.id, false)
            if restartVoice() { PersonStore.shared.voiceRestarting = p.id }
        }
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
            stopSpeakerEnroll()   // 途中まで集めた声の登録は残す（取り直しなら捨てる）
            PersonStore.shared.speakerInSession = nil
            saveVoicePartial()   // 途中まで集めた声の普段は、次のセッションで続きから（v1.7〜）
            voiceCarry = nil; voiceCarryOwner = nil
            running = false
            recordingFlag.set(false)
            video.configure(enabled: false, interval: VideoSender.fastest)   // 記録していない間は映像を送らない（v1.11.1〜。カメラは動いたままのことがある）
            videoSending = false
            PersonStore.shared.inSession = false
            sessionStartedAt = nil
            baselineSec = nil; baselineReady = false; differences = []; diffTargets = []; insufficient = []
            comparing = nil; savedFromMs = nil; askResave = false; todayBaseline = nil; todayShown = false
            todayVoice = nil; resaveAccepted = false; comparingVoice = nil; usedFace = nil; usedVoice = nil; voiceSec = nil; otherVoice = false
            voiceWait = nil; voiceSpreadWide = false; voiceRetake = false; voiceRetaking = false; speakerEnrollNote = nil
            speakerOther.clear(); otherVoiceSourceLogged = nil; speakerLast = nil; otherVoiceBySpeaker = false
            PersonStore.shared.voiceRestarting = nil
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
        // 解析に渡す映像の向き・鏡（v1.6.1〜）：鏡なら記録の値を直す。横長の映像が届いたら回転を決め直す
        camera.onOrientation = { [weak face] m in face?.setMirrored(m) }
        face.onImageSize = { [weak camera] s in camera?.checkPortrait(s) }
        do {
            try face.load()
            lensInUse = try camera.configureIfNeeded(lens: CameraLens.selected)
        } catch {
            status = "カメラを使えませんでした: \(error.localizedDescription)"
            return false
        }

        let face = self.face, audio = self.audio, logger = self.logger, voiceBox = self.voiceBox
        let recordingFlag = self.recordingFlag
        face.onResult = { [weak self] r in
            // 記録を始める前（だれを記録しますか）：顔が映っているかだけを見る。記録・声の判定・見る側には流さない（v1.11.1〜）
            guard recordingFlag.get() else {
                let found = r.face
                Task { @MainActor in self?.previewFrame(face: found) }
                return
            }
            let a = audio.current
            // 撮影時刻（端末の起動からの時計）を、epoch ms に直す
            let ageSec = CACurrentMediaTime() - Double(r.captureMs) / 1000
            let tMs = Int64((Date().timeIntervalSince1970 - ageSec) * 1000)
            let round1 = { (x: Double) in (x * 10).rounded() / 10 }
            let round4 = { (x: Double) in (x * 10000).rounded() / 10000 }
            // 本人の声か（記録に書いた値と同じもので決める：表情の数値は 0.001、yaw は 0.1 に丸めたもの）
            let bsD = r.face ? r.blendshapes.mapValues { (Double($0) * 1000).rounded() / 1000 } : [:]
            // 声の大きさ・高さは、記録に書く値（JSON の Float の書き方）と同じ Double にする（振り返りレポートと同じ値で決めるため）
            let num = { (f: Float?) in f.flatMap { Double("\($0)") } }
            let dec = voiceBox.add(t: Double(tMs) / 1000, face: r.face, yaw: r.pose.map { round1($0.yaw) },
                                   bs: bsD, rms: num(a.rmsDb), f0: num(a.f0Hz), otherJaw: r.otherJaw)
            let voiceSelf = dec.voiceSelf, voiceFaceValid = dec.faceValid
            let r2 = { (x: Double?) in x.map { ($0 * 100).rounded() / 100 } }
            var frame = FrameRecord(tMs: tMs, face: r.face,
                                    bs: r.face ? r.blendshapes : nil, pts: r.face ? r.keyPoints : nil,
                                    rmsDb: a.rmsDb, f0Hz: a.f0Hz, procMs: r.procMs, latMs: r.latMs,
                                    yawDeg: r.pose.map { round1($0.yaw) }, pitchDeg: r.pose.map { round1($0.pitch) },
                                    rollDeg: r.pose.map { round1($0.roll) },
                                    faceCx: r.box.map { round4($0.cx) }, faceCy: r.box.map { round4($0.cy) },
                                    faceW: r.box.map { round4($0.w) }, voiceSelf: Nullable(voiceSelf))
            if voiceSelf != nil {
                frame.voiceSelfReason = dec.reason?.rawValue
                frame.voiceCorr = r2(dec.corr); frame.voiceCorrOther = r2(dec.corrOther); frame.voiceMatch = dec.match?.rawValue
            }
            frame.otherJawOpen = r.otherJaw
            // ファイルが開いていないとき・記録の開始より前のコマは書かれない
            logger.write(frame, notBefore: tMs)
            let reason = dec.reason
            Task { @MainActor in self?.update(r, audio: a, tMs: tMs, voiceSelf: voiceSelf, voiceFaceValid: voiceFaceValid, voiceReason: reason) }
        }
        audio.onBlocks = { [weak logger] t, step, db in logger?.write(AudioRecord(tMs: t, blockMs: step, rmsDb: db), notBefore: t) }
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

    /// 記録を始める前の画面の「顔が映っています／映っていません」。ちらつかないよう、0.7秒見つからなければ「映っていません」
    private func previewFrame(face found: Bool) {
        guard !running else { return }
        let now = CACurrentMediaTime()
        if found { lastPreviewFaceHost = now }
        let v = now - lastPreviewFaceHost < 0.7
        if previewFace != v { previewFace = v }
    }

    private func stopCamera() {
        guard cameraActive else { return }
        camera.stop()
        cameraActive = false
        previewFace = nil; lastPreviewFaceHost = -.infinity
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
        pitchCoverage.reset(); pitchRatio = nil
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
            e.mirrorCorrected = camera.analysisMirrored
            e.orientationVersion = CameraManager.orientationVersion
            logger.write(e)
            head.reset()
            restartBaseline(keepVoice: true)
            face.setPreferred(nil)
            applySaved()   // このカメラの保存した普段があれば、すぐそれで比べる（v1.6.1〜）
            showMessage("カメラを\(used.label)にしました。" + (comparing == .saved ? "このカメラの保存した普段で比べています" : "普段を取り直しています"))
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
    /// 「普段を取り直す」で選ぶもの（v1.9.2〜）
    enum RestartPart: String, CaseIterable, Identifiable {
        case face = "表情だけ", voice = "声だけ", both = "両方"
        var id: String { rawValue }
    }

    func restart(_ part: RestartPart) {
        switch part {
        case .face: restartBaseline(keepVoice: true)
        case .voice: restartVoice()
        case .both: restartBaseline()
        }
    }

    // MARK: 話者の区別（v1.10〜、記録に書くだけ。画面には出さない）

    /// 埋め込みを1つ求めた：登録した人ごとの似ている度合いを記録に書き、声の登録を集めていれば足す
    private func speakerResult(endMs: Int64, spanS: Double, timing: SpeakerTiming, f0Ratio: Double?, embedding e: [Float]) {
        guard running, speakerOn else { return }
        var scores: [String: Double] = [:]
        for p in PersonStore.shared.people {
            guard let s = p.speaker, s.model == SpeakerCriteria.model else { continue }
            scores[p.id] = (SpeakerMath.cosine(e, s.embedding) * 1000).rounded() / 1000
        }
        let r1 = { (x: Double) in (x * 10).rounded() / 10 }
        let windowMs = Int((spanS * 1000).rounded())
        let selID = PersonStore.shared.selectedID
        let selScore = selID.flatMap { scores[$0] }
        let others = scores.filter { $0.key != selID }.map(\.value)
        let selfBy = SpeakerMath.selfBySpeaker(score: selScore)
        let selfRel = SpeakerMath.selfBySpeakerRel(score: selScore, others: others)   // v1.11〜：「本人以外の声」はこちらで
        speakerOther.add(tMs: endMs, windowMs: windowMs, selfBySpeaker: selfRel)
        speakerLast = selScore.map { ($0, others.max(), windowMs) }
        logger.write(SpeakerRecord(tMs: endMs, windowMs: Int((spanS * 1000).rounded()), scores: scores,
                                   calcMs: r1(timing.calcMs), model: SpeakerCriteria.model,
                                   f0Ratio: f0Ratio.map { ($0 * 100).rounded() / 100 },
                                   fbankMs: r1(timing.fbankMs), predictMs: r1(timing.predictMs), waitMs: r1(timing.waitMs),
                                   selfBySpeaker: Nullable(selfBy), selfBySpeakerRel: Nullable(selfRel)), notBefore: endMs)
        guard let en = speakerEnroll else { return }
        switch en.collect {
        case .voiced:
            _ = speakerTally.add(SpeakerSelfGate<Int>.Outcome.counted, seconds: min(spanS, SpeakerCriteria.hopS))
            addSpeakerEnroll(endMs: endMs, spanS: spanS, embedding: e)
        case .voiceSelf:   // 本人：そのまとまりのコマの voice_self が分かってから決める（v1.10.1〜）
            speakerGate.embedding(endMs: endMs, spanS: spanS, item: (endMs, spanS, e))
            drainSpeakerGate()
        }
    }

    /// 本人を登録しているとき、映像のコマごとの voice_self を入れる（update から）
    private func speakerGateFrame(tMs: Int64, voiceSelf: Bool?, reason: String?) {
        guard let en = speakerEnroll, en.collect == .voiceSelf else { return }
        speakerGate.frame(tMs: tMs, voiceSelf: voiceSelf, reason: reason)
        drainSpeakerGate()
    }

    private func drainSpeakerGate() {
        for r in speakerGate.ready(nowMs: Self.nowMs()) {
            // 途中で選んでいる人を変えたら、voice_self はほかの人のものなので数えない
            guard let en = speakerEnroll, en.collect == .voiceSelf, PersonStore.shared.selectedID == en.id else { continue }
            // 数えたら足した分と同じ長さを、理由ごとに足す。計算した声が5秒増えるごとにも1行（v1.10.3〜。数えた声が5秒に届かなくても取りこぼしが分かるように）
            let crossed = speakerTally.add(r.outcome, seconds: min(r.item.spanS, SpeakerCriteria.hopS))
            if r.outcome == .counted {
                addSpeakerEnroll(endMs: r.item.endMs, spanS: r.item.spanS, embedding: r.item.embedding, computedCrossed: crossed)
            } else if crossed {
                writeEnrollProgress(en, tMs: r.item.endMs, score: nil)
            }
        }
    }

    private func addSpeakerEnroll(endMs: Int64, spanS: Double, embedding e: [Float], computedCrossed: Bool = false) {
        guard var en = speakerEnroll else { return }
        // 0.5秒ごとなので、重ならない分だけ数える
        let score = SpeakerMath.addWithProgress(&en.partial, embedding: e, spanS: min(spanS, SpeakerCriteria.hopS))
        speakerEnroll = en
        // たまった秒数が5秒増えるごと（v1.10.1〜）、または本人の登録で計算した声が5秒増えたとき（v1.10.3〜、score なしのこともある）
        if score != nil || computedCrossed { writeEnrollProgress(en, tMs: endMs, score: score) }
        let sec = Int(en.partial.validS)
        if PersonStore.shared.speakerEnrollSec != sec { PersonStore.shared.speakerEnrollSec = sec }
        let name = PersonStore.shared.people.first { $0.id == en.id }?.displayName ?? ""
        if en.partial.validS >= SpeakerCriteria.enrollTargetS {
            let done = SpeakerMath.finish(en.partial, now: Self.nowMs())
            PersonStore.shared.setSpeaker(en.id, done)
            writeEnrollProgress(en, tMs: Self.nowMs(), score: nil, final: true)
            showSpeakerDone("\(name)の声を\(en.retake ? "登録し直しました" : "登録しました")")
            speakerEnroll = nil; speakerGate.clear(); PersonStore.shared.speakerEnrolling = nil
        } else {
            setSpeakerProgress(name: name, sec: sec)
            if !en.retake, sec != speakerEnrollSavedSec {   // 初めての登録は、途中の分を1秒ごとに残す（取り直しは、たまるまで今の登録を残し、途中の分は残さない）
                speakerEnrollSavedSec = sec
                PersonStore.shared.setSpeakerPartial(en.id, en.partial)
            }
        }
    }

    /// 記録の speaker_enroll_progress（埋め込みは書かない）。本人を登録しているときは、計算した声と数えなかった理由ごとの秒数も（v1.10.3〜）。
    /// final：登録し終えた・止めた・記録を閉じたときの最後の1行（score は無い）
    private func writeEnrollProgress(_ en: (id: String, partial: SpeakerEnrollPartial, retake: Bool, collect: SpeakerEnrollCollect),
                                     tMs: Int64, score: Double?, final: Bool = false) {
        var ev = EventRecord(tMs: tMs, kind: "speaker_enroll_progress", value: nil)
        ev.personId = en.id; ev.validS = (en.partial.validS * 10).rounded() / 10; ev.score = score
        if en.collect == .voiceSelf {
            let r1 = { (x: Double) in (x * 10).rounded() / 10 }
            ev.computedS = r1(speakerTally.computedS); ev.notSelfS = r1(speakerTally.notSelfS)
            ev.noF0S = r1(speakerTally.noF0S); ev.noFramesS = r1(speakerTally.noFramesS)
        }
        if final { ev.final = true }
        logger.write(ev)
    }

    /// 撮る側の「いま」の進み具合（docs/wording-guide.md）
    private func setSpeakerProgress(name: String, sec: Int) {
        let t = "\(name)の声を集めています（\(sec)/\(Int(SpeakerCriteria.enrollTargetS))秒）。黙っている間は数えません"
        if speakerEnrollNote != t { speakerEnrollNote = t }
    }

    private func showSpeakerDone(_ msg: String) {
        speakerEnrollNote = msg
        Task {
            try? await Task.sleep(for: .seconds(5))
            if speakerEnrollNote == msg { speakerEnrollNote = nil }
        }
    }

    /// 設定の「人」で「声を登録する」：記録中で話者の区別がオンなら、その人の声の登録を集め始める。
    /// 選んでいる人（本人）なら、本人の声とされた時間だけを集める（v1.10.1〜）
    private func startSpeakerEnroll(_ id: String, consentBy: String) -> Bool {
        guard running, speakerOn, let p = PersonStore.shared.people.first(where: { $0.id == id }) else { return false }
        let now = Self.nowMs()
        let retake = p.speaker != nil
        let collect: SpeakerEnrollCollect = PersonStore.shared.selectedID == id ? .voiceSelf : .voiced
        var part = SpeakerEnrollPartial(model: SpeakerCriteria.model, sum: [], embeddings: 0, validS: 0, startedMs: now, consentBy: consentBy, consentMs: now)
        if !retake, let old = p.speakerPartial, old.model == SpeakerCriteria.model, !old.expired(now: now) {
            part = old; part.consentBy = consentBy; part.consentMs = now   // 続きから（同意はこのとき聞き直したもの）
        }
        speakerEnroll = (id, part, retake, collect)
        speakerEnrollSavedSec = -1
        speakerTally = SpeakerEnrollTally()
        speakerGate.clear()
        PersonStore.shared.speakerEnrollCollect = collect
        PersonStore.shared.speakerEnrollSec = Int(part.validS)
        var e = EventRecord(tMs: now, kind: "speaker_enroll", value: .text(retake ? "取り直し" : "登録"))
        e.personId = id   // 名前・同意した人は記録に書かない
        e.collect = collect.rawValue
        if collect == .voiceSelf { e.gateVersion = 3 }   // 数える決まり（v1.10.4〜 3：数える 0.5秒だけを見て、声の高さの範囲は見ない。2＝v1.10.3）
        logger.write(e)
        setSpeakerProgress(name: p.displayName, sec: Int(part.validS))
        return true
    }

    private func stopSpeakerEnroll() {
        if let en = speakerEnroll {
            if !en.retake, en.partial.embeddings > 0 { PersonStore.shared.setSpeakerPartial(en.id, en.partial) }
            if running { writeEnrollProgress(en, tMs: Self.nowMs(), score: nil, final: true) }
        }
        speakerEnroll = nil
        speakerGate.clear()
        PersonStore.shared.speakerEnrolling = nil
        if speakerEnrollNote?.hasSuffix("黙っている間は数えません") == true { speakerEnrollNote = nil }
    }

    /// 声の普段だけを、その場で初めから集め直す（v1.9.2〜）。表情の普段はそのまま。記録には baseline_restart（part: "voice"）
    @discardableResult
    func restartVoice() -> Bool {
        guard running else { return false }
        var e = EventRecord(tMs: Self.nowMs(), kind: "baseline_restart", value: nil)
        e.part = BaselinePart.voice.rawValue
        logger.write(e)
        lastChange = lastChange.map { (BaselinePart.keysAfterRestart($0.diffs, part: .voice), $0.faceReadable) }   // 声の違いだけ数え直す（v1.9.3〜）
        engine.setBaseline(nil, part: .voice)          // 声は集め直すまで比べない
        // 声の高さの範囲は外す（古い声の普段の範囲は、取り直す理由そのもの）。この間は口の動き（と顔）だけで本人の声を決める。
        // 撮る側の「いま」に「声の普段を集め直しています。この間は口の動きだけで本人の声を数えます」と出す（voiceRetaking）
        voiceBox.setPitchRange(median: nil, iqr: nil, fromT: 0)
        voiceCarry = nil                                  // 前のセッションまでに途中まで集めた分も使わない
        voiceStats = [:]; voiceValidS = 0; voicePrevT = nil; voiceStartMs = Self.nowMs(); voiceDone = false
        voiceSessionFirstMs = nil; voiceSavedSec = -1; voiceF0Values = []; voiceSpreadWide = false
        voiceSec = 0; comparingVoice = nil; usedVoice = nil; todayVoice = nil
        voiceWaitTracker.reset(); voiceWait = nil
        voiceRetake = true; voiceRetaking = true
        voiceCarryOwner = PersonStore.shared.selected?.id
        // 取り直しは、10秒たまって保存し直すまで、保存した古い声の普段を残す（途中の分は saveVoicePartial しない。閉じたら次のセッションは古い声の普段のまま）
        publishBaseline(tMs: Self.nowMs())   // 声の「データ不足」を消して、集めている表示にする
        showMessage("声の普段を集め直しています")
        return true
    }

    /// 設定の「人」で「声の普段を取り直す」を押した：記録中でその人を選んでいれば、その場で集め直す（v1.9.2〜）
    private func restartVoiceFromSettings(_ id: String) -> Bool {
        guard running, PersonStore.shared.selectedID == id else { return false }
        return restartVoice()
    }

    /// keepVoice：カメラを変えたとき（v1.7〜）・「表情だけ」取り直すとき（v1.9.2〜）。声の普段は続ける（記録には part: "face" で書く）
    func restartBaseline(keepVoice: Bool = false) {
        guard running else { return }
        var e = EventRecord(tMs: Self.nowMs(), kind: "baseline_restart", value: nil)
        if keepVoice { e.part = BaselinePart.face.rawValue }
        logger.write(e)
        resetBaseline(keepVoice: keepVoice)
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

    private func resetBaseline(keepVoice: Bool = false) {
        baselineStartHost = CACurrentMediaTime()
        baselineStartMs = Self.nowMs()
        stats = [:]
        baselineValidS = 0; baselineLastT = nil; lastValidHost = -.infinity
        baselineTarget = Self.selectedBaselineSeconds
        baselineSec = 0; baselineReady = false; baselineWait = nil; insufficient = []; differences = []; diffTargets = []
        // 違いの数：取り直した部分の違いだけを数え直す（v1.9.3〜、SessionStats と同じ）。表情だけなら、続いている声の違いは数え直さない
        lastChange = keepVoice ? lastChange.map { (BaselinePart.keysAfterRestart($0.diffs, part: .face), $0.faceReadable) } : nil
        squintPending = []
        engine.setBaseline(nil, part: keepVoice ? .face : .all)   // 普段が無い間は比べない
        engine.finished = []
        liveZ = [:]; liveDiffs = []
        link.baseline = nil   // 見る側の「いつもの範囲」も消す（記録し終えたら、また送る）
        meterZ = [:]; diffMetrics = [:]; baselineStats = nil
        comparing = nil; savedFromMs = nil; askResave = false
        boxStats = (Welford(), Welford(), Welford())
        poseStats = [:]
        baselineClosed = DiffEngine.ClosedDetector(); baselineClosedS = 0; baselineEyesClosedLong = false
        usedFace = nil
        guard !keepVoice else { return }
        voiceBox.setPitchRange(median: nil, iqr: nil, fromT: 0)   // 声も取り直すなら、声の高さの範囲も外す（v1.9.3〜、review.py の pitch_ranges と同じ）
        // 声の普段も、表情とは別に初めから集め直す（v1.6〜）。前のセッションまでに途中まで集めた分（voiceCarry）は残す（v1.7〜）
        voiceStats = [:]; voiceValidS = 0; voicePrevT = nil; voiceStartMs = Self.nowMs(); voiceDone = false
        voiceSessionFirstMs = nil; voiceSavedSec = -1; voiceF0Values = []; voiceSpreadWide = false; voiceRetake = false; voiceRetaking = false
        voiceSec = Int(voiceCarry?.validS ?? 0); comparingVoice = nil; usedVoice = nil; todayVoice = nil
        voiceWaitTracker.reset(); voiceWait = nil
    }

    // MARK: 途中まで集めた声の普段（v1.7〜）

    /// 選んだ人の途中まで集めた声の普段を読む（声の普段がまだ無い人だけ）。集め始めてから14日たったものは捨て、event に残す
    private func loadVoiceCarry() {
        voiceCarry = nil; voiceCarryOwner = nil
        guard let p = PersonStore.shared.selected, p.voice == nil else { return }
        voiceCarryOwner = p.id
        guard let part = p.voicePartial else { return }
        let now = Self.nowMs()
        if part.expired(now: now) {
            PersonStore.shared.setVoicePartial(p.id, nil)
            var e = EventRecord(tMs: now, kind: "voice_partial_discarded",
                                value: .text("集め始めてから\(Int(DiffCriteria.voiceBaselineMaxAgeDays))日たったため、途中まで集めた声の普段（本人の声 \(Int(part.validS))秒）を使いませんでした"))
            e.personId = p.id
            logger.write(e)
            return
        }
        voiceCarry = part
        if !voiceDone, comparingVoice == nil { voiceSec = Int(voiceTotalS) }
    }

    /// 前のセッションまでの分とこのセッションの分を足した、本人の声の秒数
    private var voiceTotalS: Double { (voiceCarry?.validS ?? 0) + voiceValidS }

    /// 前のセッションまでの分とこのセッションの分を足した値
    private var voiceMergedStats: [Metric: Welford] {
        var out = voiceStats
        for (k, w) in voiceCarry?.stats ?? [:] {
            guard let m = Metric(rawValue: k) else { continue }
            out[m] = w.merged(out[m] ?? Welford())
        }
        return out
    }

    /// 前のセッションまでの分とこのセッションの分の声の高さ（v1.9.1〜）
    private var voiceMergedF0: [Double] { (voiceCarry?.f0Values ?? []) + voiceF0Values }

    private static func dayString(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// 今までの分（このセッションを含む）。このセッションで本人の声を数えていなければ、前のままの値
    private func voicePartialNow() -> VoicePartial? {
        guard let first = voiceSessionFirstMs, voiceValidS > 0 else { return voiceCarry }
        let days = Set((voiceCarry?.days ?? []) + [Self.dayString(first)]).sorted()
        return VoicePartial(startedMs: voiceCarry?.startedMs ?? first, updatedMs: Self.nowMs(), validS: (voiceTotalS * 10).rounded() / 10,
                            stats: Dictionary(uniqueKeysWithValues: voiceMergedStats.map { ($0.key.rawValue, $0.value) }),
                            sessions: (voiceCarry?.sessions ?? 0) + 1, days: days, f0Values: voiceMergedF0)
    }

    /// 選んだ人に、途中まで集めた声の普段を保存する（声の普段がまだ無い人だけ。集め終えたら setVoice で消える）
    private func saveVoicePartial() {
        // 声の普段を取り直している間は、途中の分を保存しない（v1.9.3〜：閉じたら捨てて、次のセッションは古い声の普段のまま）
        guard !voiceDone, !voiceRetake, let owner = voiceCarryOwner, let p = PersonStore.shared.selected, p.id == owner, p.voice == nil else { return }
        PersonStore.shared.setVoicePartial(owner, voicePartialNow())
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

    /// 選んだ人に今のカメラの保存した普段があれば、source: "saved" の baseline 行（compared: true）を書き、
    /// その普段ですぐ比べ始める（v1.3〜。v1.6.1〜はカメラごと。開いたとき・カメラを変えたとき）。今日の普段はうしろで黙って記録し、compared: false で書く。
    /// 今のカメラの普段が無い（ほかのカメラの普段だけある）ときは書かず、理由を event（kind: "saved_baseline_skipped"）に残す（今日の普段を画面に出して取る）。
    /// 声の普段はカメラに関係なく、あればすぐ使う
    private func applySaved() {
        guard let p = PersonStore.shared.selected else { return }
        let lens = (lensInUse ?? camera.lens).rawValue
        let now = Self.nowMs()
        if let sv = p.saved(for: lens) {
            applySavedFace(sv, now: now)
        } else if p.hasSaved {
            var e = EventRecord(tMs: now, kind: "saved_baseline_skipped",
                                value: .text("このカメラの保存した普段が無いため、保存した普段の行を書きませんでした"))
            e.camera = lens
            e.savedCamera = p.savedByCamera.keys.sorted().joined(separator: ",")
            logger.write(e)
        }
        if comparingVoice == nil, let v = p.voice { applySavedVoice(v, now: now) }   // カメラを変えたときは、続けている声の普段のまま
        publishBaseline(tMs: now)
    }

    private func applySavedFace(_ sv: SavedBaseline, now: Int64) {
        // 表情の部分（v1.5 までに保存した普段の声の数値は、本人以外の声も入っているので使わない）
        let faceMetrics = sv.metrics.filter { Metric(rawValue: $0.key)?.isFace ?? false }
        var row = BaselineRecord(tMs: now, startedMs: nil, wallS: nil, validS: nil,
                                 yawLimitDeg: Self.baselineYawLimit, warmupS: Self.baselineWarmup,
                                 minN: Self.minSamples, targetS: sv.targetS, blinkMasked: true, metrics: faceMetrics)
        row.source = BaselineSource.saved.rawValue; row.compared = true; row.part = BaselinePart.face.rawValue
        row.savedMs = sv.savedMs; row.camera = sv.camera; row.faceBox = sv.faceBox; row.pose = sv.pose
        logger.write(row)
        engine.setBaseline(Self.engineBaseline(faceMetrics), part: .face)
        comparing = .saved
        savedFromMs = sv.savedMs
        usedFace = (sv.savedMs, faceMetrics)
        face.setPreferred(sv.faceBox)
    }

    /// 声の部分（v1.6〜に保存したものがあれば、すぐ声も比べ始める。今日の声の普段はうしろで集める）
    private func applySavedVoice(_ v: SavedVoice, now: Int64) {
        do {
            var vr = BaselineRecord(tMs: now, startedMs: nil, wallS: nil, validS: nil,
                                    yawLimitDeg: Self.baselineYawLimit, warmupS: Self.baselineWarmup,
                                    minN: Self.minSamples, targetS: DiffCriteria.voiceBaselineS, blinkMasked: true, metrics: v.metrics)
            vr.source = BaselineSource.saved.rawValue; vr.compared = true; vr.part = BaselinePart.voice.rawValue
            vr.savedMs = v.savedMs; vr.voiceValidS = v.validS
            logger.write(vr)
            engine.setBaseline(Self.engineBaseline(v.metrics), part: .voice)
            // 声の高さの範囲（v1.9〜）：この行の時刻のコマから、保存した声の普段の範囲の外の声は本人の声と言わない（review.py と同じ）
            let f0 = v.metrics[Metric.f0Hz.rawValue]
            voiceBox.setPitchRange(median: f0?.insufficient == false ? f0?.median : nil, iqr: f0?.iqr, fromT: Double(now) / 1000)
            voiceSpreadWide = v.spreadWide
            comparingVoice = .saved
            usedVoice = v.metrics
            voiceSec = nil; voiceWait = nil
        }
    }

    /// 「この普段で保存し直しますか？」で「保存し直す」
    func overwriteSaved() {
        askResave = false
        guard let t = todayBaseline, let p = PersonStore.shared.selected else { return }
        resaveAccepted = true   // 声の普段も、集め終えたもので置き換える
        PersonStore.shared.setSaved(p.id, camera: t.camera, t)   // 今のカメラの普段だけ置き換える
        if let v = todayVoice {
            PersonStore.shared.setVoice(p.id, v)
            usePitchRange(of: v, tMs: Self.nowMs())   // 保存し直した声の普段の範囲を、この時刻から使う（v1.9.4〜）
        }
        showMessage("\(p.displayName)の\(CameraLens(rawValue: t.camera)?.shortLabel ?? "")の普段を保存し直しました")
    }

    /// 保存した普段がまだ無ければ自動で保存する。あるときは、今日の普段を画面に出して取ったときだけ保存し直すか聞く
    /// （うしろで黙って取った今日の普段は、記録に書くだけで保存しない）
    private func saveTodayIfNew() {
        askResave = false
        guard let t = todayBaseline, let p = PersonStore.shared.selected else { return }
        if p.voice == nil, let v = todayVoice { PersonStore.shared.setVoice(p.id, v) }
        if p.saved(for: t.camera) == nil {   // このカメラの普段がまだ無い（ほかのカメラの普段は変えない）
            PersonStore.shared.setSaved(p.id, camera: t.camera, t)
            showMessage("\(p.displayName)の\(CameraLens(rawValue: t.camera)?.shortLabel ?? "")の普段を保存しました")
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
        // 顔の向きの普段（v1.8〜）：比べるのには使わない。記録と振り返りレポートだけ
        let pose: [String: BaselineRecord.Stat]? = poseStats.isEmpty ? nil : poseStats.mapValues { w in
            BaselineRecord.Stat(n: w.n, mean: (w.mean * 100).rounded() / 100, std: (w.std * 100).rounded() / 100, insufficient: w.n < Self.minSamples)
        }
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
        row.pose = pose
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
                                      savedMs: Self.nowMs(), faceBox: faceBox, pose: pose)
        saveTodayIfNew()   // 人を選んでいて、保存した普段がまだ無ければ保存する（あれば、画面に出して取ったときだけ保存し直すか聞く）
    }

    /// 声の普段：本人の声のコマが合計 10秒たまったら（v1.6〜）。表情の普段とは別の baseline 行（part: "voice"）
    private func collectVoice(tMs: Int64, voiceSelf: Bool?, faceValid: Bool, reason: VoiceSelfTracker.Reason?, audio a: AudioAnalyzer.Snapshot) {
        guard running, !voiceDone else { return }
        let t = Double(tMs) / 1000
        let warm = t - Double(sessionStartMs) / 1000 >= Self.baselineWarmup
        let counted = voiceSelf == true && warm
        if counted, let p = voicePrevT, t > p { voiceValidS += min(t - p, 0.5) }
        voicePrevT = t
        if counted {
            if voiceSessionFirstMs == nil { voiceSessionFirstMs = tMs }
            if let db = a.rmsDb { voiceStats[.rmsDb, default: Welford()].add(Double(db)) }
            if let f0 = a.f0Hz { voiceStats[.f0Hz, default: Welford()].add(Double(f0)); voiceF0Values.append((Double(f0) * 10).rounded() / 10) }
        }
        let total = voiceTotalS   // 前のセッションまでに途中まで集めた分も足す（v1.7〜）
        if total >= DiffCriteria.voiceBaselineS {
            finishVoice(tMs: tMs)
        } else if comparingVoice == nil {
            if voiceSec != Int(total) { voiceSec = Int(total) }
            if Int(voiceValidS) != voiceSavedSec { voiceSavedSec = Int(voiceValidS); saveVoicePartial() }   // 1秒ごとに保存
            // 進み具合が増えないときの理由（開いてから5秒より後だけ）
            let w = warm ? voiceWaitTracker.add(t: t, voiceSelf: voiceSelf, faceValid: faceValid, selfReason: reason)?.rawValue : nil
            if voiceWait != w { voiceWait = w }
        }
    }

    private func finishVoice(tMs: Int64) {
        voiceDone = true
        let merged = voiceMergedStats
        let partial = voicePartialNow()
        var out: [String: BaselineRecord.Stat] = [:]
        for m in Metric.allCases where !m.isFace {
            let w = merged[m] ?? Welford()
            out[m.rawValue] = BaselineRecord.Stat(n: w.n,
                                                  mean: w.n > 0 ? (w.mean * 10000).rounded() / 10000 : nil,
                                                  std: w.n > 0 ? (w.std * 10000).rounded() / 10000 : nil,
                                                  insufficient: w.n < Self.minSamples)
        }
        // 声の高さは中央値と四分位範囲も書く（v1.9.1〜、声の高さの範囲に使う。v1.9 までに途中まで集めた分には値が無いので、このセッションの分だけ）
        if let rp = DiffCriteria.robustPitch(voiceMergedF0), var st = out[Metric.f0Hz.rawValue] {
            st.median = rp.median; st.iqr = rp.iqr
            out[Metric.f0Hz.rawValue] = st
        }
        let useToday = comparingVoice == nil   // 保存した声の普段で比べているときは切り替えない
        let started = voiceCarry?.startedMs ?? voiceStartMs   // 前のセッションから続けたなら、集め始めた日時
        var row = BaselineRecord(tMs: tMs, startedMs: started, wallS: (Double(tMs - started) / 100).rounded() / 10,
                                 validS: nil, yawLimitDeg: Self.baselineYawLimit, warmupS: Self.baselineWarmup,
                                 minN: Self.minSamples, targetS: DiffCriteria.voiceBaselineS, blinkMasked: true, metrics: out)
        row.source = BaselineSource.today.rawValue; row.compared = useToday; row.part = BaselinePart.voice.rawValue
        row.voiceValidS = (voiceTotalS * 10).rounded() / 10
        row.voiceSessions = partial?.sessions ?? 1
        row.voiceDays = partial?.days.count ?? 1
        row.voiceCarriedS = ((voiceCarry?.validS ?? 0) * 10).rounded() / 10
        logger.write(row)
        if useToday {
            engine.setBaseline(Self.engineBaseline(out), part: .voice)
            comparingVoice = .today
            usedVoice = out
            publishBaseline(tMs: tMs)
        }
        voiceSec = nil; voiceWait = nil
        PersonStore.shared.voiceRestarting = nil   // 集め直し終えた
        let v = SavedVoice(metrics: out, validS: row.voiceValidS ?? voiceTotalS, savedMs: tMs)
        todayVoice = v
        // 人の保存した普段に声の普段が無ければ足す（「保存し直す」を選んだあとなら置き換える）。うしろで集めたものは置き換えない
        if let p = PersonStore.shared.selected, p.voice == nil || resaveAccepted || voiceRetake {
            let replaced = p.voice != nil
            PersonStore.shared.setVoice(p.id, v)
            showMessage("\(p.displayName)の声の普段を\(replaced ? "保存し直しました" : "保存しました")")
        }
        voiceRetake = false; voiceRetaking = false
        // 声の高さの範囲（v1.9.4〜）：集め終えたら、選んでいる人の今の保存した声の普段（今保存し直したなら新しいもの、置き換えなかったなら前のもの）の範囲を使い始める。
        // 外していたのは集めている間だけ。記録に event（voice_pitch_range）を書き、振り返りレポートとリプレイもこの時刻から同じ範囲を使う
        usePitchRange(of: PersonStore.shared.selected?.voice, tMs: tMs)
    }

    /// 声の高さの範囲を、その声の普段の中央値・四分位範囲にする（中央値が無ければ外す）。記録に event（kind: "voice_pitch_range"、median・iqr）を書く
    private func usePitchRange(of v: SavedVoice?, tMs: Int64) {
        let st = v?.metrics[Metric.f0Hz.rawValue]
        let median = st?.insufficient == false ? st?.median : nil
        voiceBox.setPitchRange(median: median, iqr: st?.iqr, fromT: Double(tMs) / 1000)
        var e = EventRecord(tMs: tMs, kind: "voice_pitch_range", value: nil)
        e.median = median; e.iqr = median == nil ? nil : st?.iqr
        logger.write(e)
        voiceSpreadWide = v?.spreadWide ?? false
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

    private func update(_ r: FaceAnalyzer.Result, audio a: AudioAnalyzer.Snapshot, tMs: Int64, voiceSelf: Bool?, voiceFaceValid: Bool,
                        voiceReason: VoiceSelfTracker.Reason? = nil) {
        guard cameraActive else { return }
        collectVoice(tMs: tMs, voiceSelf: voiceSelf, faceValid: r.face && voiceFaceValid, reason: voiceReason, audio: a)
        speakerGateFrame(tMs: tMs, voiceSelf: voiceSelf, reason: voiceReason?.rawValue)
        if a.at > lastAudioAtCoverage, let db = a.rmsDb {   // 音の塊ごとに1回
            lastAudioAtCoverage = a.at
            pitchCoverage.add(t: a.at, db: db, f0: a.f0Hz != nil)
        }
        let tNow = Double(tMs) / 1000
        if voiceSelf == true { lastSelfVoiceT = tNow }
        if voiceSelf == false, voiceFaceValid { lastOtherVoiceT = tNow }   // 顔が読めていて口が動いていない声
        // 「本人以外の声」（v1.10.5〜）：選んでいる人の声の登録（今のモデル）があれば声紋で、無ければ今まで通り voice_self で。voice_self の記録・声の普段は変えない
        let bySpeaker = speakerOn && (PersonStore.shared.selected?.speaker?.model == SpeakerCriteria.model)
        let other = running && (bySpeaker ? speakerOther.other(nowMs: tMs)
                                          : tNow - lastOtherVoiceT <= 1 && tNow - lastSelfVoiceT > 1)
        if otherVoice != other { otherVoice = other }
        if otherVoiceBySpeaker != bySpeaker { otherVoiceBySpeaker = bySpeaker }
        let source = bySpeaker ? "speaker" : "voice_self"
        if running, otherVoiceSourceLogged != source {   // どちらで決めたかを記録に（記録の始め・変わったとき）
            otherVoiceSourceLogged = source
            logger.write(EventRecord(tMs: tMs, kind: "other_voice_source", value: .text(source)), notBefore: tMs)
        }
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
        pitchRatio = pitchCoverage.ratio(now: CACurrentMediaTime())

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
            // 数えた時間が10秒を超えてから判定する（数え始めは短い閉じでも2割を超えてしまうため、v1.6.1〜）
            let long = baselineValidS > Self.baselineEyesClosedMinS && baselineEyesClosedS > baselineValidS * Self.baselineEyesClosedRatio
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
            // 顔の向き：記録に書くのと同じ 0.1° に丸めた値（振り返りレポートが記録のコマから数え直したものと同じになるように）
            if let p = r.pose {
                for (k, v) in [("yaw_deg", p.yaw), ("pitch_deg", p.pitch), ("roll_deg", p.roll)] {
                    poseStats[k, default: Welford()].add((v * 10).rounded() / 10)
                }
            }
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
        // 声が出た（v1.7〜）は普段が無くても出すので、記録中はいつも更新する（普段が無い間、ほかの違いは出ない）
        if running { updateDifferences(latestT: epochT, faceReadable: readable) }
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
            z: comparing != nil ? liveZ : nil, diffs: running ? liveDiffs : nil, diffCount: running ? diffCount : nil,
            head: head.state?.rawValue,
            eyesClosed: comparing != nil && engine.eyesJudgeable ? engine.active[.eyesClosed] != nil : nil,
            voiceSec: running ? voiceSec : nil, voiceTotal: Int(DiffCriteria.voiceBaselineS), otherVoice: running ? otherVoice : nil,
            directionVersion: FaceDirection.version,
            voiceOn: running ? engine.active[.voiceOn] != nil : nil,
            voiceWait: running && voiceSec != nil ? voiceWait : nil,
            personName: running ? PersonStore.shared.selected?.displayName : nil))
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
        let diffKeys = keys.filter { !$0.hasPrefix(DiffTarget.voiceOnKey + ":") }   // 声が出たは違いの数に入れない（v1.7〜）
        if differences != messages { differences = messages; diffTargets = shown.map(\.target) }
        if meterZ != engine.z { meterZ = engine.z }
        let dm = Dictionary(uniqueKeysWithValues: shown.compactMap { s in s.metric.map { ($0, s.above) } })
        if diffMetrics != dm { diffMetrics = dm }
        liveZ = Dictionary(uniqueKeysWithValues: engine.z.map { ($0.key.rawValue, ($0.value * 100).rounded() / 100) })
        liveDiffs = shown.map { LiveDiff(metric: $0.target.key, above: $0.above, seconds: Int(max(0, latestT - $0.startT))) }

        if lastChange == nil || lastChange!.diffs != keys || lastChange!.faceReadable != faceReadable {
            diffCount += Set(diffKeys).subtracting(lastChange?.diffs ?? []).count
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

    struct Decision { let voiceSelf: Bool?; let faceValid: Bool; let reason: VoiceSelfTracker.Reason?
                      let corr: Double?; let corrOther: Double?; let match: VoiceSelfTracker.Match? }

    /// 本人の声を決める（rms・f0 は記録に書くのと同じ値）
    func add(t: Double, face: Bool, yaw: Double?, bs: [String: Double], rms: Double?, f0: Double?, otherJaw: Double?) -> Decision {
        lock.lock(); defer { lock.unlock() }
        let v = tracker.add(t: t, face: face, yaw: yaw, bs: bs, rms: rms, f0: f0, otherJaw: otherJaw)
        return Decision(voiceSelf: v, faceValid: tracker.faceValid, reason: tracker.reason,
                        corr: tracker.corr, corrOther: tracker.corrOther, match: tracker.match)
    }

    /// 保存した声の普段の声の高さを、この時刻のコマから使う（v1.9〜。nil で使わない）
    func setPitchRange(median: Double?, iqr: Double?, fromT: Double) {
        lock.lock(); defer { lock.unlock() }
        tracker.setPitchRange(median: median, iqr: iqr, fromT: fromT)
    }
}

/// 別のスレッドから読む Bool（記録中か）
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}
