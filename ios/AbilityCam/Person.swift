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
    var asym: [String: BaselineRecord.Stat]?     // 左右の差の普段（v1.12〜。判定には使わない）

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
    var markDetails: MarkDetails?                // 家族の印の詳しい中身の選択肢（v1.13〜。nil なら初めの選択肢）

    var markOptions: MarkDetails { markDetails ?? .initial }

    /// 画面に出す名前（v1.3 から「さん」を付けない：「自分」「姉」）
    var displayName: String { name }

    func saved(for camera: String) -> SavedBaseline? { savedByCamera[camera] }
    var hasSaved: Bool { !savedByCamera.isEmpty }

    init(id: String, name: String) { self.id = id; self.name = name }

    enum CodingKeys: String, CodingKey { case id, name, savedByCamera = "saved_by_camera", voice, saved, voicePartial = "voice_partial", voiceRetakePending = "voice_retake_pending"
        case speaker, speakerPartial = "speaker_partial", markDetails = "mark_details" }

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
        markDetails = try c.decodeIfPresent(MarkDetails.self, forKey: .markDetails)
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
        try c.encodeIfPresent(markDetails, forKey: .markDetails)
    }
}

/// 人の一覧。Application Support の persons.json（「ファイル」アプリには出ない場所）に置く
@MainActor
final class PersonStore: ObservableObject {
    static let shared = PersonStore()

    @Published private(set) var people: [Person] = []
    @Published var selectedID: String? {
        didSet { if !previewOnly { UserDefaults.standard.set(selectedID, forKey: "personID") } }
    }
    private var previewOnly = false   // スクリーンショット用の作り物の人（保存しない）

    #if DEBUG
    /// 最初の画面のスクリーンショット用（-uiPreviewStart -previewPeople 0/1/3）。persons.json・前回の人は変えない
    func fillPreview(count: Int) {
        previewOnly = true
        people = ["自分", "姉", "母"].prefix(max(0, count)).enumerated().map { Person(id: "preview-\($0.offset)", name: $0.element) }
        selectedID = people.first?.id
    }
    #endif

    var selected: Person? { people.first { $0.id == selectedID } }

    // MARK: 記録する人（v1.11〜：開いたら人を選んでから記録を始める。1本の記録には1人だけ）

    /// 記録している（ファイルが開いている）か。AnalysisModel が入れる
    @Published var inSession = false
    /// 人を選んで記録を始めるのを待っている（開いたあと・記録を閉じたあと）。AnalysisModel が入れる。
    /// 初めから true（v1.11.2〜）：カメラの許可のダイアログなどで前に出る前も、記録中の画面ではなく最初の画面を出す
    @Published var awaitingPerson = true
    /// この人で記録を始める（記録中なら閉じてから新しく。lens：カメラも変える）。AnalysisModel が入れる
    var onStartRecording: ((String, CameraLens?) -> Void)?

    /// 人を選んだ：記録していなければその人で始める。記録中は人を変えない（v1.11.2〜。記録を終えてから選ぶ）。返り値：始めたか
    @discardableResult
    func choose(_ id: String) -> Bool {
        guard !inSession, people.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        onStartRecording?(id, nil)
        return true
    }

    /// 設定で記録中に人かカメラを変えた：「いまの記録を閉じて、新しく始めますか？」で「はい」（v1.11.3〜）。今の記録を閉じて、新しい記録にする
    func restartRecording(personID id: String? = nil, lens: CameraLens? = nil) {
        guard let pid = id ?? selectedID, people.contains(where: { $0.id == pid }) else { return }
        onStartRecording?(pid, lens)
    }

    static let restartQuestion = "いまの記録を閉じて、新しく始めますか？"
    static func restartMessage(_ what: String) -> String {
        "1本の記録には1人・1つのカメラです。いまの記録を閉じて要約し、\(what)で新しい記録を始めます"
    }

