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
    var pose: [String: BaselineRecord.Stat]?     // 普段の間の顔の向き（yaw_deg・pitch_deg・roll_deg、本人から見て。v1.8〜。比べるのには使わない）
    var voice: SavedVoice?                       // 声の普段（v1.6〜。それより前に保存したものには無い）

    var savedDate: Date { Date(timeIntervalSince1970: Double(savedMs) / 1000) }
}

/// 保存した声の普段（v1.6〜）：本人の声のコマだけで集めた声の大きさ・高さ
struct SavedVoice: Codable, Equatable {
    let metrics: [String: BaselineRecord.Stat]   // rms_db / f0_hz
    let validS: Double                           // 数えた本人の声の秒数
    let savedMs: Int64

    /// 声の高さのばらつき（四分位範囲 ÷ 1.349、v1.9.1〜）。中央値の無い v1.9 までの声の普段は標準偏差（注意を出すかを決めるだけ）
    var f0Spread: Double? {
        guard let st = metrics[Metric.f0Hz.rawValue], !st.insufficient else { return nil }
        if let q = st.iqr { return DiffCriteria.spread(iqr: q) }
        return st.std
    }
    /// ばらつきが大きすぎる（声の普段を集める間に、高い声・低い声も出していた）
    var spreadWide: Bool { (f0Spread ?? 0) > DiffCriteria.voiceSpreadWarnHz }
}

/// 人：名前だけ。この端末の中にだけ保存し、外には送らない（見る側にも、記録にも名前は書かない。記録には id だけ）
/// 保存した普段はカメラ（広角・超広角・前面）ごとに1つずつ、声の普段はカメラに関係なく1つ（v1.6.1〜）
struct Person: Codable, Identifiable, Equatable {
    let id: String                               // ランダムな id
    var name: String
    var savedByCamera: [String: SavedBaseline] = [:]   // カメラ（wide / ultra_wide / front）→ 表情の普段
    var voice: SavedVoice?                       // 声の普段（どのカメラでも使う）
    var voicePartial: VoicePartial?              // 途中まで集めた声の普段（v1.7〜。声の普段ができたら消す）

    /// 画面に出す名前（v1.3 から「さん」を付けない：「自分」「姉」）
    var displayName: String { name }

    func saved(for camera: String) -> SavedBaseline? { savedByCamera[camera] }
    var hasSaved: Bool { !savedByCamera.isEmpty }

    init(id: String, name: String) { self.id = id; self.name = name }

    enum CodingKeys: String, CodingKey { case id, name, savedByCamera = "saved_by_camera", voice, saved, voicePartial = "voice_partial" }

    /// v1.6 までの persons.json（saved が1つ）は、そのカメラの普段として移す。声の普段は人ごとに移す
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        savedByCamera = try c.decodeIfPresent([String: SavedBaseline].self, forKey: .savedByCamera) ?? [:]
        voice = try c.decodeIfPresent(SavedVoice.self, forKey: .voice)
        voicePartial = try c.decodeIfPresent(VoicePartial.self, forKey: .voicePartial)
        if var old = try c.decodeIfPresent(SavedBaseline.self, forKey: .saved) {
            if voice == nil { voice = old.voice }
            old.voice = nil
            if savedByCamera[old.camera] == nil { savedByCamera[old.camera] = old }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(savedByCamera, forKey: .savedByCamera)
        try c.encodeIfPresent(voice, forKey: .voice)
        try c.encodeIfPresent(voicePartial, forKey: .voicePartial)
    }
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
        let p = Person(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespaces))
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

    /// そのカメラの普段だけを置き換える（ほかのカメラの普段は変えない）。nil で消す
    func setSaved(_ id: String, camera: String, _ b: SavedBaseline?) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        var b = b
        b?.voice = nil   // 声の普段は人ごとに別に持つ
        people[i].savedByCamera[camera] = b
        save()
    }

    /// 声の普段を置き換える。できたら、途中まで集めた分は消す
    func setVoice(_ id: String, _ v: SavedVoice?) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        people[i].voice = v
        if v != nil { people[i].voicePartial = nil }
        save()
    }

    /// 途中まで集めた声の普段を置き換える（nil で消す。v1.7〜）
    func setVoicePartial(_ id: String, _ p: VoicePartial?) {
        guard let i = people.firstIndex(where: { $0.id == id }), people[i].voicePartial != p else { return }
        people[i].voicePartial = p
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
                            row(p.displayName, detail: Self.savedSummary(p),
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

    /// 「保存した普段：広角 10/28 15:10・前面 10/28 16:02」（カメラごと、v1.6.1〜）
    static func savedSummary(_ p: Person) -> String {
        let list = CameraLens.allCases.compactMap { l in p.saved(for: l.rawValue).map { "\(l.shortLabel) \(date($0.savedDate))" } }
        return list.isEmpty ? "保存した普段はありません" : "保存した普段：" + list.joined(separator: "・")
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
                        Text(PersonPickerView.savedSummary(p))
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
            Text("人ごとに、普段の数値（指標ごとの n・平均・標準偏差、普段の長さ、保存した日時、顔の位置と大きさ）だけをこの端末に保存します。表情の普段はカメラ（広角・超広角・前面）ごとに1つずつ、声の普段はどのカメラでも使う1つです。名前は外に送りません")
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
            Section {
                ForEach(CameraLens.allCases) { l in
                    if let s = p?.saved(for: l.rawValue) {
                        LabeledContent(l.label, value: "\(PersonPickerView.date(s.savedDate))（\(Int(s.targetS))秒）")
                        Button("\(l.shortLabel)の普段を消す") { store.setSaved(id, camera: l.rawValue, nil) }
                    } else {
                        LabeledContent(l.label, value: "ありません")
                    }
                }
            } header: { Text("保存した表情の普段（カメラごと）") } footer: {
                Text("このカメラで今日の普段を記録し終えると、そのカメラの普段として自動で保存します（ほかのカメラの普段は変えません）")
            }
            Section {
                if let v = p?.voice {
                    LabeledContent("保存した日時", value: PersonPickerView.date(Date(timeIntervalSince1970: Double(v.savedMs) / 1000)))
                    LabeledContent("本人の声", value: String(format: "%.0f秒", v.validS))
                    if let m = v.metrics[Metric.f0Hz.rawValue], let med = m.median {
                        LabeledContent("声の高さ（中央値・ばらつき）", value: String(format: "%.0f Hz・%.0f Hz", med, v.f0Spread ?? 0))
                    }
                    if v.spreadWide {
                        Text("声の普段のばらつきが大きいです（取り直せます）").foregroundStyle(ContentView.navyText)
                    }
                    // 取り直す：保存した声の普段と途中まで集めた分を消し、次に記録を始めたときから集め直す
                    Button("声の普段を取り直す") { store.setVoice(id, nil); store.setVoicePartial(id, nil) }
                    Button("声の普段を消す") { store.setVoice(id, nil) }
                } else {
                    Text("ありません（本人の声が10秒たまると、自動で保存します）").foregroundStyle(.secondary)
                }
            } header: { Text("保存した声の普段（どのカメラでも使う）") } footer: {
                Text("「取り直す」と、保存した声の普段と途中まで集めた声を消し、次に記録を始めたときから集め直します")
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
