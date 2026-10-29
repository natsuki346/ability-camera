import SwiftUI

/// 文字の色と使い分け（v1.10.5〜、docs/wording-guide.md の「文字の色」の表）。
/// 種類（表情の違い・目を閉じている・声・顔の向き・進み具合・記録の状態）ごとに色を分ける。赤・黄・緑の信号色は使わない。
/// 文字の色は、白の背景で 6.9:1 以上・黒の背景で 11:1 以上（ダークモードでは明るい色に替える）。
/// メーターの点の色（Metric.color）は文字には使わず、行の頭の小さな印にだけ使う（空色・アンバーは白の背景で文字にすると読みにくい）
enum Palette {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// 表情の違い・記録の状態（濃紺。今までの文字の色）
    static let face = ContentView.navyText
    /// 目を閉じている（墨紫）
    static let eyes = adaptive(light: 0x5E4B8B, dark: 0xC9BCE8)
    /// 声（声の違い・声が出た・本人以外の声・声の普段のばらつき）。焦げ茶（「声が出た」の色）
    static let voice = adaptive(light: 0x6B4E3D, dark: 0xE3CDB9)
    /// 顔の向き（藍）
    static let head = adaptive(light: 0x2F5D8A, dark: 0xA9C8E8)
    /// 進み具合と、その理由（普段・声の普段・声の登録）。青灰
    static let progress = adaptive(light: 0x4F5B6B, dark: 0xC2CAD4)

    /// 行の頭の印の色：メーター・グラフと同じ色。目を閉じている・声が出たは濃いので、ダークモードでは明るくする（黒の背景で 3:1 以上）
    static func marker(_ t: DiffTarget) -> Color {
        switch t {
        case .metric(let m): m.color
        case .eyesClosed: adaptive(light: 0x5E4B8B, dark: 0x9B87C9)
        case .voiceOn: adaptive(light: 0x6B4E3D, dark: 0xA8876F)
        }
    }

    /// 違いの種類ごとの文字の色
    static func text(_ t: DiffTarget) -> Color {
        switch t {
        case .metric(let m): m.isFace ? face : voice
        case .eyesClosed: eyes
        case .voiceOn: voice
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// いつもとの違い1行（大事なもの）：頭にメーターの点と同じ色の印、文字は種類の色で太く大きく
struct DiffLineView: View {
    let text: String
    let target: DiffTarget?
    var font: Font = .title3.bold()
    var markerSize: CGFloat = 10

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(target.map(Palette.marker) ?? Palette.face)
                .overlay(Circle().stroke(ContentView.navyText.opacity(0.35), lineWidth: 0.5))   // 空色・アンバーは白の上で薄いので縁取り
                .frame(width: markerSize, height: markerSize)
                .accessibilityHidden(true)
            Text(text).font(font).foregroundStyle(target.map(Palette.text) ?? Palette.face)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

/// 補足の1行（進み具合・理由・本人以外の声など）：小さなアイコンと、種類の色の小さい文字
struct NoteLine: View {
    let text: String
    let icon: String
    let color: Color
    var font: Font = .caption
    var lines = 1

    var body: some View {
        Label {
            Text(text).lineLimit(lines).minimumScaleFactor(0.7)
        } icon: {
            Image(systemName: icon).imageScale(.small)
        }
        .font(font)
        .foregroundStyle(color)
        .labelStyle(NoteLabelStyle())
    }
}

private struct NoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) { configuration.icon.frame(width: 14); configuration.title }
    }
}