    /// 選んだ人の一覧の順：前回の人（selectedID）をいちばん上に
    var chooseOrder: [Person] {
        people.filter { $0.id == selectedID } + people.filter { $0.id != selectedID }
    }

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
        guard !previewOnly, let d = try? JSONEncoder().encode(people) else { return }
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
    /// 今の記録で話者の区別が動いているか（記録していなければ nil。v1.10.2〜、設定のトグルの下に出す）
    @Published var speakerInSession: Bool?
    @Published var speakerEnrollCollect: SpeakerEnrollCollect?   // 集めているもの（本人の声とされた時間だけ／声が出ている時間すべて、v1.10.1〜）
    /// 撮る側が、記録中ならその人の声の登録を集め始める（始めたら true）。AnalysisModel が入れる
    var onSpeakerEnroll: ((_ id: String, _ consentBy: String) -> Bool)?
    var onSpeakerEnrollStop: (() -> Void)?

    @discardableResult
    func startSpeakerEnroll(_ id: String, consentBy: String) -> Bool {
        let live = onSpeakerEnroll?(id, consentBy) ?? false
        if live { speakerEnrolling = id }   // 秒数は AnalysisModel が入れる（続きからなら途中の秒数）
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

    /// 家族の印の詳しい中身の選択肢を置き換える（v1.13〜）
    func setMarkDetails(_ id: String, _ d: MarkDetails) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        people[i].markDetails = d
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

    /// 記録している人は消さない（v1.11.2〜。記録を終えてから消す）
    func remove(_ id: String) {
        guard !(inSession && selectedID == id) else { return }
        people.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        save()
    }
}

/// 人の行・保存した普段の要約など、人の画面で使うもの
@MainActor
enum PersonPickerView {
    /// 行の右上の小さな印：「記録している人」「前回」
    static func tag(_ p: Person, _ store: PersonStore) -> String? {
        guard store.selectedID == p.id else { return nil }
        return store.inSession ? "記録している人" : "前回"
    }
}

extension PersonPickerView {
    static func row(_ title: String, tag: String? = nil, detail: String? = nil, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).foregroundStyle(.primary)
                    if let tag {
                        Text(tag).font(.caption2.bold()).foregroundStyle(Palette.face)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(ContentView.paleSlate.opacity(0.6), in: Capsule())
                    }
                }
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
                    PersonPickerView.row(p.displayName, tag: PersonPickerView.tag(p, store), detail: PersonPickerView.savedSummary(p), selected: false)
                }
            }
            HStack {
                TextField("名前を足す（例 姉）", text: $newName)
                Button("足す") { store.add(name: newName); newName = "" }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("人") } footer: {
            Text("人ごとに、普段の数値（指標ごとの n・平均・標準偏差、普段の長さ、保存した日時、顔の位置と大きさ）だけをこの端末に保存します。表情の普段はカメラ（広角・超広角・前面）ごとに1つずつ、声の普段はどのカメラでも使う1つです。名前は記録のファイルには書かず（記録には id だけ）、見る側に記録している人の名前だけを送ります。記録していないときは、人ごとの画面の「この人で記録する」でも記録を始められます（記録中は人を変えません）")
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
    @State private var askRestart = false           // 「いまの記録を閉じて、新しく始めますか？」（v1.11.3〜）
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
            // どちらで集めるか（v1.10.1〜）：集めている間は始めたときのもの、それ以外は今選んでいる人かで
            let collect: SpeakerEnrollCollect? = store.speakerEnrolling == id ? store.speakerEnrollCollect : (store.selectedID == id ? .voiceSelf : .voiced)
            if let c = collect { Text(Self.collectNote(c)).font(.caption).foregroundStyle(.secondary) }
            if let n = speakerNote { Text(n).font(.caption).foregroundStyle(.secondary) }
            if !speakerRecord { Text("設定の「話者の区別を記録する」がオフのあいだは、集めず、記録にも書きません").font(.caption).foregroundStyle(.secondary) }
        } header: { Text("声の登録（話者の区別・記録に書くだけ）") } footer: {
            Text("記録しているときに、この人がひとりで話している間に押してください。声が\(target)秒たまると登録します（取り直すときは、たまるまで今の登録を残します）。声の特徴の数値はこの端末の中だけに置き、記録にはだれの声か分けるための似ている度合いだけを書きます。本人確認・認証には使いません")
        }
    }

    /// 記録する人（v1.11〜）：記録中にほかの人を選ぶと「いまの記録を閉じて、新しく始めますか？」と確かめる（v1.11.3〜。人を変えるのは設定と最初の画面だけ）
    @ViewBuilder private func recordSection(_ p: Person?) -> some View {
        Section {
            if store.inSession, store.selectedID == id {
                Label("この人を記録しています", systemImage: "record.circle").foregroundStyle(Palette.face)
            } else if let p {
                Button("この人で記録する") {
                    if store.inSession { askRestart = true } else { store.choose(p.id) }
                }
            }
        } header: { Text("記録する人") } footer: {
            Text("1本の記録には1人だけです。記録中にほかの人にすると、いまの記録を閉じて、その人で新しい記録を始めます。名前を変える・声を登録する・普段を取り直すは、記録中もできます（記録する人は変わりません）")
        }
    }

    /// 登録の画面に小さく出す、どちらで集めるか（docs/wording-guide.md）
    static func collectNote(_ c: SpeakerEnrollCollect) -> String {
        switch c {
        case .voiceSelf: return "選んでいる人なので、本人の声として数えた時間だけを集めます"
        case .voiced: return "選んでいる人ではないので、声が出ている時間をすべて集めます"
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
                        // 保存した普段に無い指標（v1.15〜。前の版で保存した普段）
                        let missing = Metric.allCases.filter { m in m.isFace && (s.metrics[m.rawValue].map { $0.insufficient } ?? true) }
                        if !missing.isEmpty {
                            Text("保存した普段に無い指標：" + missing.map(\.label).joined(separator: "・") + "（普段を取り直すと比べます）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
            recordSection(p)
            Section {
                NavigationLink("家族の印の詳しい中身") { MarkDetailsEditor(id: id) }
            } footer: {
                Text("家族の印（快・不快）を押したあとに出す選択肢です。家族の言葉としてそのまま記録します。アプリが状態として判定したり、画面に状態として出したりはしません")
            }
            speakerSection(p)
            Section {
                if store.inSession && store.selectedID == id {
                    Text("この人を記録しているので、記録を終えてから消せます").foregroundStyle(.secondary)   // v1.11.2〜
                } else {
                    Button("この人を消す") { confirmDelete = true }
                }
            }
        }
        .alert(PersonStore.restartQuestion, isPresented: $askRestart) {
            Button("はい") { store.restartRecording(personID: id) }
            Button("いいえ", role: .cancel) {}
        } message: {
            Text(PersonStore.restartMessage(p?.displayName ?? ""))
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

/// 設定の人ごとの画面の「家族の印の詳しい中身」（v1.13〜）：快・不快それぞれの選択肢を足す・消す・並べ替える
struct MarkDetailsEditor: View {
    let id: String
    @ObservedObject var store = PersonStore.shared
    @State private var newPleasant = ""
    @State private var newUnpleasant = ""

    private var details: MarkDetails { store.people.first { $0.id == id }?.markOptions ?? .initial }

    var body: some View {
        List {
            section(.unpleasant, items: details.unpleasant, text: $newUnpleasant)
            section(.pleasant, items: details.pleasant, text: $newPleasant)
            Section {
                Button("初めの選択肢に戻す") { store.setMarkDetails(id, .initial) }
            } footer: {
                Text("家族の印を押したあと、数秒だけ選択肢を出します。選ばなければ、印だけを記録します。選んだ言葉は、家族の言葉としてそのまま記録に書きます（アプリが状態として判定・表示には使いません）。「分からない」には出しません。あとから、これまでの記録や Mac で付けたり変えたりできます")
            }
        }
        .navigationTitle("家族の印の詳しい中身")
        .toolbar { EditButton() }
    }

    private func section(_ m: Mark, items: [String], text: Binding<String>) -> some View {
        Section(m.rawValue) {
            ForEach(items, id: \.self) { Text($0) }
                .onDelete { idx in update(m) { $0.remove(atOffsets: idx) } }
                .onMove { from, to in update(m) { $0.move(fromOffsets: from, toOffset: to) } }
            HStack {
                TextField("選択肢を足す", text: text)
                Button("足す") {
                    let v = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                    text.wrappedValue = ""
                    guard !v.isEmpty else { return }
                    update(m) { if !$0.contains(v) { $0.append(v) } }
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func update(_ m: Mark, _ change: (inout [String]) -> Void) {
        var d = details
        if m == .pleasant { change(&d.pleasant) } else { change(&d.unpleasant) }
        store.setMarkDetails(id, d)
    }
}
