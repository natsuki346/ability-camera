import Foundation
import SwiftUI

/// 顔の枠（中心 x・y と幅、0〜1）の平均と標準偏差。普段を記録している間の本人の顔の位置と大きさ（v1.2〜）
struct FaceBoxStats: Codable, Equatable {
    struct S: Codable, Equatable { let n: Int; let mean: Double; let std: Double }
    let cx: S
    let cy: S
    let w: S
}

/// 保存した普段：数値だけ。映像・顔の点の座標・顔の形は保存しない（顔認証はしない）
struct SavedBaseline: Codable, Equatable {
    let metrics: [String: BaselineRecord.Stat]   // 指標ごとの n・平均・標準偏差・insufficient
    let camera: String                           // wide / ultra_wide
    let targetS: Double                          // 普段の長さ
    let savedMs: Int64                           // 保存した日時
    var faceBox: FaceBoxStats?
    var voice: SavedVoice?                       // 声の普段（v1.6〜。それより前に保存したものには無い）

    var savedDate: Date { Date(timeIntervalSince1970: Double(savedMs) / 1000) }
}

/// 保存した声の普段（v1.6〜）：本人の声のコマだけで集めた声の大きさ・高さ
struct SavedVoice: Codable, Equatable {
    let metrics: [String: BaselineRecord.Stat]   // rms_db / f0_hz
    let validS: Double                           // 数えた本人の声の秒数
    let savedMs: Int64
}

/// 人：名前だけ。この端末の中にだけ保存し、外には送らない（見る側にも、記録にも名前は書かない。記録には id だけ）
struct Person: Codable, Identifiable, Equatable {
    let id: String                               // ランダムな id
    var name: String
    var saved: SavedBaseline?

    /// 画面に出す名前（v1.3 から「さん」を付けない：「自分」「姉」）
    var displayName: String { name }
}

/// 人の一覧。Application Support の persons.json（「ファイル」アプリには出ない場所）に置く
@MainActor
final class PersonStore: ObservableObject {
    static let shared = PersonStore()

    @Published private(set) var people: [Person] = []
    @Published var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "personID") }
    }

    var selected: Person? { people.first { $0.id == selectedID } }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("persons.json")
    }

    private init() {
        if let d = try? Data(contentsOf: Self.url), let list = try? JSONDecoder().decode([Person].self, from: d) {
            people = list
        }
        let id = UserDefaults.standard.string(forKey: "personID")
        selectedID = people.contains { $0.id == id } ? id : nil
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(people) else { return }
        try? d.write(to: Self.url, options: [.atomic, .completeFileProtection])
    }

    @discardableResult
    func add(name: String) -> Person {
        let p = Person(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespaces), saved: nil)
        people.append(p)
        save()
        return p
    }

    func rename(_ id: String, to name: String) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        people[i].name = n
        save()
    }

    func setSaved(_ id: String, _ b: SavedBaseline?) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        people[i].saved = b
        save()
    }

    func remove(_ id: String) {
        people.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        save()
    }
}

/// 上の帯をタップしたときの「人を選ぶ」
struct PersonPickerView: View {
    @ObservedObject var store = PersonStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { store.selectedID = nil; dismiss() } label: { row("人を選ばない", selected: store.selectedID == nil) }
                    ForEach(store.people) { p in
                        Button { store.selectedID = p.id; dismiss() } label: {
                            row(p.displayName, detail: p.saved.map { "保存した普段 \(Self.date($0.savedDate))（\(CameraLens(rawValue: $0.camera)?.label ?? $0.camera)）" } ?? "保存した普段はありません",
                                selected: store.selectedID == p.id)
                        }
                    }
                } footer: {
                    Text("選んだ人の普段を、この端末の中にだけ保存します（数値だけ。映像・顔の形は保存しません）。名前は記録のファイルにも見る側にも送りません。名前を変える・消すは設定から")
                }
                Section("人を足す") {
                    HStack {
                        TextField("名前（例 姉）", text: $newName)
                        Button("足す") {
                            let p = store.add(name: newName)
                            store.selectedID = p.id
                            newName = ""
                            dismiss()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("人を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private func row(_ title: String, detail: String? = nil, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle())
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }
}

/// 設定の「人」：名前を変える・普段を消す・人を消す
struct PeopleSettingsSection: View {
    @ObservedObject var store = PersonStore.shared
    @State private var newName = ""

    var body: some View {
        Section {
            ForEach(store.people) { p in
                NavigationLink { PersonEditView(id: p.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.displayName)
                        Text(p.saved.map { "保存した普段 \(PersonPickerView.date($0.savedDate))" } ?? "保存した普段はありません")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                TextField("名前を足す（例 姉）", text: $newName)
                Button("足す") { store.add(name: newName); newName = "" }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("人") } footer: {
            Text("人ごとに、普段の数値（指標ごとの n・平均・標準偏差、カメラ、普段の長さ、保存した日時、顔の位置と大きさ）だけをこの端末に保存します。名前は外に送りません")
        }
    }
}

struct PersonEditView: View {
    let id: String
    @ObservedObject var store = PersonStore.shared
    @State private var name = ""
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = store.people.first { $0.id == id }
        Form {
            Section("名前") {
                TextField("名前", text: $name)
                    .onSubmit { store.rename(id, to: name) }
                Button("名前を変える") { store.rename(id, to: name) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == p?.name)
            }
            Section("保存した普段") {
                if let s = p?.saved {
                    LabeledContent("保存した日時", value: PersonPickerView.date(s.savedDate))
                    LabeledContent("カメラ", value: CameraLens(rawValue: s.camera)?.label ?? s.camera)
                    LabeledContent("普段の長さ", value: "\(Int(s.targetS))秒")
                    Button("普段を消す") { store.setSaved(id, nil) }
                } else {
                    Text("ありません（この人を選んで今日の普段を記録し終えると、自動で保存します）").foregroundStyle(.secondary)
                }
            }
            Section {
                Button("この人を消す") { confirmDelete = true }
            }
        }
        .navigationTitle(p?.displayName ?? "")
        .onAppear { name = p?.name ?? "" }
        .confirmationDialog("この人と、保存した普段を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す") { store.remove(id); dismiss() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("記録のファイルは消えません")
        }
    }
}
