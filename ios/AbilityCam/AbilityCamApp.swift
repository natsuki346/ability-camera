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
    var startCues: (() -> Void)? = nil   // 試すモードを始める（v1.18〜、撮る側だけ）
    @AppStorage("role") private var role = ""
    @AppStorage("deviceName") private var deviceName = ""
    @AppStorage("sendVideo") private var sendVideo = false
    @AppStorage("speakerRecord") private var speakerRecord = false   // 話者の区別を記録する（v1.10〜、初めはオフ）
    @AppStorage("cameraLens") private var cameraLens = CameraLens.wide.rawValue
    @AppStorage("baselineSeconds") private var baselineSeconds = AnalysisModel.defaultBaselineSeconds
    @State private var allowed = AllowedViewers.all()
    @ObservedObject private var people = PersonStore.shared
    @AppStorage(SpeakerSettings.qosKey) private var speakerQoS = "utility"                       // 確かめる用（v1.10.3〜）
    @AppStorage(SpeakerSettings.unitsKey) private var speakerUnits = "cpuAndNeuralEngine"
    @State private var speakerDevOpen = false
    @State private var pendingLens: CameraLens?   // 記録中に選んだカメラ（確かめてから、閉じて新しく始める。v1.11.3〜）
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
                        // 記録中に変えたときは「いまの記録を閉じて、新しく始めますか？」（v1.11.3〜。1本の記録には1つのカメラ）
                        Picker("カメラ", selection: Binding(get: { cameraLens }, set: { v in
                            if people.inSession, v != cameraLens { pendingLens = CameraLens(rawValue: v) } else { cameraLens = v }
                        })) {
                            ForEach(CameraLens.allCases) { l in
                                Text(l.available ? l.label : "\(l.label)（この端末にはありません）").tag(l.rawValue)
                                    .disabled(!l.available)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: { Text("カメラ") } footer: {
                        Text("最初の画面（だれを記録しますか）の下の「カメラ」か、ここで選びます。記録中に変えると、いまの記録を閉じて、新しい記録を始めます（確かめてから）。初めは広角。超広角は広く映るので顔が画面から外れにくくなりますが、画角の端では顔が歪み、表情の数値が変わることがあります。前面は自分の顔で試すためのもので、胸に着けて使うのは背面です（前面でも左右は背面と同じ意味になるよう、反転せずに解析します）。使ったカメラは記録の先頭に書きます。保存した普段は、同じカメラのときだけ使います")
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
                        Toggle("話者の区別を記録する", isOn: $speakerRecord)
                            .onChange(of: speakerRecord) { _, on in if on { SpeakerModelStore.shared.preload() } }
                        // 確かめる用の設定（v1.10.3〜。初めは閉じている。起動引数 -speakerQoS / -speakerComputeUnits でも変えられる）
                        DisclosureGroup("確かめる用の設定", isExpanded: $speakerDevOpen) {
                            Picker("計算の優先度", selection: $speakerQoS) {
                                ForEach(SpeakerSettings.qosChoices, id: \.self) { Text($0).tag($0) }
                            }
                            Picker("計算の場所（computeUnits）", selection: $speakerUnits) {
                                ForEach(SpeakerSettings.unitsChoices, id: \.self) { Text($0).tag($0) }
                            }
                            .onChange(of: speakerUnits) { _, _ in if speakerRecord { SpeakerModelStore.shared.preload() } }
                            Text("話者の区別の計算の速さを比べるためのもの。次の記録から使い、記録のヘッダ（speaker_qos・speaker_compute_units）に書きます。初めは utility・cpuAndNeuralEngine")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            // 記録中に切り替えても、今の記録には効かない（v1.10.2〜。オンにしたつもりの記録がオフだったため）
                            if let now = people.speakerInSession {
                                Text("切り替えは次の記録から効きます。今の記録は\(now ? "オン" : "オフ")のままです")
                                    .font(.caption.bold()).foregroundStyle(now == speakerRecord ? .secondary : ContentView.navyText)
                            } else {
                                Text("切り替えは次の記録から効きます").font(.caption.bold())
                            }
                            Text("初めはオフ。オンのあいだは、声が出ている間（声の高さが取れている、または声の大きさが -52dB 以上）0.5秒ごとに声の特徴を数値にし、設定の「人」で声を登録した人ごとの似ている度合いを記録に書きます（type: \"speaker\" の行）。画面には出しません。声の特徴の数値はこの端末の persons.json の中だけで、記録にも見る側にも送りません。本人確認・認証には使いません。次に記録を始めたときから使います")
                        }
                    }
                    if let startCues {
                        Section {
                            DisclosureGroup("確かめる用：試すモード") {
                                Button("試すモードを始める") { startCues() }
                                    .disabled(!people.inSession)
                                Text("自分の顔で、指示どおりに動かして「いつもとの違い」が出るかを確かめるもの（約\(Int((CuePlan.totalS / 60).rounded()))分と、始める前に普段を取り直す時間）。始めると「普段を取り直す（表情だけ）」をしてから、画面に大きく指示を出します：何もしない・眉を寄せる×5・笑う×5・顔を横に向ける・何もしない・いちばん強く眉を寄せる・いちばん大きく笑う。指示ごとに記録へ書き（event kind: cue）、終わったら結果を出し、その人の動く幅を保存します。記録中だけ使えます")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
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
            .alert(PersonStore.restartQuestion, isPresented: Binding(get: { pendingLens != nil }, set: { if !$0 { pendingLens = nil } })) {
                Button("はい") {
                    if let l = pendingLens { people.restartRecording(lens: l) }
                    pendingLens = nil
                }
                Button("いいえ", role: .cancel) { pendingLens = nil }
            } message: {
                Text(PersonStore.restartMessage("\(pendingLens?.label ?? "")のカメラ"))
            }
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
