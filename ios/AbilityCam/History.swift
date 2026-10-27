import SwiftUI
import UniformTypeIdentifiers

/// これまでの記録の1行：日時・長さ・顔が映っていた割合・違いが出た回数・家族の印の数
struct RecordRow: View {
    let started: Date
    let durationS: Double
    let faceRatio: Double?
    let diffs: Int
    let marks: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.date.string(from: started)).font(.body.weight(.semibold)).monospacedDigit()
            HStack(spacing: 12) {
                Text(ContentView.duration(durationS))
                Text("顔 \(faceRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")")
                Text("違い \(diffs)回")
                Text("家族の印 \(marks)")
            }
            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d（E） HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()
}

/// 撮る側：この端末の記録（sessions.jsonl の要約）。タップでリプレイ
struct CameraHistoryView: View {
    let sessions: [SessionSummary]
    let openMenu: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    Text("まだありません（アプリを閉じると、ここに足されます）").foregroundStyle(.secondary)
                }
                ForEach(sessions.prefix(200)) { s in
                    NavigationLink(value: s.file) {
                        RecordRow(started: Date(timeIntervalSince1970: Double(s.startedMs) / 1000), durationS: s.durationS,
                                  faceRatio: s.faceRatio, diffs: s.segments, marks: s.marks)
                    }
                }
                Section {
                } footer: {
                    Text("記録中のものは、アプリを閉じたあとに足されます。「違い」の回数は記録したときの決まりで数えたもので、v1.0 より前の記録は多めに出ます（リプレイでは今の決まりで数え直します）。記録のファイルは「ファイル」アプリ > このiPhone内 > Ability Cam にあります")
                }
            }
            .navigationTitle("これまでの記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { MenuToolbar(openMenu: openMenu) }
            .navigationDestination(for: String.self) { file in
                ReplayLoaderView(url: SessionStore.dir.appendingPathComponent(file))
            }
        }
    }
}

/// 見る側（Mac・iPad）：何も保存しないので、AirDrop で受け取った記録のファイルを「記録を開く」で開く。
/// 開いたものはこの端末のメモリにだけ置き、どこにも写さない（アプリを閉じたら一覧から消える）
struct OpenedRecordsView: View {
    @Binding var opened: [ReplayData]
    let openMenu: (() -> Void)?
    @State private var picking = false
    @State private var loading = 0
    @State private var errors: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { picking = true } label: { Label("記録を開く", systemImage: "folder") }
                    if loading > 0 {
                        HStack { ProgressView(); Text("記録を読んでいます…（\(loading)件）") }
                    }
                    ForEach(errors, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                } footer: {
                    Text("AirDrop で受け取った ability-cam-*.jsonl を選びます。開いた記録はこの端末に保存せず、どこにも写しません。アプリを閉じると一覧から消えます。見る側が自動でファイルを受け取ることはありません")
                }
                Section {
                    if opened.isEmpty {
                        Text("開いている記録はありません").foregroundStyle(.secondary)
                    }
                    ForEach(opened) { d in
                        NavigationLink(value: d.id) {
                            RecordRow(started: Date(timeIntervalSince1970: d.startT), durationS: d.durationS,
                                      faceRatio: d.faceRatio, diffs: d.diffCount, marks: d.markCount)
                        }
                    }
                    .onDelete { opened.remove(atOffsets: $0) }
                } header: { Text("開いている記録") }
            }
            .navigationTitle("これまでの記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { MenuToolbar(openMenu: openMenu) }
            .navigationDestination(for: UUID.self) { id in
                if let d = opened.first(where: { $0.id == id }) { ReplayView(data: d) }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .json, .plainText], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                errors = []
                for url in urls { load(url) }
            }
        }
    }

    private func load(_ url: URL) {
        loading += 1
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<ReplayData, Error> in
                // 選んだファイルをその場で読むだけ（写さない）
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return .success(try ReplayData(data: data, name: url.lastPathComponent))
                } catch {
                    return .failure(error)
                }
            }.value
            loading -= 1
            switch r {
            case .success(let d):
                opened.removeAll { $0.name == d.name }
                opened.append(d)
                opened.sort { $0.startT > $1.startT }
            case .failure(let e):
                errors.append("\(url.lastPathComponent)：\(e.localizedDescription)")
            }
        }
    }
}

/// 記録のファイルを読んでから、リプレイを出す
struct ReplayLoaderView: View {
    let url: URL
    @State private var data: ReplayData?
    @State private var error: String?

    var body: some View {
        Group {
            if let data {
                ReplayView(data: data)
            } else if let error {
                Text(error).foregroundStyle(.secondary).padding()
            } else {
                ProgressView("記録を読んでいます…")
            }
        }
        .task(id: url) {
            let url = url
            let r = await Task.detached(priority: .userInitiated) { () -> Result<ReplayData, Error> in
                do {
                    let d = try Data(contentsOf: url, options: .mappedIfSafe)
                    return .success(try ReplayData(data: d, name: url.lastPathComponent))
                } catch {
                    return .failure(error)
                }
            }.value
            switch r {
            case .success(let d): data = d
            case .failure(let e): error = "記録を読めませんでした：\(e.localizedDescription)"
            }
        }
    }
}
