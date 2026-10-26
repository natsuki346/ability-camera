import Foundation
import MultipeerConnectivity
import UIKit

/// 撮る側 → 見る側 に送るもの。音声・顔の478点・JSONL は送らない（映像は設定でオンにしたときだけ、別に送る）
struct LiveState: Codable {
    var captureMs: Int64              // 撮影の時刻（撮る側の時計、epoch ms）
    var sentMs: Int64
    var faceReadable: Bool
    var yaw: Double?, pitch: Double?, roll: Double?
    var shape: [String: Double]?      // 顔の絵を動かす表情の数値（ならした値）と向き。読めないときは nil
    var values: [String: Double]?     // グラフ用の指標（mouth_smile など、そのコマの値）。顔が無いコマは nil
    var rmsDb: Double?, f0Hz: Double? // 声の大きさ・高さの数値（音声そのものではない）
    var differences: [String]         // 「眉を寄せる動きが、いつもより強い（12秒）」の一覧
    var baselineSec: Int?             // 普段を記録中の数えた秒（記録し終えたら nil）
    var baselineTotal: Int
    var baselineReady: Bool
    var baselineWait: String?
    var insufficient: [String]
    var recording: Bool
    var sessionStartedMs: Int64?
    var scene: String?
    var faceRatio: Double?
    var fps: Double?
    // v0.7〜（古い撮る側からは届かないので省略できる）
    var z: [String: Double]?          // 指標ごとの今の z（約1秒でならした値から）。比べられない指標は入らない
    var diffs: [LiveDiff]?            // いつもとの違い（指標・向き・続いている秒数）。differences と同じもの
    var diffCount: Int?               // このセッションで違いが出た回数（sessions.jsonl の segments と同じ数え方）
}

/// いつもとの違い1つ
struct LiveDiff: Codable, Hashable {
    let metric: String                // mouth_smile など
    let above: Bool                   // いつもより上（強い・大きい・高い）か
    let seconds: Int                  // 続いている秒数
}

/// 普段の記録が終わったとき（取り直したときも）に1回送る。見る側はこれで「いつもの範囲」を描く。
/// つながったときにも、今の普段を1回送る（記録中・まだ無いときは nil）
struct LiveBaseline: Codable {
    let startedMs: Int64
    let tMs: Int64
    let metrics: [String: BaselineRecord.Stat]   // 指標ごとの n / mean / std / insufficient（std は下限をかける前）
}

/// 家族の印・場面（t_ms は撮る側の時計）
struct LiveEvent: Codable, Identifiable {
    var id = UUID()
    let tMs: Int64
    let kind: String                  // mark / scene
    let value: String
    var by: String?                   // 見る側で押したときは、その端末の名前
}

/// 1通の中身（JSON）。映像だけは JSON にせず、先頭 1 バイト 0xFF の後ろに JPEG を付けて送る
struct Wire: Codable {
    var kind: String                  // state / event / baseline / viewer_event / ping / pong / grant / bye / revoked
    var state: LiveState?
    var baseline: LiveBaseline?       // baseline：nil なら「普段はまだ無い（記録中）」
    var event: LiveEvent?
    var t0: Int64?                    // ping を送った時刻（見る側の時計）
    var tc: Int64?                    // pong を返した時刻（撮る側の時計）
    var token: String?                // grant：次から確認なしでつなぐための合言葉
    var cameraID: String?
    var clockCorrected: Bool?         // viewer_event：時計のずれを直した時刻か
}

/// 見る側から申し込むときに付けるもの
struct InviteInfo: Codable {
    let id: String                    // 見る側の端末の ID（アプリを入れたときに作る）
    let name: String
    var token: String?                // 前に許可されたときにもらった合言葉
}

