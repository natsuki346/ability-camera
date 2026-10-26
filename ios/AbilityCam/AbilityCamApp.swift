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
    @AppStorage("role") private var role = ""
    @AppStorage("deviceName") private var deviceName = ""
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
            }
            .navigationTitle("設定")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
