import AVFoundation
import SwiftUI

/// 撮る側の記録中の画面（v1.11.3〜）：上の切り替え（segmented）で「いま」と「データ」を選ぶ（前に開いていた方を覚える）。
/// いま＝直感（小さい映像・いつもと違うこと・家族の印・場面）、データ＝数字とグラフ（LivePages.swift）。
/// どちらを開いていても、記録・判定・見る側に送るものは同じ（表示だけの違い）。横スワイプのページ（いま／グラフ／数字）はやめた
struct ContentView: View {
    @ObservedObject var model: AnalysisModel
    var openMenu: (() -> Void)?            // サイドバーを開く（iPad のサイドバーがあるときは nil）
    @State private var cameraLarge = false
    @State private var showSettings = false
    @AppStorage("liveTab") private var tab = LiveTab.now.rawValue   // 前に開いていたタブ
    @State private var confirmEnd = false   // 「記録を終えますか？」（v1.11.2〜。記録中は人を変えない）
    @ObservedObject private var people = PersonStore.shared


    var body: some View {
        VStack(spacing: 8) {
            topBar   // 前面カメラの帯は出さない（カメラは最初の画面か設定で選ぶ、v1.11.2〜）
            Picker("表示", selection: $tab) {
                ForEach(LiveTab.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            ViewersBar(link: model.link)
            if tab == LiveTab.data.rawValue {
                DataTab(model: model)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    camera
                    NowSide(model: model)
                }
                NowDifferences(model: model)
                marks
                scenes
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .overlay { if cameraLarge { largeCamera } }
        .sheet(isPresented: $showSettings) { SettingsView(link: model.link) }
        .confirmationDialog("記録を終えますか？", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("記録を終える") { model.endRecording() }
            Button("続ける", role: .cancel) {}
        } message: {
            Text("記録を閉じて、最初の画面（だれを記録しますか）に戻ります")
        }
        // 「普段を取り直す」などで画面に出して取った今日の普段を、取り終えたとき（保存した普段がある人だけ）
        .alert("この普段で保存し直しますか？", isPresented: Binding(get: { model.askResave }, set: { if !$0 { model.askResave = false } })) {
            Button("保存し直す") { model.overwriteSaved() }
            Button("保存しない", role: .cancel) { model.askResave = false }
        } message: {
            Text("\(people.selected?.displayName ?? "")の保存した普段を、今取った普段に置き換えます。次からは、この普段ですぐ比べ始めます")
        }
    }

    /// 上：左に ≡、真ん中に「記録中 12分34秒」、右に歯車
    private var topBar: some View {
        ZStack {
            recordingBanner
            HStack {
                if let openMenu {
                    Button(action: openMenu) { Image(systemName: "line.3.horizontal").font(.title3).padding(10) }
                        .accessibilityLabel("メニュー")
                }
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape").font(.title3).padding(10) }
                    .accessibilityLabel("設定")
            }
        }
        .foregroundStyle(Self.navyText)
    }

    /// いつも出す：記録中かどうかと経過時間。下に小さく記録している人。押すと「記録を終えますか？」だけ（v1.11.2〜。人は変えない）
    private var recordingBanner: some View {
        Button { if model.running { confirmEnd = true } } label: {
            VStack(spacing: 1) {
                Group {
                    if model.running, let since = model.sessionStartedAt {
                        TimelineView(.periodic(from: since, by: 1)) { ctx in
                            Label("記録中 \(Self.duration(ctx.date.timeIntervalSince(since)))", systemImage: "record.circle")
                                .monospacedDigit()
                        }
                    } else {
                        Label("記録の準備中…", systemImage: "hourglass")
                    }
                }
                .font(.callout.bold())
                Text(people.selected?.displayName ?? "人を選んでいません")
                    .font(.caption2)
            }
            .foregroundStyle(Self.navy)
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Self.paleSlate, in: Capsule())   // 薄い青灰
        }
        .buttonStyle(.plain)
        .accessibilityHint("押すと、記録を終えるかを確かめます")
    }

    static let navy = Color(red: 0x1F / 255, green: 0x3A / 255, blue: 0x5F / 255)   // 濃紺
    static let paleSlate = Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255)   // 薄い青灰
    /// 文字の濃紺。ダークモードでは読めないので、明るい青灰にする（ライトモードは濃紺のまま）
    static let navyText = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(paleSlate) : UIColor(navy) })

    static func duration(_ s: Double) -> String {
        let n = Int(s.rounded())
        if n >= 3600 { return "\(n / 3600)時間\(String(format: "%02d", n / 60 % 60))分" }
        return n >= 60 ? "\(n / 60)分\(String(format: "%02d", n % 60))秒" : "\(n)秒"
    }

    static func dateText(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// 小さいカメラ映像（網目つき）。タップで大きく
    private var camera: some View {
        // 1つのカメラに映像の層は1つだけにする（大きく出している間は、こちらは黒）
        Group { if cameraLarge { Color.black } else { CameraPreview(camera: model.camera, fill: true, lens: model.lensInUse) } }
            .overlay {
                // 網目は解析の遅れの分だけ映像より遅れて見える（即時性そのものなので、隠さない）
                if model.meshEnabled, let mesh = model.mesh, !cameraLarge { MeshOverlay(mesh: mesh, fill: true) }
            }
            .overlay(alignment: .topLeading) { cameraBadges.padding(5) }
            .aspectRatio(3 / 4, contentMode: .fit)
            .containerRelativeFrame(.horizontal) { w, _ in w * 0.48 }   // 画面幅の半分くらい（左上）
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { cameraLarge = true } }
            .accessibilityLabel("カメラ映像（タップで大きく）")
    }

    /// 映像の上に小さく：「顔：読めています」「声：本人／本人以外の声」（v1.11.3〜）
    private var cameraBadges: some View {
        VStack(alignment: .leading, spacing: 3) {
            badge(!model.cameraActive ? "顔：–" : model.faceReadable ? "顔：読めています" : "顔：読めません",
                  icon: model.faceReadable ? "face.smiling" : "face.dashed", color: Palette.face)
            badge(model.otherVoice ? "声：本人以外の声" : model.selfVoiceNow ? "声：本人" : "声：–",
                  icon: "waveform", color: Palette.voice, strong: model.otherVoice)
        }
    }

    private func badge(_ text: String, icon: String, color: Color, strong: Bool = false) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(strong ? .bold : .semibold))
            .foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
    }

    /// 大きいカメラ映像。もう一度タップで戻る
    private var largeCamera: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            CameraPreview(camera: model.camera, fill: false, lens: model.lensInUse)
                .overlay { if model.meshEnabled, let mesh = model.mesh { MeshOverlay(mesh: mesh, fill: false) } }
                .ignoresSafeArea(edges: .bottom)
            Button { model.meshEnabled.toggle() } label: {
                Label("網目", systemImage: model.meshEnabled ? "circle.grid.cross.fill" : "circle.grid.cross").font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(model.meshEnabled ? .white : .gray)
            .padding(12)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { cameraLarge = false } }
        .transition(.opacity)
    }

    /// 家族の印。介助しながら片手で押せる大きさ
    private var marks: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.markMessage ?? "家族の印").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                ForEach(Mark.allCases) { m in
                    Button { model.tapMark(m) } label: {
                        Text(m.rawValue)
                            .font(.title2.bold())
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(m == .pleasant ? .teal : m == .unpleasant ? .indigo : .gray)
                }
            }
            .disabled(!model.running)
        }
    }

    /// 場面。1行のチップ（横にスクロール）。同時に一つだけ、もう一度押すと「場面なし」
    private var scenes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("場面").font(.caption).foregroundStyle(.secondary)
                ForEach(CareScene.allCases) { s in
                    let on = model.scene == s
                    Button { model.tapScene(s) } label: {
                        Text(s.rawValue).font(.callout).lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .foregroundStyle(on ? Color.white : Self.navy)
                            .background(on ? Self.navy : Self.paleSlate, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .disabled(!model.running)
        .opacity(model.running ? 1 : 0.5)
    }
}

/// 記録中の画面のタブ（v1.11.3〜）
enum LiveTab: String, CaseIterable, Identifiable {
    case now, data
    var id: String { rawValue }
    var title: String { self == .now ? "いま" : "データ" }
}

/// 見ている端末（だれが見ているか）と、見たいという申し込みの確認
struct ViewersBar: View {
    @ObservedObject var link: CameraLink
    @AppStorage("sendVideo") private var sendVideo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sendVideo {   // オンのあいだは必ず出す
                Label(link.viewers.isEmpty ? "映像を送る設定です（今は見ている端末がありません）" : "映像を送っています",
                      systemImage: "video")
                    .font(.callout.bold())
                    .foregroundStyle(ContentView.navy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(link.viewers, id: \.self) { p in
                HStack {
                    Label("\(p.displayName)が見ています", systemImage: "ipad.and.iphone")
                    Spacer()
                    Button("切る") { link.disconnect(p) }
                        .buttonStyle(.bordered)
                        .tint(Color(red: 0x6B / 255, green: 0x7A / 255, blue: 0x8C / 255))   // 青灰（赤は使わない）
                }
                .font(.callout)
                .foregroundStyle(ContentView.navy)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .alert(link.requests.first.map { "\($0.peer.displayName)に状態を送りますか？" } ?? "",
               isPresented: Binding(get: { !link.requests.isEmpty }, set: { _ in })) {
            if let r = link.requests.first {
                Button("送る") { link.answer(r, send: true) }
                Button("送らない", role: .cancel) { link.answer(r, send: false) }
            }
        } message: {
            Text("記録している人の名前・顔の絵を動かす数値・顔の向き・いつもとの違い・記録の状態・家族の印と場面を、その場で送ります。音声・記録のファイルは送りません（映像は設定でオンにしたときだけ）。「送る」を選ぶと、この端末を覚えて次からは確認なしでつなぎます（設定で取り消せます）。")
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager
    var fill = false   // true: 枠いっぱいに（はみ出す分は切る）
    var lens: CameraLens?   // 変わったら、プレビューの向きと鏡をもう一度合わせる

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.camera = camera
        v.previewLayer.session = camera.session
        v.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        uiView.match()
    }

    /// プレビューの回転と鏡を、解析に渡す映像と同じにする（網目が顔に重なるように、v1.6.1〜）
    final class PreviewView: UIView {
        weak var camera: CameraManager?
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        func match() { camera?.matchPreview(previewLayer) }
        override func layoutSubviews() { super.layoutSubviews(); match() }
    }
}

