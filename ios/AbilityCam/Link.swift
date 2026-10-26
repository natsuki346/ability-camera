import Foundation
import MultipeerConnectivity
import UIKit

/// 撮る側 → 見る側 に送るもの。映像・音声・顔の478点・JSONL は送らない
struct LiveState: Codable {
    var captureMs: Int64              // 撮影の時刻（撮る側の時計、epoch ms）
    var sentMs: Int64
    var faceReadable: Bool
    var yaw: Double?, pitch: Double?, roll: Double?
    var shape: [String: Double]?      // 顔の絵を動かす表情の数値（ならした値）と向き。読めないときは nil
    var differences: [String]         // 「眉を寄せる動きが、いつもより強い（12秒）」の一覧
    var baselineSec: Int?             // 普段を記録中の数えた秒（記録し終えたら nil）
    var baselineTotal: Int
    var baselineReady: Bool
    var baselineWait: String?
    var insufficient: [String]
    var recording: Bool
    var sessionStartedMs: Int64?
    var faceRatio: Double?
    var fps: Double?
}

/// 家族の印・場面
struct LiveEvent: Codable, Identifiable {
    var id = UUID()
    let tMs: Int64
    let kind: String                  // mark / scene
    let value: String
}

/// 1通の中身。ping / pong は、2台の時計のずれを測って「撮影→届くまで」を出すため
struct Wire: Codable {
    var kind: String                  // state / event / ping / pong / bye
    var state: LiveState?
    var event: LiveEvent?
    var t0: Int64?                    // ping を送った時刻（見る側の時計）
    var tc: Int64?                    // pong を返した時刻（撮る側の時計）
}

enum LinkConfig {
    static let service = "abilitycam"   // Info.plist の NSBonjourServices と同じ（_abilitycam._tcp / _udp）
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static var deviceName: String {
        let s = UserDefaults.standard.string(forKey: "deviceName")?.trimmingCharacters(in: .whitespaces) ?? ""
        var name = s.isEmpty ? UIDevice.current.name : s
        while name.utf8.count > 63 { name.removeLast() }   // MCPeerID の名前は 63 バイトまで（日本語は1字3バイト）
        return name.isEmpty ? "Ability Cam" : name
    }
}

// MARK: - 撮る側

