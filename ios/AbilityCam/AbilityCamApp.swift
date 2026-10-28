import SwiftUI

@main
struct AbilityCamApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// 役割：撮る側（iPhone、胸に着ける）／見る側（iPad、Apple シリコンの Mac）。最初に選び、次からは覚えておく
enum Role: String, CaseIterable, Identifiable {
    case camera, viewer
    var id: String { rawValue }
    var title: String { self == .camera ? "撮る側" : "見る側" }
    var detail: String {
        self == .camera ? "iPhone を胸に着けて、表情と声を記録します"
                        : "iPad や Mac で、撮る側の顔の絵といつもとの違いをその場で見ます（何も保存しません）"
    }
}

struct RootView: View {
    @AppStorage("role") private var role = ""

    var body: some View {
        switch Role(rawValue: role) {
        case .camera: CameraShell()
        case .viewer: ViewerShell()
        case nil: RoleSelectView { role = $0.rawValue }
        }
    }
}

struct RoleSelectView: View {
    let choose: (Role) -> Void
    private var suggested: Role { UIDevice.current.userInterfaceIdiom == .phone ? .camera : .viewer }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("この端末の役割を選んでください").font(.title2.bold())
            Text("あとから設定で変えられます").foregroundStyle(.secondary)
            ForEach([suggested] + Role.allCases.filter { $0 != suggested }) { r in
                Button { choose(r) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.title).font(.title3.bold())
                        Text(r.detail).font(.callout).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .buttonStyle(.bordered)
                .tint(r == suggested ? .accentColor : .secondary)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 560)
    }
}

/// 設定：役割と、相手の画面に出るこの端末の名前
struct SettingsView: View {
    var link: CameraLink? = nil   // 撮る側のときだけ
    var inSidebar = false         // サイドバーの「設定」として出す（閉じるボタンは出さない）
    var openMenu: (() -> Void)? = nil
    @AppStorage("role") private var role = ""
    @AppStorage("deviceName") private var deviceName = ""
    @AppStorage("sendVideo") private var sendVideo = false
    @AppStorage("cameraLens") private var cameraLens = CameraLens.wide.rawValue
    @AppStorage("baselineSeconds") private var baselineSeconds = AnalysisModel.defaultBaselineSeconds
    @State private var allowed = AllowedViewers.all()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("役割", selection: $role) {
                        ForEach(Role.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("この端末の役割") } footer: {
                    Text("撮る側から見る側に変えると、今の記録を閉じて整理します")
                }
                Section {
                    TextField(UIDevice.current.name, text: $deviceName)
                } header: { Text("この端末の名前") } footer: {
                    Text("つないだ相手の画面に「〇〇が見ています」「〇〇に状態を送りますか？」のように出ます。次につなぐときから使われます")
                }
                if link != nil {
                    Section {
                        Picker("カメラ", selection: $cameraLens) {
                            ForEach(CameraLens.allCases) { l in
                                Text(l.available ? l.label : "\(l.label)（この端末にはありません）").tag(l.rawValue)
                                    .disabled(!l.available)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: { Text("カメラ") } footer: {
                        Text("初めは広角。超広角は広く映るので顔が画面から外れにくくなりますが、画角の端では顔が歪み、表情の数値が変わることがあります。前面は自分の顔で試すためのもので、胸に着けて使うのは背面です（前面でも左右は背面と同じ意味になるよう、反転せずに解析します。上の帯に「前面カメラ（試す用）」と出ます）。使ったカメラは記録の先頭に書きます。記録中に変えると、変えたことを記録して普段を取り直します。保存した普段は、同じカメラのときだけ使います")
                    }
                    Section {
                        Picker("普段の長さ", selection: $baselineSeconds) {
                            ForEach(AnalysisModel.baselineChoices, id: \.self) { Text("\($0)秒").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } header: { Text("普段の長さ") } footer: {
                        Text("初めは30秒。顔が映っていて横を向きすぎていない時間がこの秒数になったら、普段を記録し終えます。普段を記録している途中に変えると、今の記録にすぐ使います（数えた分はそのまま）。記録し終えたあとに変えると、次に普段を記録するとき（取り直す・次のセッション）から使います。使った長さは記録の baseline 行（target_s）に書きます。選んだ人に保存した普段があり、カメラが同じときは、開いてすぐその普段で比べ始め、今日の普段は画面に出さずにうしろで記録します")
                    }
                    PeopleSettingsSection()
                    Section {
                        Toggle("見る側に映像も送る", isOn: $sendVideo)
                    } footer: {
                        Text("初めはオフ。オンのあいだは、見ている端末に小さな映像（長い辺 480px、毎秒5コマまで）を送り、上の帯に「映像を送っています」と出ます。見る側は表示するだけで保存しません。解析のコマ/秒が落ちるときは、送るコマを減らします")
                    }
                    Section {
                        if allowed.isEmpty {
                            Text("ありません").foregroundStyle(.secondary)
                        }
                        ForEach(allowed) { v in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(v.name)
                                    Text("許可した日 \(Self.date(v.addedMs))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("取り消す") {
                                    AllowedViewers.remove(v.id)
                                    link?.disconnect(viewerID: v.id)
                                    allowed = AllowedViewers.all()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } header: { Text("許可した端末") } footer: {
                        Text("ここにある端末は、確認なしでつながります（つながると上の帯に「〇〇が見ています」と出ます）。取り消すと、つながっていれば切り、次は確認してからつなぎます")
                    }
                }
            }
            .navigationTitle("設定")
            .onAppear { allowed = AllowedViewers.all() }
            .toolbar {
                if inSidebar {
                    MenuToolbar(openMenu: openMenu)
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
                }
            }
        }
    }

    private static func date(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
