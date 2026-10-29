import Foundation
import SwiftUI

/// 「いつもとの違い」を見る指標。状態の名前は付けない（意味の解釈は家族がする）
/// v1.12〜：表情のまとまり（orbit・nose_lip・mouth_tense・cheek_raise）を足した。普段・保存した普段・z・データのタブ・重なりのできごと（co_change）には使うが、
/// 「いつもとの違い」の区間・画面の「いま」・見る側・リプレイは今までの6つ（main）だけ（docs/research-expressions.md）
enum Metric: String, CaseIterable {
    case mouthSmile = "mouth_smile", browDown = "brow_down", eyeSquint = "eye_squint", jawOpen = "jaw_open"
    case rmsDb = "rms_db", f0Hz = "f0_hz"
    case orbit, noseLip = "nose_lip", mouthTense = "mouth_tense", cheekRaise = "cheek_raise"
    // 顔の点（478点）から求める距離（v1.15〜、FaceGeometry）。blendshape がほとんど動かない顔のため
    case browEyeGap = "brow_eye_gap", browInnerGap = "brow_inner_gap", eyeOpen = "eye_open", mouthCorner = "mouth_corner"

    /// 「いつもとの違い」の区間・画面・見る側に使う指標（v1.11 までの6つ）
    static let main: [Metric] = [.mouthSmile, .browDown, .eyeSquint, .jawOpen, .rmsDb, .f0Hz]
    /// 表情のまとまり（v1.12〜、記録とレポート・データのタブだけ）
    static let groups: [Metric] = [.orbit, .noseLip, .mouthTense, .cheekRaise]
    /// 顔の点から求める距離（v1.15〜。記録とレポート・データのタブだけ）
    static let geometry: [Metric] = [.browEyeGap, .browInnerGap, .eyeOpen, .mouthCorner]
    var isGeometry: Bool { Self.geometry.contains(self) }
    var isMain: Bool { Self.main.contains(self) }

    var isFace: Bool { self != .rmsDb && self != .f0Hz }
    /// まばたきのコマと前後 0.2秒を使わない（目を細める・目のまわりは、まばたきで動くため）
    var blinkMasked: Bool { self == .eyeSquint || self == .orbit || self == .eyeOpen }   // 目の開き（v1.15〜）も

    /// 表情の値（左右の平均）。bs：表情の数値 52種。目のまわり・鼻と上唇・口の緊張は、左右それぞれで大きい方をとってから平均する（v1.12〜）
    static func faceValues(_ bs: (String) -> Double) -> [Metric: Double] {
        func avg(_ k: String) -> Double { (bs(k + "Left") + bs(k + "Right")) / 2 }
        func maxAvg(_ a: String, _ b: String) -> Double {
            (max(bs(a + "Left"), bs(b + "Left")) + max(bs(a + "Right"), bs(b + "Right"))) / 2
        }
        return [.mouthSmile: avg("mouthSmile"), .browDown: avg("browDown"), .eyeSquint: avg("eyeSquint"), .jawOpen: bs("jawOpen"),
                .orbit: maxAvg("eyeSquint", "cheekSquint"), .noseLip: maxAvg("noseSneer", "mouthUpperUp"),
                .mouthTense: maxAvg("mouthPress", "mouthStretch"), .cheekRaise: avg("cheekSquint")]
    }

    /// 左右の差（左 − 右、本人から見て。v1.12〜、普段と比べて記録するだけで判定には使わない）
    static let asymKeys = ["brow_down", "orbit", "mouth_smile"]
    static func asymmetry(_ bs: (String) -> Double) -> [String: Double] {
        ["brow_down": bs("browDownLeft") - bs("browDownRight"),
         "orbit": max(bs("eyeSquintLeft"), bs("cheekSquintLeft")) - max(bs("eyeSquintRight"), bs("cheekSquintRight")),
         "mouth_smile": bs("mouthSmileLeft") - bs("mouthSmileRight")]
    }