/// 見る側から申し込みを受け、本人のそばの画面で確かめてから送る。見る端末ごとにセッションを分ける（1台ずつ切れるように）
final class CameraLink: NSObject, ObservableObject, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    struct Request: Identifiable {
        let id = UUID()
        let peer: MCPeerID
        let reply: (Bool, MCSession?) -> Void
    }

    @Published private(set) var viewers: [MCPeerID] = []
    @Published private(set) var requests: [Request] = []

    private var me: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var sessions: [MCPeerID: MCSession] = [:]    // main で触る
    private let sendQueue = DispatchQueue(label: "link.send", qos: .utility)
    private let lock = NSLock()
    private var sending = false
    private let encoder = JSONEncoder()

    func start() {
        guard advertiser == nil else { return }
        let me = MCPeerID(displayName: LinkConfig.deviceName)
        self.me = me
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["role": "camera"], serviceType: LinkConfig.service)
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
        sessions = [:]
        viewers = []
    }

    /// 「〇〇に状態を送りますか？」への答え
    func answer(_ r: Request, send: Bool) {
        requests.removeAll { $0.id == r.id }
        guard send, let me else { r.reply(false, nil); return }
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        sessions[r.peer] = s
        r.reply(true, s)
    }

    /// 見ている端末を切る
    func disconnect(_ peer: MCPeerID) {
        guard let s = sessions.removeValue(forKey: peer) else { return }
        if let d = try? JSONEncoder().encode(Wire(kind: "bye")) { try? s.send(d, toPeers: s.connectedPeers, with: .reliable) }
        s.disconnect()
        viewers.removeAll { $0 == peer }
    }

    /// 1秒に10回程度。送っている途中なら今回は飛ばす（解析のじゃまをしない）
    func send(_ state: LiveState) {
        guard !viewers.isEmpty else { return }
        lock.lock()
        if sending { lock.unlock(); return }
        sending = true
        lock.unlock()
        let targets = Array(sessions.values)
        sendQueue.async { [weak self] in
            guard let self else { return }
            if let d = try? self.encoder.encode(Wire(kind: "state", state: state)) {
                for s in targets where !s.connectedPeers.isEmpty { try? s.send(d, toPeers: s.connectedPeers, with: .unreliable) }
            }
            self.lock.lock(); self.sending = false; self.lock.unlock()
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

    // MARK: delegate（MultipeerConnectivity のスレッドから呼ばれる）

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            self.requests.removeAll { $0.peer == peerID }
            self.requests.append(Request(peer: peerID, reply: invitationHandler))
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                guard self.sessions[peerID] === session else { return }
                if !self.viewers.contains(peerID) { self.viewers.append(peerID) }
            case .notConnected:
                if self.sessions[peerID] === session { self.sessions[peerID] = nil }
                self.viewers.removeAll { $0 == peerID }
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data), w.kind == "ping",
              let reply = try? JSONEncoder().encode(Wire(kind: "pong", t0: w.t0, tc: LinkConfig.nowMs)) else { return }
        try? session.send(reply, toPeers: [peerID], with: .unreliable)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - 見る側

/// 近くの撮る側を探し、「見たい」と申し込む。受け取ったものは画面に出すだけで、何も保存しない
final class ViewerLink: NSObject, ObservableObject, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    enum Status: Equatable {
        case idle
        case requesting(String)       // 撮る側の画面で確かめてもらっている
        case connected(String)
    }

    @Published private(set) var found: [MCPeerID] = []
    @Published private(set) var status = Status.idle
    @Published private(set) var state: LiveState?
    @Published private(set) var lastReceived: Date?
    @Published private(set) var latencyMs: Double?
    @Published private(set) var events: [LiveEvent] = []   // 直近だけ（画面に出すだけ）
    @Published var notice: String?

    private var me: MCPeerID?
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    private var pingTimer: Timer?
    private var clock: [(rtt: Int64, offset: Double)] = []   // 撮る側の時計 − こちらの時計
    private let decoder = JSONDecoder()

    func start() {
        guard browser == nil else { return }
        let me = MCPeerID(displayName: LinkConfig.deviceName)
        self.me = me
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s
        let b = MCNearbyServiceBrowser(peer: me, serviceType: LinkConfig.service)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        pingTimer?.invalidate(); pingTimer = nil
        found = []
        status = .idle
    }

    /// 「見たい」と申し込む
    func request(_ peer: MCPeerID) {
        guard let session, let browser else { return }
        notice = nil
        status = .requesting(peer.displayName)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 60)
    }

    func leave() {
        session?.disconnect()
        status = .idle
    }

    private func ping() {
        guard let session, !session.connectedPeers.isEmpty,
              let d = try? JSONEncoder().encode(Wire(kind: "ping", t0: LinkConfig.nowMs)) else { return }
        try? session.send(d, toPeers: session.connectedPeers, with: .unreliable)
    }

    /// 往復が一番短かったときのずれを使う
    private var offsetMs: Double? { clock.min { $0.rtt < $1.rtt }?.offset }

    // MARK: delegate

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.found.contains(peerID) { self.found.append(peerID) }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.found.removeAll { $0 == peerID } }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.session else { return }
            switch state {
            case .connected:
                self.status = .connected(peerID.displayName)
                self.clock = []
                self.events = []
                self.pingTimer?.invalidate()
                self.ping()
                self.pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.ping() }
            case .notConnected:
                if case .requesting(let name) = self.status {
                    self.notice = "\(name) で「送らない」が選ばれたか、時間内に答えがありませんでした"
                }
                if session.connectedPeers.isEmpty {
                    self.status = .idle
                    self.pingTimer?.invalidate(); self.pingTimer = nil
                }
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let t1 = LinkConfig.nowMs
        guard let w = try? decoder.decode(Wire.self, from: data) else { return }
        DispatchQueue.main.async {
            switch w.kind {
            case "state":
                guard let s = w.state else { return }
                self.state = s
                self.lastReceived = Date()
                if let off = self.offsetMs { self.latencyMs = Double(t1) + off - Double(s.captureMs) }
            case "event":
                guard let e = w.event else { return }
                self.events.insert(e, at: 0)
                if self.events.count > 8 { self.events.removeLast() }
            case "pong":
                guard let t0 = w.t0, let tc = w.tc, t1 >= t0 else { return }
                self.clock.append((t1 - t0, Double(tc) - Double(t0 + t1) / 2))
                if self.clock.count > 15 { self.clock.removeFirst() }
            case "bye":
                self.notice = "\(peerID.displayName) が送るのを止めました"
                session.disconnect()
                self.status = .idle
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
