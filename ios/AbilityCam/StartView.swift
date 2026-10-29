import SwiftUI

/// 撮る側を開いたときの最初の画面「だれを記録しますか」（v1.11.1〜）。
/// 介助する人に要るのは「正しい人で、すぐ始められる」「映り方を始める前に確かめられる」だけなので、それ以外は置かない。
/// - 上：カメラの映像（保存も送信もしない。網目は出さない）と、その下に「顔が映っています／映っていません」
/// - 前回記録した人を大きなボタン1つで。押すと軽い触覚を返して記録を始める
/// - ほかの人（横に並べる）と「＋ 人を足す」は小さく
/// 映像は記録を始めてもカメラを止めずに、記録中の画面に引き継ぐ（同じ AVCaptureSession）
struct PersonStartView: View {
    @ObservedObject var model: AnalysisModel
    @ObservedObject private var store = PersonStore.shared
    @State private var showSettings = false
    @State private var askName = false
    @State private var newName = ""
    @State private var started = 0          // 触覚を返すきっかけ

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    topBar
                    camera(height: max(160, geo.size.height / 3))
                    Text("だれを記録しますか")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let last = lastPerson {
                        mainButton(last)
                        others
                    } else {
                        addButton(large: true)
                    }
                    Spacer(minLength: 8)
                    Label("映像と音声は保存しません", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
        .background(Color(.systemBackground))
        .sensoryFeedback(.impact(weight: .light), trigger: started)
        .sheet(isPresented: $showSettings) { SettingsView(link: model.link) }
        .alert("人を足す", isPresented: $askName) {
            TextField("名前（例 姉）", text: $newName)
            Button("足して記録する") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                guard !n.isEmpty else { return }
                start(store.add(name: n).id)
            }
            Button("やめる", role: .cancel) { newName = "" }
        } message: {
            Text("名前はこの端末の中にだけ保存します（記録のファイルには書きません）")
        }
    }

    /// 前回記録した人（いなければ、いちばん上の人）
    private var lastPerson: Person? { store.chooseOrder.first }

    /// 右上の設定だけ
    private var topBar: some View {
        HStack {
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .foregroundStyle(Palette.progress)
            .accessibilityLabel("設定")
        }
    }

    /// カメラの映像（角丸、画面幅いっぱい）と、顔が映っているかの一言
    private func camera(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                #if DEBUG
                if AnalysisModel.uiPreviewStart {
                    PreviewStandIn()   // シミュレーターにはカメラが無いので、スクリーンショット用の代わり
                } else {
                    CameraPreview(camera: model.camera, fill: true, lens: model.lensInUse)
                }
                #else
                CameraPreview(camera: model.camera, fill: true, lens: model.lensInUse)
                #endif
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)
            faceLine
        }
    }

    @ViewBuilder private var faceLine: some View {
        if let note = model.startNote {
            Label(note, systemImage: "info.circle")
                .font(.footnote).foregroundStyle(Palette.progress)
        } else if let found = model.previewFace {
            Label(found ? "顔が映っています" : "顔が映っていません", systemImage: found ? "face.smiling" : "face.dashed")
                .font(.footnote.weight(found ? .regular : .semibold))
                .foregroundStyle(found ? Palette.face : Palette.progress)
                .animation(.easeInOut(duration: 0.2), value: found)
        } else {
            Label("カメラを準備しています", systemImage: "hourglass")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// 前回記録した人：大きなボタン1つ
    private func mainButton(_ p: Person) -> some View {
        Button { start(p.id) } label: {
            VStack(spacing: 4) {
                Text(p.displayName)
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
                Text("押すと記録を始めます")
                    .font(.subheadline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 112)
            .padding(.vertical, 8)
            .background(ContentView.navy, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p.displayName)。記録を始める")
    }

    /// ほかの人（横に並べる）と「＋ 人を足す」
    private var others: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.chooseOrder.dropFirst()) { p in
                    Button { start(p.id) } label: {
                        Text(p.displayName)
                            .font(.body)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(Palette.face)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(p.displayName)。記録を始める")
                }
                addButton(large: false)
            }
        }
    }

    private func addButton(large: Bool) -> some View {
        Button { askName = true } label: {
            Label("人を足す", systemImage: "plus")
                .font(large ? .title2.bold() : .body)
                .padding(.horizontal, 16)
                .frame(maxWidth: large ? .infinity : nil, minHeight: large ? 112 : 44)
                .foregroundStyle(large ? Color.white : Palette.face)
                .background(large ? AnyShapeStyle(ContentView.navy) : AnyShapeStyle(Color(.secondarySystemBackground)),
                            in: RoundedRectangle(cornerRadius: large ? 20 : 22, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("人を足す")
    }

    private func start(_ id: String) {
        started += 1
        #if DEBUG
        if AnalysisModel.uiPreviewStart { return }
        #endif
        _ = store.choose(id)   // 記録していないので、そのまま始まる
    }
}

#if DEBUG
/// スクリーンショット用：映像の代わりに灰色の地と顔の絵
private struct PreviewStandIn: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.18)], startPoint: .top, endPoint: .bottom)
            FaceSketch(shape: ["yaw": 4, "pitch": -2, "roll": 1], size: 120, tone: .medium)
        }
    }
}
#endif
