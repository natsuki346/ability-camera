import Foundation

/// 顔の向きの段（見る側の「時間の流れ」と、記録の head_turn）。状態の名前ではなく、向きの事実だけ
enum HeadState: String, Codable, CaseIterable {
    case front          // 正面（|yaw| < 15° になってから、35° を超えるまで）
    case right, left    // 映像で見て右／左へ 35° を超えた（15° 未満に戻るまで）
    case hidden         // 顔が見えない
    case oblique        // 見えなくなったあと、15〜35° で見えるようになった（正面にも横にも入っていない）

    var label: String {
        switch self {
        case .front: "正面"
        case .right: "右"
        case .left: "左"
        case .hidden: "見えない"
        case .oblique: "斜め（15〜35°）"
        }
    }
}

/// 顔を向ける・そむけるを、0.5秒以上続いたときだけ確かめる（ちらつきを防ぐ）。
/// 正面は |yaw| < 15°、横は |yaw| > 35°。その間（15〜35°）では今の状態を続ける。
/// analysis/review.py の head_states() も同じ決まり
struct HeadTurnTracker {
    static let sideDeg = 35.0
    static let frontDeg = 15.0
    static let holdS = 0.5

    struct Change {
        let tMs: Int64          // その向きになり始めた時刻（0.5秒続いたのを確かめた時刻ではない）
        let from: HeadState
        let to: HeadState
        let yawDeg: Double?     // 右・左・正面：なり始めたときの yaw。見えない：見えなくなる直前の yaw
        var value: String { HeadTurnTracker.text(to: to, yaw: yawDeg) }
    }

    private(set) var state: HeadState?
    private var pending: (state: HeadState, tMs: Int64, yaw: Double?)?
    private var lastYaw: Double?    // 最後に見えたときの yaw

    mutating func reset() { state = nil; pending = nil; lastYaw = nil }

    /// 1コマごとに呼ぶ。向きが変わって 0.5秒続いたときだけ Change を返す（最初に決まったときは返さない）
    mutating func add(tMs: Int64, face: Bool, yaw: Double?) -> Change? {
        if face && yaw == nil { return nil }   // 顔はあるが向きが取れなかったコマは数えない
        let target = Self.target(face: face, yaw: yaw, current: state)
        let before = lastYaw
        if face { lastYaw = yaw }
        if target == state { pending = nil; return nil }
        if pending?.state != target {
            pending = (target, tMs, target == .hidden ? before : yaw)
        }
        guard let p = pending, Double(tMs - p.tMs) / 1000 >= Self.holdS else { return nil }
        let from = state
        state = target
        pending = nil
        guard let from else { return nil }
        return Change(tMs: p.tMs, from: from, to: target, yawDeg: p.yaw)
    }

    static func target(face: Bool, yaw: Double?, current: HeadState?) -> HeadState {
        guard face, let y = yaw else { return .hidden }
        if y > sideDeg { return .right }
        if y < -sideDeg { return .left }
        if abs(y) < frontDeg { return .front }
        switch current {   // 15〜35°：今の状態を続ける。見えなかった（または初め）なら「斜め」
        case nil, .hidden?: return .oblique
        case let s?: return s
        }
    }

    /// 記録の value。事実だけ（「右へ」「見えなくなった（直前は右 40°）」など）
    static func text(to: HeadState, yaw: Double?) -> String {
        switch to {
        case .right: "右へ"
        case .left: "左へ"
        case .front: "正面に戻った"
        case .hidden: yaw.map { "見えなくなった（直前は\(side($0))）" } ?? "見えなくなった"
        case .oblique: "見えるようになった（\(yaw.map(side) ?? "斜め")）"
        }
    }

    /// 「右 40°」「左 20°」「正面」（映像で見て右が +）
    static func side(_ yaw: Double) -> String {
        let d = Int(abs(yaw).rounded())
        if abs(yaw) < frontDeg { return "正面" }
        return "\(yaw > 0 ? "右" : "左") \(d)°"
    }
}