enum LinkConfig {
    static let service = "abilitycam"   // Info.plist の NSBonjourServices と同じ（_abilitycam._tcp / _udp）
    static let videoTag: UInt8 = 0xFF
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static var deviceName: String {
        let s = UserDefaults.standard.string(forKey: "deviceName")?.trimmingCharacters(in: .whitespaces) ?? ""
        var name = s.isEmpty ? UIDevice.current.name : s
        while name.utf8.count > 63 { name.removeLast() }   // MCPeerID の名前は 63 バイトまで（日本語は1字3バイト）
        return name.isEmpty ? "Ability Cam" : name
    }
    /// この端末の ID（一度作ったら変えない）
    static func persistentID(_ key: String) -> String {
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: key)
        return s
    }
    static func randomToken() -> String {
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString()
    }
}

/// 撮る側が「送る」を許可した見る側（設定で1台ずつ取り消せる）
struct AllowedViewer: Codable, Identifiable {
    let id: String
    var name: String
    let token: String
    let addedMs: Int64
}

enum AllowedViewers {
    private static let key = "allowedViewers"
    static func all() -> [AllowedViewer] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let a = try? JSONDecoder().decode([AllowedViewer].self, from: d) else { return [] }
        return a
    }
    private static func save(_ a: [AllowedViewer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(a), forKey: key)
    }
    static func find(_ id: String, token: String?) -> AllowedViewer? {
        guard let token else { return nil }
        return all().first { $0.id == id && $0.token == token }
    }
    static func add(id: String, name: String) {
        let v = AllowedViewer(id: id, name: name, token: LinkConfig.randomToken(), addedMs: LinkConfig.nowMs)
        save(all().filter { $0.id != id } + [v])
    }
    static func rename(_ id: String, to name: String) {
        var a = all()
        guard let i = a.firstIndex(where: { $0.id == id }), a[i].name != name else { return }
        a[i].name = name
        save(a)
    }
    static func remove(_ id: String) { save(all().filter { $0.id != id }) }
}

// MARK: - 撮る側

