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
        case .camera: ContentView()
        case .viewer: ViewerView()
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
    @AppStorage("role") private var role = ""
    @AppStorage("deviceName") private var deviceName = ""
    @AppStorage("sendVideo") private var sendVideo = false
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private static func date(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
