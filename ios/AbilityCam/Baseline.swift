import Foundation

/// 「いつもとの違い」を見る指標。状態の名前は付けない（意味の解釈は家族がする）
enum Metric: String, CaseIterable {
    case mouthSmile = "mouth_smile", browDown = "brow_down", eyeSquint = "eye_squint", jawOpen = "jaw_open"
    case rmsDb = "rms_db", f0Hz = "f0_hz"

    var isFace: Bool { self != .rmsDb && self != .f0Hz }

    var label: String {
        switch self {
        case .mouthSmile: "口角を上げる"
        case .browDown: "眉を寄せる"
        case .eyeSquint: "目を細める"
        case .jawOpen: "口を開ける"
        case .rmsDb: "声の大きさ"
        case .f0Hz: "声の高さ"
        }
    }

    /// 標準偏差の下限（普段がほとんど動かない指標で、わずかな揺れを大きな違いと見なさないため）
    var stdFloor: Double {
        switch self {
        case .rmsDb: 2       // dB
        case .f0Hz: 10       // Hz
        default: 0.03        // 表情の数値（0〜1）
        }
    }

    /// z から、画面に出す文。表情は「強い」だけ、声は「大きい／小さい」「高い／低い」
    func message(z: Double) -> String? {
        switch self {
        case .rmsDb: z >= 2 ? "声が、いつもより大きい" : z <= -2 ? "声が、いつもより小さい" : nil
        case .f0Hz: z >= 2 ? "声が、いつもより高い" : z <= -2 ? "声が、いつもより低い" : nil
        default: z >= 2 ? "\(label)動きが、いつもより強い" : nil
        }
    }

    /// 記録に書く、違いの向き（"brow_down:above" など）
    func diffKey(z: Double) -> String? {
        guard message(z: z) != nil else { return nil }
        return "\(rawValue):\(z > 0 ? "above" : "below")"
    }
}

/// 平均と標準偏差を1つずつ足しながら求める（Welford 法）
struct Welford {
    private(set) var n = 0
    private(set) var mean = 0.0
    private var m2 = 0.0

    mutating func add(_ x: Double) {
        n += 1
        let d = x - mean
        mean += d / Double(n)
        m2 += d * (x - mean)
    }

    var std: Double { n > 1 ? (m2 / Double(n - 1)).squareRoot() : 0 }
}

/// 約1秒の移動平均（時間で重みを決める EMA）。最後に更新された時刻も持つ
struct Smoother {
    static let tau = 1.0
    private(set) var value: Double?
    private(set) var lastT: Double = -.infinity

    mutating func add(_ x: Double, at t: Double) {
        if let v = value {
            let a = 1 - exp(-max(t - lastT, 0) / Self.tau)
            value = v + a * (x - v)
        } else {
            value = x
        }
        lastT = t
    }

    func fresh(now: Double) -> Bool { value != nil && now - lastT <= 1 }
}
