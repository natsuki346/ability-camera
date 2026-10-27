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

    /// 標準偏差の下限（普段がほとんど動かない指標で、わずかな揺れを大きな違いと見なさないため）。
    /// 振り返りレポート（analysis/criteria.json の std_floor）と同じ
    var stdFloor: Double {
        switch self {
        case .rmsDb: 6       // dB（2026-10-27 に 2 → 6：静かな部屋の小さな物音で違いにならないように）
        case .f0Hz: 10       // Hz
        default: 0.03        // 表情の数値（0〜1）
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
