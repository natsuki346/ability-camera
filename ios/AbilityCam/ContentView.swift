import AVFoundation
import SwiftUI

/// 撮る側の「いま」：スクロールなしの1画面。小さい iPhone（SE の高さ）でも家族の印のボタンまで見える。
/// 真ん中は横にスワイプして「いま」「グラフ」「数字」を切り替える（LivePages.swift）
struct ContentView: View {
    @ObservedObject var model: AnalysisModel
    var openMenu: (() -> Void)?            // サイドバーを開く（iPad のサイドバーがあるときは nil）
    @State private var cameraLarge = false
    @State private var showSettings = false
    @State private var middlePage = 0
    @State private var showPeople = false
    @ObservedObject private var people = PersonStore.shared
    @AppStorage("sketchTone") private var sketchTone = SketchTone.medium

    static let sketchSize: CGFloat = 140
    static let dotsHeight: CGFloat = 26   // ページの点の分（中身と重ならないように）

    var body: some View {
        VStack(spacing: 8) {
            topBar
            if model.lensInUse == .front {   // 前面は自分で試す用（v1.5〜）
                Label("前面カメラ（試す用）", systemImage: "camera.rotate")
                    .font(.caption).foregroundStyle(Self.navy)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Self.paleSlate, in: Capsule())
            }
            ViewersBar(link: model.link)
            HStack(alignment: .top, spacing: 12) {
                faceSketch
                camera
            }
            middle
            marks
            scenes
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .overlay { if cameraLarge { largeCamera } }
        .sheet(isPresented: $showSettings) { SettingsView(link: model.link) }
        .sheet(isPresented: $showPeople) { PersonPickerView() }
        .onChange(of: people.selectedID) { model.personChanged() }
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

    /// いつも出す：記録中かどうかと経過時間。下に小さく選んでいる人（タップで変える）
    private var recordingBanner: some View {
        Button { showPeople = true } label: {
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
                Text("\(people.selected?.displayName ?? "人を選んでいません") ▾")
                    .font(.caption2)
            }
            .foregroundStyle(Self.navy)
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Self.paleSlate, in: Capsule())   // 薄い青灰
        }
        .buttonStyle(.plain)
        .accessibilityHint("タップで人を選ぶ")
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

    /// 真ん中：横にスワイプして切り替えるページ（下にページの点）。グラフのページでは、グラフの外でスワイプする
    private var middle: some View {
        TabView(selection: $middlePage) {
            NowPage(model: model).padding(.bottom, Self.dotsHeight).tag(0)
            GraphPage(graph: model.graph).padding(.bottom, Self.dotsHeight).tag(1)
            NumbersPage(model: model).padding(.bottom, Self.dotsHeight).tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .padding(.bottom, 2)
        .frame(maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    /// 小さいカメラ映像（網目つき）。タップで大きく
    private var camera: some View {
        // 1つのカメラに映像の層は1つだけにする（大きく出している間は、こちらは黒）
        Group { if cameraLarge { Color.black } else { CameraPreview(session: model.camera.session, fill: true, lens: model.lensInUse) } }
            .overlay {
                // 網目は解析の遅れの分だけ映像より遅れて見える（即時性そのものなので、隠さない）
                if model.meshEnabled, let mesh = model.mesh, !cameraLarge { MeshOverlay(mesh: mesh, fill: true) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.sketchSize * 4 / 3 * 0.9)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { cameraLarge = true } }
            .accessibilityLabel("カメラ映像（タップで大きく）")
    }

    /// 大きいカメラ映像。もう一度タップで戻る
    private var largeCamera: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            CameraPreview(session: model.camera.session, fill: false, lens: model.lensInUse)
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

    /// 動きを写す顔の絵（映像と同じ見え方・同じ向き）。読めないときは灰色で中立
    private var faceSketch: some View {
        let shape = model.cameraActive ? model.faceShape : nil
        let sketch = FaceSketch(shape: shape, size: Self.sketchSize, tone: sketchTone)
        return VStack(spacing: 2) {
            sketch
                .contextMenu {   // 長押しで絵の色を選ぶ
                    Picker("絵の色", selection: $sketchTone) {
                        ForEach(SketchTone.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            Group {
                if !model.cameraActive {
                    Text(" ")
                } else if let shape {
                    Text(sketch.turnedAway ? "横向き：表情は参考程度"
                         : shape["yaw"] != nil ? "顔の向き：\(FaceSketch.directionText(shape))" : " ")
                } else {
                    Text("読めません").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(width: Self.sketchSize)
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
            Text("顔の絵を動かす数値・顔の向き・いつもとの違い・記録の状態・家族の印と場面を、その場で送ります。音声・記録のファイルは送りません（映像は設定でオンにしたときだけ）。「送る」を選ぶと、この端末を覚えて次からは確認なしでつなぎます（設定で取り消せます）。")
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var fill = false   // true: 枠いっぱいに（はみ出す分は切る）
    var lens: CameraLens?   // 変わったら、プレビューの左右反転をもう一度切る

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        uiView.unmirror()
    }

    /// プレビューも、解析と同じく左右反転しない（前面カメラで、網目が映像と左右逆にならないように）
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        func unmirror() { if let c = previewLayer.connection { CameraManager.unmirror(c) } }
        override func layoutSubviews() { super.layoutSubviews(); unmirror() }
    }
}