    var label: String {
        switch self {
        case .mouthSmile: "口角を上げる"
        case .browDown: "眉を寄せる"
        case .eyeSquint: "目を細める"
        case .jawOpen: "口を開ける"
        case .rmsDb: "声の大きさ"
        case .f0Hz: "声の高さ"
        case .orbit: "目のまわりを縮める"
        case .noseLip: "鼻・上唇を上げる"
        case .mouthTense: "口を結ぶ・横に引く"
        case .cheekRaise: "頬を上げる"
        case .browEyeGap: "眉と目の間（点）"
        case .browInnerGap: "眉頭の間（点）"
        case .eyeOpen: "目の開き（点）"
        case .mouthCorner: "口角の高さ（点）"
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
        // v1.12〜（データのタブだけ）
        case .orbit: Color(red: 0x7A / 255, green: 0x6F / 255, blue: 0xB0 / 255)        // 藤
        case .noseLip: Color(red: 0xB0 / 255, green: 0x7A / 255, blue: 0xA1 / 255)      // 藤紫
        case .mouthTense: Color(red: 0x5F / 255, green: 0x7F / 255, blue: 0x8F / 255)   // 鉄色
        case .cheekRaise: Color(red: 0x8F / 255, green: 0xB8 / 255, blue: 0xD8 / 255)   // 薄い空色
        // v1.15〜（顔の点の距離。データのタブだけ）
        case .browEyeGap: Color(red: 0xC2 / 255, green: 0x8A / 255, blue: 0x2E / 255)   // 黄土（眉の仲間）
        case .browInnerGap: Color(red: 0x9E / 255, green: 0x74 / 255, blue: 0x2A / 255)  // 濃い黄土
        case .eyeOpen: Color(red: 0x6D / 255, green: 0x5A / 255, blue: 0x9E / 255)       // 菫（目の仲間）
        case .mouthCorner: Color(red: 0x3E / 255, green: 0x92 / 255, blue: 0xB8 / 255)   // 青緑寄りの空色（口角の仲間）
        }
    }

    /// 標準偏差の下限（普段がほとんど動かない指標で、わずかな揺れを大きな違いと見なさないため）。
    /// 振り返りレポート（analysis/criteria.json の std_floor）と同じ
    var stdFloor: Double {
        switch self {
        case .rmsDb: 6       // dB（2026-10-27 に 2 → 6：静かな部屋の小さな物音で違いにならないように）
        case .f0Hz: 10       // Hz
        case .browEyeGap, .browInnerGap, .eyeOpen, .mouthCorner: 0.01   // 目尻の間の距離に対する割合（v1.15〜、仮の値）
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
        case .browEyeGap, .browInnerGap, .eyeOpen, .mouthCorner: String(format: "%.3f", v)
        default: String(format: "%.2f", v)
        }
    }

    /// 値として取りうる範囲（いつもの範囲を書くときに、この外は切る）
    var valueBounds: ClosedRange<Double> {
        switch self {
        case .rmsDb: -120...0
        case .f0Hz: 0...2000
        case .browEyeGap, .browInnerGap, .eyeOpen, .mouthCorner: -1...2
        default: 0...1
        }
    }
}

/// 顔の点（MediaPipe Face Landmarker の 478点）から求める距離（v1.15〜）。どれも左右の目尻（33・263）の間の距離で割る（顔の大きさ・カメラからの距離によらないように）。
/// 縦の距離は、額（10）からあご（152）への向き（顔の下向き）に沿って測る（頭が傾いても縦のまま）。|yaw| が maxYaw を超えるコマは求めない（普段にも比べるのにも使わない）。
/// 点の番号は README の「顔の点の距離」
enum FaceGeometry {
    static let maxYaw = 25.0
    static let eyeOuter = (33, 263)
    static let browMid = (105, 334)          // 眉の中央（上の縁）
    static let upperLid = (159, 386), lowerLid = (145, 374)
    static let browInner = (107, 336)        // 眉頭
    static let mouthCenter = (13, 14), mouthCorners = (61, 291)
    static let forehead = 10, chin = 152
    /// 記録に書く点（あとから確かめるため、frame の geo_pts に [x, y]）
    static let indices = [33, 263, 105, 334, 159, 386, 145, 374, 107, 336, 13, 14, 61, 291, 10, 152]

