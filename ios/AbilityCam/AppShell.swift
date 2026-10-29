import SwiftUI

/// サイドバーの項目
enum SidebarPage: String, Hashable, Identifiable {
    case now, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "いま"
        case .history: "これまでの記録"
        case .settings: "設定"
        }
    }

    var icon: String {
        switch self {
        case .now: "dot.radiowaves.left.and.right"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// iPhone（幅が狭いとき）は左から出る引き出し、iPad・Mac（幅が広いとき）は NavigationSplitView のサイドバー。
/// content には、引き出しを開く操作を渡す（サイドバーが見えているときは nil）
struct SidebarShell<Content: View>: View {
    let pages: [SidebarPage]
    @Binding var page: SidebarPage
    @ViewBuilder let content: (SidebarPage, (() -> Void)?) -> Content
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var drawer = false

    static var drawerWidth: CGFloat { 280 }

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(pages, selection: Binding<SidebarPage?>(get: { page }, set: { if let p = $0 { page = p } })) { p in
                    Label(p.title, systemImage: p.icon).tag(p)
                }
                .navigationTitle("Ability Cam")
            } detail: {
                content(page, nil)
            }
        } else {
            ZStack(alignment: .leading) {
                content(page) { withAnimation(.easeOut(duration: 0.2)) { drawer = true } }
                if drawer {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                        .accessibilityLabel("メニューを閉じる")
                    drawerPanel
                        .transition(.move(edge: .leading))
                }
            }
        }
    }

    private var drawerPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ability Cam").font(.headline).padding(.horizontal, 16).padding(.vertical, 12)
            ForEach(pages) { p in
                Button {
                    page = p
                    close()
                } label: {
                    Label(p.title, systemImage: p.icon)
                        .font(.body.weight(page == p ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(page == p ? ContentView.paleSlate : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ContentView.navy)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: Self.drawerWidth)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .shadow(color: .black.opacity(0.15), radius: 8, x: 2)
        .gesture(DragGesture().onEnded { if $0.translation.width < -40 { close() } })
    }

    private func close() { withAnimation(.easeOut(duration: 0.2)) { drawer = false } }
}

/// 「いま」以外の画面の枠：題と、引き出しを開く ≡
struct PageFrame<Content: View>: View {
    let title: String
    let openMenu: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { MenuToolbar(openMenu: openMenu) }
        }
    }
}

struct MenuToolbar: ToolbarContent {
    let openMenu: (() -> Void)?
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let openMenu {
                Button(action: openMenu) { Image(systemName: "line.3.horizontal") }
                    .accessibilityLabel("メニュー")
            }
        }
    }
}

/// 撮る側：記録は「いま」の画面がどこにあっても続ける（開いている間は記録する）
struct CameraShell: View {
    @StateObject private var model = AnalysisModel()
    @ObservedObject private var people = PersonStore.shared
    @State private var page = SidebarPage.now
    @AppStorage("cameraLens") private var cameraLens = CameraLens.wide.rawValue
    @AppStorage("baselineSeconds") private var baselineSeconds = AnalysisModel.defaultBaselineSeconds
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SidebarShell(pages: [.now, .history, .settings], page: $page) { p, menu in
            switch p {
            case .now:
                // 開いたら、人を選んでから記録を始める（v1.11〜）
                if people.awaitingPerson && !model.running {
                    PersonStartView(openMenu: menu, note: model.startNote)
                } else {
                    ContentView(model: model, openMenu: menu)
                }
            case .history: CameraHistoryView(sessions: model.sessions, openMenu: menu)
            case .settings: SettingsView(link: model.link, inSidebar: true, openMenu: menu)
            }
        }
        .onChange(of: cameraLens) { model.applyLens() }   // 設定で広角／超広角を変えた
        .onChange(of: baselineSeconds) { model.applyBaselineLength() }   // 設定で普段の長さを変えた
        .onDisappear { model.shutdown() }   // 役割を「見る側」に変えた
        // アプリが終わる（上にスワイプして閉じた・裏で時間が尽きた）ときも、記録を閉じて要約する（v1.10.3〜。登録の途中の final の行も書く）
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in model.shutdown() }
        // 話者の区別のモデルを、アプリを開いたときに1回だけ読み込む（v1.10.3〜。設定がオンのときだけ）
        .onAppear { if UserDefaults.standard.bool(forKey: "speakerRecord") { SpeakerModelStore.shared.preload() } }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: Task { await model.appBecameActive() }   // 開いたら記録（新しいセッション、5秒以内なら同じセッション）
            case .background: model.appEnteredBackground()          // 裏に回ったら止めて、整理する
            default: break
            }
        }
    }
}

/// 見る側：つながりは「いま」以外の画面にしても切らない。開いた記録はメモリにだけ置く（アプリを閉じたら消える）
struct ViewerShell: View {
    @StateObject private var link = ViewerLink()
    @State private var page = SidebarPage.now
    @State private var opened: [ReplayData] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SidebarShell(pages: [.now, .history, .settings], page: $page) { p, menu in
            switch p {
            case .now: ViewerView(link: link, openMenu: menu)
            case .history: OpenedRecordsView(opened: $opened, openMenu: menu)
            case .settings: SettingsView(inSidebar: true, openMenu: menu)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: link.start()       // 起動したら自動で探してつなぐ
            case .background: link.stop()
            default: break
            }
        }
        .onDisappear { link.stop() }
    }
}
