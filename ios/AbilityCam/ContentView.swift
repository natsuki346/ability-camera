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
    @AppStorage("cameraCorner") private var cornerRaw = Corner.topTrailing.rawValue   // 映像の小さな窓の場所（四隅、v1.14〜）
    @State private var drag: CGSize = .zero
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
                // v1.14〜：真ん中に状態のカード（いちばん大きく、画面の高さに合わせて縮む）。映像はカードの角の小さな窓。家族の印と場面は大きく
                NowCard(model: model, windowCorner: cameraCorner, windowReserve: Self.windowWidth + 12)
                    .overlay(alignment: cameraCorner.alignment) { cameraWindow.padding(8) }
                    .frame(maxHeight: .infinity)
                pastMarksLine
                marks
                if model.markDetailPrompt != nil { markDetailChips } else { scenes }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .overlay { if cameraLarge { largeCamera } }
        .overlay { if model.cueStage != nil { CueOverlay(model: model) } }   // 試すモードの指示（v1.18〜）
        .sheet(isPresented: $showSettings) { SettingsView(link: model.link, startCues: { showSettings = false; model.startCues() }) }
        .sheet(isPresented: Binding(get: { model.cueResult != nil }, set: { if !$0 { model.cueResult = nil } })) {
            if let r = model.cueResult { CueResultView(result: r) }
        }
        .alert("試すモード", isPresented: Binding(get: { model.cueError != nil }, set: { if !$0 { model.cueError = nil } })) {
            Button("閉じる", role: .cancel) { model.cueError = nil }
        } message: { Text(model.cueError ?? "") }
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

    private var cameraCorner: Corner { Corner(rawValue: cornerRaw) ?? .topTrailing }
    static let windowWidth: CGFloat = 100

    /// 映像の小さな窓（v1.14〜、Zoom の自分の映像のように）：カードの角に重ねる。網目つき。ドラッグで四隅に動かし、タップで大きく。
    /// 窓の下に小さなアイコン2つ：顔（読めている／読めない）、声（本人／本人以外／無し）
    private var cameraWindow: some View {
        VStack(spacing: 4) {
            // 1つのカメラに映像の層は1つだけにする（大きく出している間は、こちらは黒）
            Group { if cameraLarge { Color.black } else { CameraPreview(camera: model.camera, fill: true, lens: model.lensInUse) } }
                .overlay {
                    // 網目は解析の遅れの分だけ映像より遅れて見える（即時性そのものなので、隠さない）
                    if model.meshEnabled, let mesh = model.mesh, !cameraLarge { MeshOverlay(mesh: mesh, fill: true) }
                }
                .frame(width: Self.windowWidth, height: Self.windowWidth * 4 / 3)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            HStack(spacing: 6) {
                statusIcon(model.faceReadable && model.cameraActive ? "face.smiling" : "face.dashed",
                           color: Palette.face, dim: !(model.faceReadable && model.cameraActive))
                    .accessibilityLabel(model.faceReadable && model.cameraActive ? "顔：読めています" : "顔：読めません")
                statusIcon(model.otherVoice ? "person.2.wave.2" : "waveform", color: Palette.voice, dim: !model.otherVoice && !model.selfVoiceNow)
                    .accessibilityLabel(model.otherVoice ? "声：本人以外の声" : model.selfVoiceNow ? "声：本人" : "声：無し")
            }
        }
        .offset(drag)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { cameraLarge = true } }
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { drag = $0.translation }
            .onEnded { v in
                // 動かした向きで、いちばん近い角へ
                var c = cameraCorner
                if v.translation.width < -40 { c = c.withLeading(true) } else if v.translation.width > 40 { c = c.withLeading(false) }
                if v.translation.height > 40 { c = c.withTop(false) } else if v.translation.height < -40 { c = c.withTop(true) }
                withAnimation(.spring(duration: 0.25)) { cornerRaw = c.rawValue; drag = .zero }
            })
        .accessibilityElement(children: .contain)
        .accessibilityHint("タップで映像を大きく。ドラッグで四隅に動かす")
    }

    private func statusIcon(_ name: String, color: Color, dim: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color.opacity(dim ? 0.4 : 1))
            .frame(width: 28, height: 22)
            .background(.regularMaterial, in: Capsule())
    }

    /// 前に同じ組み合わせのとき、家族が付けた印（v1.13〜）：あれば、カードの下に1行小さく
    @ViewBuilder private var pastMarksLine: some View {
        let past = model.pastMarkSummaryNow()
        if !past.isEmpty {
            Text("前に同じ組み合わせのとき、家族が付けた印：" + past.map(\.text).joined(separator: "、"))
                .font(.caption).foregroundStyle(Palette.face).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    /// 家族の印（v1.14〜：画面幅いっぱいの3つ、高さ 80pt 以上、title 太字）。介助しながら片手で押せる大きさ
    private var marks: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.markMessage ?? "家族の印").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                ForEach(Mark.allCases) { m in
                    Button { model.tapMark(m) } label: {
                        Text(m.rawValue)
                            .font(.title.bold())
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(m == .pleasant ? .teal : m == .unpleasant ? .indigo : .gray)
                }
            }
            .disabled(!model.running)
        }
    }

    /// 家族の印を押したあとに10秒だけ出す「詳しく（任意）」（v1.13〜、快・不快のとき。v1.14〜：場面の場所に、折り返して大きく。押したら消える）。
    /// 押さなければ消え、記録はワンタップの分だけ
    @ViewBuilder private var markDetailChips: some View {
        if let p = model.markDetailPrompt {
            VStack(alignment: .leading, spacing: 4) {
                Text("詳しく（任意）：\(p.mark.rawValue)").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(p.options, id: \.self) { o in
                        Button { model.chooseMarkDetail(o) } label: {
                            Text(o).font(.body.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.7)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(Self.navy)
                                .background(Self.paleSlate, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("家族の印の詳しい中身（任意）")
        }
    }

    /// 場面（v1.14〜：横スクロールをやめて3列のグリッドで全部見える、高さ 52pt 以上）。同時に一つだけ、もう一度押すと「場面なし」
    private var scenes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("場面").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(CareScene.allCases) { s in
                    let on = model.scene == s
                    Button { model.tapScene(s) } label: {
                        Text(s.rawValue).font(.callout.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(on ? Color.white : Self.navy)
                            .background(on ? Self.navy : Self.paleSlate, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))   // ボタン全体で押せる
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .disabled(!model.running)
        .opacity(model.running ? 1 : 0.5)
        .sensoryFeedback(.selection, trigger: model.scene)   // 押したことが分かるように（v1.16〜）
    }
}

/// 映像の小さな窓の場所（四隅、v1.14〜）
enum Corner: String {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    func withTop(_ top: Bool) -> Corner { Corner(top: top, leading: isLeading) }
    func withLeading(_ leading: Bool) -> Corner { Corner(top: isTop, leading: leading) }
    init(top: Bool, leading: Bool) {
        self = top ? (leading ? .topLeading : .topTrailing) : (leading ? .bottomLeading : .bottomTrailing)
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