    /// p：点の番号 → 画像の中の位置（ピクセル。x と y の縮尺をそろえる）。返り値：brow_eye_gap・brow_inner_gap・eye_open・mouth_corner
    static func values(yaw: Double?, _ p: (Int) -> (x: Double, y: Double)?) -> [String: Double]? {
        guard let yaw, abs(yaw) <= maxYaw,
              let e1 = p(eyeOuter.0), let e2 = p(eyeOuter.1), let top = p(forehead), let bottom = p(chin) else { return nil }
        let scale = hypot(e2.x - e1.x, e2.y - e1.y)
        let dl = hypot(bottom.x - top.x, bottom.y - top.y)
        guard scale > 1e-6, dl > 1e-6 else { return nil }
        let down = ((bottom.x - top.x) / dl, (bottom.y - top.y) / dl)
        func along(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double { ((b.x - a.x) * down.0 + (b.y - a.y) * down.1) / scale }
        func dist(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double { hypot(b.x - a.x, b.y - a.y) / scale }
        guard let b1 = p(browMid.0), let b2 = p(browMid.1), let u1 = p(upperLid.0), let u2 = p(upperLid.1),
              let l1 = p(lowerLid.0), let l2 = p(lowerLid.1), let i1 = p(browInner.0), let i2 = p(browInner.1),
              let m1 = p(mouthCenter.0), let m2 = p(mouthCenter.1), let c1 = p(mouthCorners.0), let c2 = p(mouthCorners.1) else { return nil }
        let center = ((m1.x + m2.x) / 2, (m1.y + m2.y) / 2), corners = ((c1.x + c2.x) / 2, (c1.y + c2.y) / 2)
        let r4 = { (x: Double) in (x * 10000).rounded() / 10000 }
        return ["brow_eye_gap": r4((along(b1, u1) + along(b2, u2)) / 2),     // 眉から上まぶたへ下向きに（眉が下がると小さい）
                "brow_inner_gap": r4(dist(i1, i2)),                            // 眉頭の間（寄せると小さい）
                "eye_open": r4((along(u1, l1) + along(u2, l2)) / 2),           // 上まぶたから下まぶたへ（閉じると小さい）
                "mouth_corner": r4(along((corners.0, corners.1), (center.0, center.1)))]   // 口角から口の中央へ下向きに（口角が上がると大きい）
    }
}

extension Metric {
    /// 記録の geo から（v1.15〜）
    static func geometryValues(_ geo: [String: Double]?) -> [Metric: Double] {
        var out: [Metric: Double] = [:]
        for m in geometry { if let v = geo?[m.rawValue] { out[m] = v } }
        return out
    }
}

extension DiffTarget {
    /// 「目を閉じている」の色（docs/wording-guide.md：墨紫。目を細めるの薄紫より濃く、赤・黄・緑は使わない）
    static let eyesClosedColor = Color(red: 0x5E / 255, green: 0x4B / 255, blue: 0x8B / 255)
    /// 「声が出た」の色（v1.7〜、docs/wording-guide.md：焦げ茶。声の大きさの灰茶より濃く、アンバー（いつもより上）とも違う）
    static let voiceOnColor = Color(red: 0x6B / 255, green: 0x4E / 255, blue: 0x3D / 255)

    /// 段・点の色（指標はその指標の色。目を閉じている・声が出たは、事実だけを塗る色）
    var color: Color {
        switch self {
        case .metric(let m): m.color
        case .eyesClosed: Self.eyesClosedColor
        case .voiceOn: Self.voiceOnColor
        }
    }

    /// 区間の塗りの色（指標は上＝アンバー・下＝青灰。事実の段はその色）
    func fill(above: Bool, amber: Color, slate: Color) -> Color {
        isFact ? color : above ? amber : slate
    }
}

/// 平均と標準偏差を1つずつ足しながら求める（Welford 法）
struct Welford: Codable, Equatable {
    private(set) var n = 0
    private(set) var mean = 0.0
    private(set) var m2 = 0.0

    /// ほかの集まりを足す（途中まで集めた声の普段を、次のセッションの分とまとめる。v1.7〜）
    func merged(_ o: Welford) -> Welford {
        guard o.n > 0 else { return self }
        guard n > 0 else { return o }
        var r = Welford()
        r.n = n + o.n
        let d = o.mean - mean
        r.mean = mean + d * Double(o.n) / Double(r.n)
        r.m2 = m2 + o.m2 + d * d * Double(n) * Double(o.n) / Double(r.n)
        return r
    }

    mutating func add(_ x: Double) {
        n += 1
        let d = x - mean
        mean += d / Double(n)
        m2 += d * (x - mean)
    }

    var std: Double { n > 1 ? (m2 / Double(n - 1)).squareRoot() : 0 }
}

/// 途中まで集めた声の普段（v1.7〜）：本人の声のコマの声の大きさ・高さを足し合わせたもの（値の数・平均・2乗の和）。
/// 声を出す回数が少ない人でも、セッションをまたいで続きから集める。集め始めてから 14日たったら捨てる（DiffCriteria.voiceBaselineMaxAgeDays）
struct VoicePartial: Codable, Equatable {
    var startedMs: Int64                 // 集め始めた日時（最初に本人の声を数えたセッション）
    var updatedMs: Int64
    var validS: Double                   // これまでに数えた本人の声の秒数
    var stats: [String: Welford]         // rms_db / f0_hz
    var sessions: Int                    // 本人の声を数えたセッションの数
    var days: [String]                   // 数えた日（yyyy-MM-dd、この端末の時刻）
    var f0Values: [Double]? = nil        // 数えた声の高さそのもの（v1.9.1〜。中央値・四分位範囲を求めるため。v1.9 までに途中まで集めたものには無い）

    enum CodingKeys: String, CodingKey {
        case startedMs = "started_ms", updatedMs = "updated_ms", validS = "valid_s", stats, sessions, days, f0Values = "f0_values"
    }

    func expired(now: Int64) -> Bool {
        Double(now - startedMs) / 86_400_000 >= DiffCriteria.voiceBaselineMaxAgeDays
    }
}
