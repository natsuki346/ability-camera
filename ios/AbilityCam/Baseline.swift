import Foundation
import SwiftUI

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

    /// グラフと網目で使う色（docs/wording-guide.md：赤と赤・黄・緑の組み合わせを使わない）
    var color: Color {
        switch self {
        case .mouthSmile: Color(red: 0x56 / 255, green: 0xB4 / 255, blue: 0xE9 / 255)   // 空色
        case .browDown: Color(red: 0xE6 / 255, green: 0x9F / 255, blue: 0x00 / 255)     // アンバー
        case .eyeSquint: Color(red: 0xA4 / 255, green: 0x8C / 255, blue: 0xD1 / 255)    // 薄紫
        case .jawOpen: Color(red: 0x3B / 255, green: 0x78 / 255, blue: 0xC2 / 255)      // 青
        case .rmsDb: Color(red: 0x9C / 255, green: 0x85 / 255, blue: 0x72 / 255)        // 灰茶
        case .f0Hz: Color(red: 0xCC / 255, green: 0x79 / 255, blue: 0xA7 / 255)         // 赤紫
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

    /// 向きだけの短い言い方（見る側のメーターの横に出す）
    func directionText(above: Bool) -> String {
        switch self {
        case .rmsDb: above ? "いつもより大きい" : "いつもより小さい"
        case .f0Hz: above ? "いつもより高い" : "いつもより低い"
        default: above ? "いつもより強い" : "いつもより弱い"
        }
    }

    /// 数値の書き方（表情は 0〜1、声は dB / Hz）。パーセントにはしない
    func valueText(_ v: Double) -> String {
        switch self {
        case .rmsDb: String(format: "%.0f dB", v)
        case .f0Hz: String(format: "%.0f Hz", v)
        default: String(format: "%.2f", v)
        }
    }

    /// 値として取りうる範囲（いつもの範囲を書くときに、この外は切る）
    var valueBounds: ClosedRange<Double> {
        switch self {
        case .rmsDb: -120...0
        case .f0Hz: 0...2000
        default: 0...1
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
