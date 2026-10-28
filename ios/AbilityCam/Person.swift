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
    var voiceRetakePending = false               // 記録していないときに「声の普段を取り直す」を押した：次のセッションで集め直す（v1.9.3〜）
    var speaker: SpeakerEnrollment?              // 声の登録（話者の区別、v1.10〜）。声の特徴の数値と、だれが同意したか。この端末の中だけ（バックアップにも入れない）
    var speakerPartial: SpeakerEnrollPartial?    // 途中まで集めた声の登録（14日で捨てる）

    /// 画面に出す名前（v1.3 から「さん」を付けない：「自分」「姉」）
    var displayName: String { name }

    func saved(for camera: String) -> SavedBaseline? { savedByCamera[camera] }
    var hasSaved: Bool { !savedByCamera.isEmpty }

    init(id: String, name: String) { self.id = id; self.name = name }

    enum CodingKeys: String, CodingKey { case id, name, savedByCamera = "saved_by_camera", voice, saved, voicePartial = "voice_partial", voiceRetakePending = "voice_retake_pending"
        case speaker, speakerPartial = "speaker_partial" }

    /// v1.6 までの persons.json（saved が1つ）は、そのカメラの普段として移す。声の普段は人ごとに移す
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        savedByCamera = try c.decodeIfPresent([String: SavedBaseline].self, forKey: .savedByCamera) ?? [:]
        voice = try c.decodeIfPresent(SavedVoice.self, forKey: .voice)
        voicePartial = try c.decodeIfPresent(VoicePartial.self, forKey: .voicePartial)
        voiceRetakePending = try c.decodeIfPresent(Bool.self, forKey: .voiceRetakePending) ?? false
        speaker = try c.decodeIfPresent(SpeakerEnrollment.self, forKey: .speaker)
        speakerPartial = try c.decodeIfPresent(SpeakerEnrollPartial.self, forKey: .speakerPartial)
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
        if voiceRetakePending { try c.encode(true, forKey: .voiceRetakePending) }
        try c.encodeIfPresent(speaker, forKey: .speaker)
        try c.encodeIfPresent(speakerPartial, forKey: .speakerPartial)
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

    /// 記録中にその場で声の普段を集め直している人（v1.9.2〜。設定の「人」に「声の普段を集め直しています」と出す）
    @Published var voiceRestarting: String?
    /// 撮る側が、記録中ならその場で声の普段を集め直し始める（始めたら true）。AnalysisModel が入れる
    var onVoiceRestart: ((String) -> Bool)?

    /// 「声の普段を取り直す」（v1.9.3〜）：記録中でその人を選んでいれば、その場で集め直し始める。そうでなければ、次のセッションで集め直す。
    /// どちらも、本人の声が10秒たまって保存し直すまで、保存した古い声の普段は消さない（途中で閉じたら古い声の普段のまま。「いま」の「声だけ」と同じ）。
    /// 返り値：その場で始めたか
    @discardableResult
    func restartVoice(_ id: String) -> Bool {
        let live = onVoiceRestart?(id) ?? false
        voiceRestarting = live ? id : nil
        setVoiceRetakePending(id, !live)
        return live
    }

    func setVoiceRetakePending(_ id: String, _ on: Bool) {
        guard let i = people.firstIndex(where: { $0.id == id }), people[i].voiceRetakePending != on else { return }
        people[i].voiceRetakePending = on
        save()
    }

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
        Self.excludeFromBackup()
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(people) else { return }
        try? d.write(to: Self.url, options: [.atomic, .completeFileProtection])
        Self.excludeFromBackup()   // 書き直すと付け直しが要ることがあるので、毎回
    }

    /// persons.json を iCloud・端末のバックアップに入れない（v1.10〜。声の特徴の数値を入れる前に）
    private static func excludeFromBackup() {
        var u = url
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    // MARK: 声の登録（話者の区別、v1.10〜）

    /// 声の登録を集めている人（記録中だけ）と、集めた秒数（設定の「人」に出す）
    @Published var speakerEnrolling: String?
    @Published var speakerEnrollSec: Int = 0
    /// 撮る側が、記録中ならその人の声の登録を集め始める（始めたら true）。AnalysisModel が入れる
    var onSpeakerEnroll: ((_ id: String, _ consentBy: String) -> Bool)?
    var onSpeakerEnrollStop: (() -> Void)?

    @discardableResult
    func startSpeakerEnroll(_ id: String, consentBy: String) -> Bool {
        let live = onSpeakerEnroll?(id, consentBy) ?? false
        if live { speakerEnrolling = id; speakerEnrollSec = 0 }
        return live
    }

    func stopSpeakerEnroll() { onSpeakerEnrollStop?(); speakerEnrolling = nil }

    func setSpeaker(_ id: String, _ e: SpeakerEnrollment?) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        people[i].speaker = e
        if e != nil { people[i].speakerPartial = nil }
        save()
    }

    func setSpeakerPartial(_ id: String, _ p: SpeakerEnrollPartial?) {
        guard let i = people.firstIndex(where: { $0.id == id }), people[i].speakerPartial != p else { return }
        people[i].speakerPartial = p
        save()
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
    @State private var askConsent = false          // 声の登録の前に、だれが同意したかを聞く（v1.10〜）
    @State private var consentName = ""
    @State private var speakerNote: String?
    @AppStorage("speakerRecord") private var speakerRecord = false
    @Environment(\.dismiss) private var dismiss

    /// 声の登録（話者の区別、v1.10〜。記録に書くだけで、画面には出さない）
    @ViewBuilder private func speakerSection(_ p: Person?) -> some View {
        let target = Int(SpeakerCriteria.enrollTargetS)
        Section {
            if store.speakerEnrolling == id {
                Text("\(p?.displayName ?? "")の声を集めています（\(store.speakerEnrollSec)/\(target)秒）").foregroundStyle(ContentView.navyText)
                Button("止める") { store.stopSpeakerEnroll() }
            } else if let s = p?.speaker {
                LabeledContent("登録した日時", value: PersonPickerView.date(Date(timeIntervalSince1970: Double(s.savedMs) / 1000)))
                LabeledContent("同意した人", value: s.consentBy)
                LabeledContent("使った声", value: String(format: "%.0f秒", s.validS))
                if s.model != SpeakerCriteria.model {
                    Text("前のモデルの登録なので使いません（取り直せます）").foregroundStyle(.secondary)
                }
                Button("声の登録を取り直す") { consentName = s.consentBy; askConsent = true }
                Button("声の登録を消す") { store.setSpeaker(id, nil); store.setSpeakerPartial(id, nil) }
            } else if let part = p?.speakerPartial, part.model == SpeakerCriteria.model {
                Text("途中まで集めています（\(Int(part.validS))/\(target)秒）").foregroundStyle(.secondary)
                Button("続きを集める") { consentName = part.consentBy; askConsent = true }
                Button("途中の分を消す") { store.setSpeakerPartial(id, nil) }
            } else {
                Button("声を登録する") { consentName = p?.name ?? ""; askConsent = true }
            }
            if let n = speakerNote { Text(n).font(.caption).foregroundStyle(.secondary) }
            if !speakerRecord { Text("設定の「話者の区別を記録する」がオフのあいだは、集めず、記録にも書きません").font(.caption).foregroundStyle(.secondary) }
        } header: { Text("声の登録（話者の区別・記録に書くだけ）") } footer: {
            Text("記録しているときに、この人がひとりで話している間に押してください。声が\(target)秒たまると登録します（取り直すときは、たまるまで今の登録を残します）。声の特徴の数値はこの端末の中だけに置き、記録にはだれの声か分けるための似ている度合いだけを書きます。本人確認・認証には使いません")
        }
    }

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
                    // 取り直す：記録中ならその場で、そうでなければ次のセッションで集め直す。10秒たまって保存し直すまで、この声の普段は残す（v1.9.3〜）
                    if store.voiceRestarting == id {
                        Text("声の普段を集め直しています（本人の声が10秒たまったら保存し直します）").foregroundStyle(ContentView.navyText)
                    } else if p?.voiceRetakePending == true {
                        Text("次に記録を始めたときから、声の普段を集め直します").foregroundStyle(.secondary)
                    } else {
                        Button("声の普段を取り直す") { store.restartVoice(id) }
                    }
                    Button("声の普段を消す") { store.setVoice(id, nil) }
                } else if store.voiceRestarting == id {
                    Text("声の普段を集め直しています").foregroundStyle(ContentView.navyText)
                } else {
                    Text("ありません（本人の声が10秒たまると、自動で保存します）").foregroundStyle(.secondary)
                }
            } header: { Text("保存した声の普段（どのカメラでも使う）") } footer: {
                Text("「取り直す」と、記録中でこの人を選んでいればその場で、そうでなければ次に記録を始めたときから声の普段を集め直します。本人の声が10秒たまって保存し直すまで、今の声の普段は残します（途中で閉じたら今の声の普段のまま）")
            }
            speakerSection(p)
            Section {
                Button("この人を消す") { confirmDelete = true }
            }
        }
        .alert("声の登録", isPresented: $askConsent) {
            TextField("同意した人の名前", text: $consentName)
            Button("同意して集める") {
                let n = consentName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { speakerNote = "同意した人の名前を入れてください"; return }
                speakerNote = store.startSpeakerEnroll(id, consentBy: n) ? nil : "記録しているときに押してください（設定の「話者の区別を記録する」もオンに）"
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("\(p?.displayName ?? "")の声の特徴を数値にして、この端末の中だけに保存します（バックアップにも入れません）。記録には似ている度合いだけを書き、声そのものは保存しません。本人確認には使いません。同意した人の名前を入れてください")
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
