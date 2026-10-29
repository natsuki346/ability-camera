import SwiftUI

/// 撮る側を開いたときの最初の画面「だれを記録しますか」（v1.11.1〜）。
/// 介助する人に要るのは「正しい人で、すぐ始められる」「映り方を始める前に確かめられる」だけなので、それ以外は置かない。
/// - 映像は出さない（v1.11.2〜）。カメラと顔の検出は動かし、見出しの上に「顔が映っています／映っていません」だけ（アイコン付き）
/// - 前回記録した人を大きなボタン1つで、画面の真ん中寄りに。押すと軽い触覚を返して記録を始める
/// - ほかの人（横に並べる）と「＋ 人を足す」は小さく。カメラ（広角・超広角・前面）もここで小さく選ぶ（記録中は変えない、v1.11.2〜）
/// カメラは記録を始めても止めずに、記録中の画面で使い続ける（同じ AVCaptureSession。記録中の画面は今まで通り映像を出す）
struct PersonStartView: View {
    @ObservedObject var model: AnalysisModel
    @ObservedObject private var store = PersonStore.shared
    @State private var showSettings = false
    @State private var askName = false
    @State private var newName = ""
    @State private var started = 0          // 触覚を返すきっかけ
    @AppStorage("cameraLens") private var cameraLens = CameraLens.wide.rawValue

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    topBar
                    Spacer(minLength: 12)
                    faceLine
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
                    Spacer(minLength: 12)
                    lensPicker
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

    /// カメラ（広角・超広角・前面）：記録を始める前にだけ選ぶ（v1.11.2〜。記録中は設定でも変えない）
    private var lensPicker: some View {
        Menu {
            Picker("カメラ", selection: $cameraLens) {
                ForEach(CameraLens.allCases) { l in
                    Text(l.available ? l.label : "\(l.label)（この端末にはありません）").tag(l.rawValue)
                }
            }
        } label: {
            Label("カメラ：\((CameraLens(rawValue: cameraLens) ?? .wide).label)", systemImage: "camera")
                .font(.footnote)
                .frame(minHeight: 44)
        }
        .foregroundStyle(Palette.progress)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("カメラ：\((CameraLens(rawValue: cameraLens) ?? .wide).label)。変える")
    }

    @ViewBuilder private var faceLine: some View {
        if let note = model.startNote {
            Label(note, systemImage: "info.circle")
                .font(.callout).foregroundStyle(Palette.progress)
        } else if let found = model.previewFace {
            Label(found ? "顔が映っています" : "顔が映っていません", systemImage: found ? "face.smiling" : "face.dashed")
                .font(.headline.weight(found ? .regular : .semibold))
                .foregroundStyle(found ? Palette.face : Palette.progress)
                .animation(.easeInOut(duration: 0.2), value: found)
        } else {
            Label("カメラを準備しています", systemImage: "hourglass")
                .font(.headline.weight(.regular)).foregroundStyle(.secondary)
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