/// 見る側から申し込みを受ける。初めての端末は本人のそばの画面で確かめ、許可した端末は次から確認なしでつなぐ。
/// 見る端末ごとにセッションを分ける（1台ずつ切れるように）
final class CameraLink: NSObject, ObservableObject, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    struct Request: Identifiable {
        let id = UUID()
        let peer: MCPeerID
        let info: InviteInfo?
        let reply: (Bool, MCSession?) -> Void
    }

    @Published private(set) var viewers: [MCPeerID] = []
    @Published private(set) var requests: [Request] = []

    /// 今の普段（main で触る）。変わったら、見ている端末みんなに1回送る。つながったときにも送る
    var baseline: LiveBaseline? {
        didSet { sendBaseline(to: Array(sessions.values)) }
    }

    /// 見る側で付けた印・場面（main で呼ぶ）。名前は撮る側から見えている、その端末の名前
    var onViewerEvent: ((LiveEvent, String, Bool) -> Void)?

    let cameraID = LinkConfig.persistentID("cameraID")
    private var me: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var sessions: [MCPeerID: MCSession] = [:] {     // main で触る
        didSet { lock.lock(); targets = Array(sessions.values); lock.unlock() }
    }
    private var targets: [MCSession] = []                   // 映像のスレッドから読む写し（lock）
    private var viewerIDs: [MCPeerID: String] = [:]         // main で触る
    private var noticeSessions: [MCPeerID: MCSession] = [:] // 「取り消されています」を伝えるだけのつながり（見ている端末に数えない）
    private let sendQueue = DispatchQueue(label: "link.send", qos: .utility)
    private let lock = NSLock()
    private var sendingState = false, sendingVideo = false
    private let encoder = JSONEncoder()

    func start() {
        guard advertiser == nil else { return }
        let me = MCPeerID(displayName: LinkConfig.deviceName)
        self.me = me
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["role": "camera", "id": cameraID],
                                          serviceType: LinkConfig.service)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        for r in requests { r.reply(false, nil) }
        requests = []
        for s in sessions.values { s.disconnect() }
        for s in noticeSessions.values { s.disconnect() }
        sessions = [:]; viewerIDs = [:]; noticeSessions = [:]
        viewers = []
    }

    /// 「〇〇に状態を送りますか？」への答え。「送る」なら覚えて、次から確認なしでつなぐ
    func answer(_ r: Request, send: Bool) {
        requests.removeAll { $0.id == r.id }
        guard send else { r.reply(false, nil); return }
        if let info = r.info { AllowedViewers.add(id: info.id, name: r.peer.displayName) }
        accept(r.peer, viewerID: r.info?.id, reply: r.reply)
    }

    private func accept(_ peer: MCPeerID, viewerID: String?, reply: (Bool, MCSession?) -> Void) {
        guard let me else { reply(false, nil); return }
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        sessions[peer] = s
        viewerIDs[peer] = viewerID
        reply(true, s)
    }

    /// 見ている端末を切る
    func disconnect(_ peer: MCPeerID) {
        guard let s = sessions.removeValue(forKey: peer) else { return }
        viewerIDs[peer] = nil
        if let d = try? JSONEncoder().encode(Wire(kind: "bye")) { try? s.send(d, toPeers: s.connectedPeers, with: .reliable) }
        s.disconnect()
        viewers.removeAll { $0 == peer }
    }

    /// 許可を取り消した端末がつながっていれば切る
    func disconnect(viewerID: String) {
        for (p, id) in viewerIDs where id == viewerID { disconnect(p) }
    }

    /// 1秒に10回程度。送っている途中なら今回は飛ばす（解析のじゃまをしない）
    func send(_ state: LiveState) {
        guard !viewers.isEmpty, begin(\.sendingState) else { return }
        let targets = Array(sessions.values)
        sendQueue.async { [weak self] in
            guard let self else { return }
            if let d = try? self.encoder.encode(Wire(kind: "state", state: state)) {
                for s in targets where !s.connectedPeers.isEmpty { try? s.send(d, toPeers: s.connectedPeers, with: .unreliable) }
            }
            self.end(\.sendingState)
        }
    }

    func send(_ event: LiveEvent) {
        guard !viewers.isEmpty else { return }
        let targets = Array(sessions.values)
        sendQueue.async { [weak self] in
            guard let d = try? self?.encoder.encode(Wire(kind: "event", event: event)) else { return }
            for s in targets where !s.connectedPeers.isEmpty { try? s.send(d, toPeers: s.connectedPeers, with: .reliable) }
        }
    }

    private func sendBaseline(to targets: [MCSession]) {
        guard !targets.isEmpty, let d = try? JSONEncoder().encode(Wire(kind: "baseline", baseline: baseline)) else { return }
        sendQueue.async {
            for s in targets where !s.connectedPeers.isEmpty { try? s.send(d, toPeers: s.connectedPeers, with: .reliable) }
        }
    }

    /// 映像（JPEG）。どのスレッドから呼んでもよい
    func sendVideo(_ jpeg: Data) {
        lock.lock(); let targets = self.targets; lock.unlock()
        guard !targets.isEmpty else { return }
        sendQueue.async {
            var d = Data([LinkConfig.videoTag]); d.append(jpeg)
            for s in targets where !s.connectedPeers.isEmpty { try? s.send(d, toPeers: s.connectedPeers, with: .reliable) }
        }
    }

    private func begin(_ k: ReferenceWritableKeyPath<CameraLink, Bool>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if self[keyPath: k] { return false }
        self[keyPath: k] = true
        return true
    }
    private func end(_ k: ReferenceWritableKeyPath<CameraLink, Bool>) {
        lock.lock(); self[keyPath: k] = false; lock.unlock()
    }

    // MARK: delegate（MultipeerConnectivity のスレッドから呼ばれる）

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let info = context.flatMap { try? JSONDecoder().decode(InviteInfo.self, from: $0) }
        DispatchQueue.main.async {
            // 許可した端末（合言葉が合う）なら確認なしでつなぐ。「〇〇が見ています」はつながったら必ず出る
            if let info, AllowedViewers.find(info.id, token: info.token) != nil {
                AllowedViewers.rename(info.id, to: peerID.displayName)
                self.accept(peerID, viewerID: info.id, reply: invitationHandler)
                return
            }
            // 合言葉を持っているのに合わない（取り消した・知らない）：確認は出さず、理由を伝えて断る。
            // 申し込みの断り方には理由を付けられないので、伝えるだけのつながりを受けて「revoked」を送り、すぐ切る
            if info?.token != nil, let me = self.me {
                let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
                s.delegate = self
                self.noticeSessions[peerID] = s
                invitationHandler(true, s)
                return
            }
            self.requests.removeAll { $0.peer == peerID }
            self.requests.append(Request(peer: peerID, info: info, reply: invitationHandler))
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                if self.noticeSessions[peerID] === session {
                    if let d = try? JSONEncoder().encode(Wire(kind: "revoked")) {
                        try? session.send(d, toPeers: [peerID], with: .reliable)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { session.disconnect() }
                    return
                }
                guard self.sessions[peerID] === session else { return }
                if !self.viewers.contains(peerID) { self.viewers.append(peerID) }
                // 合言葉を渡す（暗号化されたつながりの上で）
                if let id = self.viewerIDs[peerID], let v = AllowedViewers.all().first(where: { $0.id == id }),
                   let d = try? JSONEncoder().encode(Wire(kind: "grant", token: v.token, cameraID: self.cameraID)) {
                    try? session.send(d, toPeers: [peerID], with: .reliable)
                }
                self.sendBaseline(to: [session])
            case .notConnected:
                if self.noticeSessions[peerID] === session { self.noticeSessions[peerID] = nil; return }
                if self.sessions[peerID] === session { self.sessions[peerID] = nil; self.viewerIDs[peerID] = nil }
                self.viewers.removeAll { $0 == peerID }
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return }
        switch w.kind {
        case "ping":
            if let reply = try? JSONEncoder().encode(Wire(kind: "pong", t0: w.t0, tc: LinkConfig.nowMs)) {
                try? session.send(reply, toPeers: [peerID], with: .unreliable)
            }
        case "viewer_event":
            guard let e = w.event else { return }
            DispatchQueue.main.async {
                guard self.sessions[peerID] === session else { return }
                self.onViewerEvent?(e, peerID.displayName, w.clockCorrected ?? false)
            }
        default: break
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - 見る側

/// 起動したら近くの撮る側を探して自動でつなぎ、切れたら自動でつなぎ直す。受け取ったものはメモリにだけ置き、何も保存しない
final class ViewerLink: NSObject, ObservableObject, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    enum Status: Equatable {
        case searching
        case requesting(String)       // 撮る側の画面で確かめてもらっている（初めての端末）
        case connecting(String)       // 許可済み：確認なしでつないでいる
        case connected(String)
        case retrying(String, Date)   // つながらなかった（電波・時間切れ・見つからない・裏に回っている）。合言葉は持ったまま、この時刻につなぎ直す
        case needsApproval(String)    // 撮る側で許可が取り消されている。手で申し込み、撮る側で確かめてもらう
    }

    /// 時間の流れの帯の1区間（撮る側の時計、秒）
    struct Run<V: Equatable>: Equatable {
        var start: Double
        var end: Double
        var value: V
    }

    /// 指標ごとの帯の塗り
    enum Band: Equatable {
        case above, below      // いつもより上／下（「いつもとの違い」に出ていた）
        case usual             // いつもの範囲
        case notCompared       // 比べていない（記録していない・普段を記録中・顔が読めない・データ不足・値が無い）
    }

    static let historyWindow = 15 * 60.0   // 時間の流れは最長15分（この端末のメモリにだけ置く）
    static let runGap = 1.0                // これより間が空いたら（つながっていなかったなど）、帯を途切れさせる

    @Published private(set) var found: [MCPeerID] = []
    @Published private(set) var status = Status.searching
    @Published private(set) var state: LiveState?
    @Published private(set) var lastReceived: Date?
    @Published private(set) var latencyMs: Double?
    @Published private(set) var events: [LiveEvent] = []   // 直近15分の家族の印・場面（画面に出すだけ）
    @Published private(set) var bands: [Metric: [Run<Band>]] = [:]   // 直近15分の時間の流れ（メモリだけ）
    @Published private(set) var scenes: [Run<String>] = []
    @Published private(set) var baseline: LiveBaseline?    // 撮る側の普段（いつもの範囲を描く）
    @Published private(set) var video: UIImage?
    @Published private(set) var videoAt: Date?
    @Published var notice: String?

    private let viewerID = LinkConfig.persistentID("viewerID")
    private var me: MCPeerID?
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    private var cameraIDs: [MCPeerID: String] = [:]
    private var declined: Set<String> = []        // 起動中に「送らない」だった撮る側（自動では申し込まない）
    private var timer: Timer?
    private var tick = 0
    private var inviteStarted: Date?
    private var retryCameraID: String?
    private var retryDelay = 0.0                  // 2, 4, 8, 16, 30, 30… 秒
    private var clock: [(rtt: Int64, offset: Double)] = []   // 撮る側の時計 − こちらの時計
    private var historyCameraID: String?          // 時間の流れを貯めている撮る側（別の撮る側につないだら消す）
    private let decoder = JSONDecoder()

    private var tokens: [String: String] {   // 撮る側の ID → 合言葉
        get { UserDefaults.standard.dictionary(forKey: "viewerTokens") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "viewerTokens") }
    }

    func start() {
        guard browser == nil else { return }
        let me = MCPeerID(displayName: LinkConfig.deviceName)
        self.me = me
        let b = MCNearbyServiceBrowser(peer: me, serviceType: LinkConfig.service)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
        status = .searching
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.onTimer() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        found = []; cameraIDs = [:]
        status = .searching
        video = nil
    }

    /// 手で申し込む（前に「送らない」だった撮る側・取り消された撮る側にも）
    func request(_ peer: MCPeerID) {
        if let id = cameraIDs[peer] { declined.remove(id) }
        retryCameraID = nil; retryDelay = 0
        invite(peer)
    }

    /// 合言葉は持ったまま、間をあけてつなぎ直す
    private func scheduleRetry(cameraID: String, name: String) {
        retryCameraID = cameraID
        retryDelay = retryDelay == 0 ? 2 : min(retryDelay * 2, 30)
        status = .retrying(name, Date().addingTimeInterval(retryDelay))
    }

    private func peer(for cameraID: String) -> MCPeerID? {
        found.last { cameraIDs[$0] == cameraID }
    }

    /// 見る側で押した印・場面を、撮る側に送って記録してもらう。時刻は押した瞬間を、撮る側の時計に直して送る
    func sendEvent(kind: String, value: String) {
        guard case .connected = status, let session, !session.connectedPeers.isEmpty else { return }
        let off = offsetMs
        let e = LiveEvent(tMs: Int64((Double(LinkConfig.nowMs) + (off ?? 0)).rounded()), kind: kind, value: value)
        guard let d = try? JSONEncoder().encode(Wire(kind: "viewer_event", event: e, clockCorrected: off != nil)) else { return }
        try? session.send(d, toPeers: session.connectedPeers, with: .reliable)
    }

    private func onTimer() {
        tick += 1
        if case .connected = status {
            if tick % 2 == 0 { ping() }
            trim()
            return
        }
        // 申し込んだまま答えが無い（撮る側が裏に回った、など）
        if let s = inviteStarted, Date().timeIntervalSince(s) > 65 {
            inviteStarted = nil
            let st = status
            session?.disconnect()
            if case .connecting(let name) = st, let id = retryCameraID ?? currentCameraID {
                scheduleRetry(cameraID: id, name: name)
            } else {
                status = .searching
            }
        }
        switch status {
        case .searching: autoConnect()
        case .retrying(let name, let at) where Date() >= at:
            guard let id = retryCameraID else { status = .searching; return }
            if let p = peer(for: id) {
                invite(p)
            } else {
                scheduleRetry(cameraID: id, name: name)   // 見つからない：撮る側が戻ってきたら foundPeer ですぐつなぐ
            }
        default: break
        }
    }

    /// 許可済みの撮る側を先に。初めての撮る側には、起動中に断られていなければ申し込む
    private func autoConnect() {
        let t = tokens
        let candidates = found.filter { p in cameraIDs[p].map { !declined.contains($0) } ?? false }
        if let p = candidates.first(where: { t[cameraIDs[$0] ?? ""] != nil }) ?? candidates.first { invite(p) }
    }

    private var currentCameraID: String?

    private func invite(_ peer: MCPeerID) {
        guard let me, let browser else { return }
        currentCameraID = cameraIDs[peer]
        session?.disconnect()
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s
        let token = cameraIDs[peer].flatMap { tokens[$0] }
        let info = InviteInfo(id: viewerID, name: me.displayName, token: token)
        notice = nil
        status = token != nil ? .connecting(peer.displayName) : .requesting(peer.displayName)
        inviteStarted = Date()
        browser.invitePeer(peer, to: s, withContext: try? JSONEncoder().encode(info), timeout: token != nil ? 15 : 60)
    }

    private func ping() {
        guard let session, !session.connectedPeers.isEmpty,
              let d = try? JSONEncoder().encode(Wire(kind: "ping", t0: LinkConfig.nowMs)) else { return }
        try? session.send(d, toPeers: session.connectedPeers, with: .unreliable)
    }

    /// 往復が一番短かったときのずれを使う
    private var offsetMs: Double? { clock.min { $0.rtt < $1.rtt }?.offset }

    private func trim() {
        guard let last = state?.captureMs else { return }
        let from = Double(last) / 1000 - Self.historyWindow
        for (m, runs) in bands {
            if let i = runs.firstIndex(where: { $0.end >= from }), i > 0 { bands[m]!.removeFirst(i) }
        }
        if let i = scenes.firstIndex(where: { $0.end >= from }), i > 0 { scenes.removeFirst(i) }
        events.removeAll { Double($0.tMs) / 1000 < from }
    }

    /// そのとき、この指標がどう見えていたか（撮る側の「いつもとの違い」と同じ決まり）
    static func band(_ m: Metric, in s: LiveState) -> Band {
        guard s.recording, s.baselineReady, !s.insufficient.contains(m.label),
              !(m.isFace && !s.faceReadable) else { return .notCompared }
        if let d = s.diffs?.first(where: { $0.metric == m.rawValue }) { return d.above ? .above : .below }
        return s.z?[m.rawValue] != nil ? .usual : .notCompared
    }

    private static func extend<V: Equatable>(_ runs: inout [Run<V>], at t: Double, _ v: V) {
        if let last = runs.last, t - last.end <= runGap {
            guard t >= last.end else { return }   // 順番が入れ替わって届いたもの
            if last.value == v { runs[runs.count - 1].end = t } else { runs.append(Run(start: last.end, end: t, value: v)) }
        } else {
            runs.append(Run(start: t, end: t, value: v))
        }
    }

    private func addHistory(_ s: LiveState) {
        let t = Double(s.captureMs) / 1000
        var b = bands
        for m in Metric.allCases { Self.extend(&b[m, default: []], at: t, Self.band(m, in: s)) }
        bands = b
        if let name = s.scene { Self.extend(&scenes, at: t, name) }
    }

    // MARK: delegate

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "camera" else { return }
        DispatchQueue.main.async {
            self.cameraIDs[peerID] = info?["id"] ?? peerID.displayName
            if !self.found.contains(peerID) { self.found.append(peerID) }
            switch self.status {
            case .searching: self.autoConnect()
            case .retrying where self.cameraIDs[peerID] == self.retryCameraID:
                self.invite(peerID)   // 撮る側が前に戻った：待たずにつなぐ
            default: break
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.found.removeAll { $0 == peerID }
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.session else { return }
            switch state {
            case .connected:
                self.inviteStarted = nil
                self.retryDelay = 0; self.retryCameraID = nil
                self.status = .connected(peerID.displayName)
                self.clock = []
                // 同じ撮る側につなぎ直したときは、時間の流れを続ける（別の撮る側なら消す）
                let id = self.cameraIDs[peerID] ?? self.currentCameraID
                if id != self.historyCameraID {
                    self.historyCameraID = id
                    self.bands = [:]; self.scenes = []; self.events = []   // 普段は、撮る側がつながったときに必ず送ってくる
                }
                self.ping()
            case .notConnected:
                self.inviteStarted = nil
                self.video = nil
                let id = self.cameraIDs[peerID] ?? self.currentCameraID
                switch self.status {
                case .requesting(let name):
                    self.notice = "\(name) で「送らない」が選ばれたか、時間内に答えがありませんでした"
                    if let id { self.declined.insert(id) }
                    self.status = .searching
                case .connecting(let name), .connected(let name):
                    // 電波・時間切れ・裏に回った など。合言葉は忘れずに、間をあけてつなぎ直す
                    if let id, self.tokens[id] != nil {
                        self.scheduleRetry(cameraID: id, name: name)
                    } else {
                        self.status = .searching
                    }
                case .needsApproval, .retrying: break
                case .searching: break
                }
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let t1 = LinkConfig.nowMs
        if data.first == LinkConfig.videoTag {
            let img = UIImage(data: data.dropFirst())   // 表示するだけ（保存しない）
            DispatchQueue.main.async {
                guard session === self.session else { return }
                self.video = img; self.videoAt = Date()
            }
            return
        }
        guard let w = try? decoder.decode(Wire.self, from: data) else { return }
        DispatchQueue.main.async {
            guard session === self.session else { return }
            switch w.kind {
            case "state":
                guard let s = w.state else { return }
                self.state = s
                self.lastReceived = Date()
                if let off = self.offsetMs { self.latencyMs = Double(t1) + off - Double(s.captureMs) }
                self.addHistory(s)
            case "baseline":
                self.baseline = w.baseline
            case "event":
                if let e = w.event { self.events.append(e) }
            case "pong":
                guard let t0 = w.t0, let tc = w.tc, t1 >= t0 else { return }
                self.clock.append((t1 - t0, Double(tc) - Double(t0 + t1) / 2))
                if self.clock.count > 15 { self.clock.removeFirst() }
            case "grant":
                if let id = w.cameraID, let token = w.token { self.tokens[id] = token }
            case "revoked":
                // 撮る側がはっきり「取り消されています／知らない」と返したときだけ、合言葉を忘れる
                let name = peerID.displayName
                if let id = self.cameraIDs[peerID] ?? self.currentCameraID {
                    self.tokens[id] = nil
                    self.declined.insert(id)   // 自動では申し込まない（撮る側に確認を出さないため）
                }
                self.retryDelay = 0; self.retryCameraID = nil
                self.status = .needsApproval(name)
                self.notice = nil
                session.disconnect()
            case "bye":
                self.notice = "\(peerID.displayName) が送るのを止めました（「見たいと申し込む」でもう一度つなげます）"
                if let id = self.cameraIDs[peerID] { self.declined.insert(id) }   // 自動ではつなぎ直さない
                session.disconnect()
                self.status = .searching
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
