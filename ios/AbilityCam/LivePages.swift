import SwiftUI

/// 「グラフ」のページの中身：直近5分の z とならした値。この端末のメモリにだけ置き、保存しない。
/// 増えるのは1秒に10回まで（グラフの描き直しもそれ以下）
@MainActor
final class GraphStore: ObservableObject {
    struct Sample {
        let t: Double                         // 撮影時刻（epoch 秒）
        let z: [Metric: Double]
        let values: [Metric: Double]          // ならした値（表情 0〜1、声 dB / Hz）
        let baseline: [Metric: DiffEngine.Stat]?
    }
    struct Event {
        let t: Double
        let label: String                     // 「家族の印：不快」「場面：食事」
        let isMark: Bool
    }

    struct Closed { let id: UUID; let start: Double; var end: Double }   // 目を閉じていた時間（v1.4〜）

    static let keepSeconds = 300.0
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var events: [Event] = []
    @Published private(set) var closed: [Closed] = []

    func reset() { samples = []; events = []; closed = [] }

    /// 目を閉じていた時間を足す・のばす（同じ区間は id で見分ける）
    func setClosed(_ s: DiffSegment) {
        if let i = closed.lastIndex(where: { $0.id == s.id }) {
            if closed[i].end != s.endT { closed[i].end = s.endT }
        } else {
            closed.append(Closed(id: s.id, start: s.startT, end: s.endT))
        }
    }

    func append(t: Double, z: [Metric: Double], values: [Metric: Double], baseline: [Metric: DiffEngine.Stat]?) {
        if let last = samples.last, t <= last.t { return }
        samples.append(Sample(t: t, z: z, values: values, baseline: baseline))
        if let i = samples.firstIndex(where: { $0.t >= t - Self.keepSeconds }), i > 0 { samples.removeFirst(i) }
        events.removeAll { $0.t < t - Self.keepSeconds }
        if closed.first.map({ $0.end < t - Self.keepSeconds }) == true { closed.removeAll { $0.end < t - Self.keepSeconds } }
    }

    func addEvent(t: Double, label: String, isMark: Bool) {
        events.append(Event(t: t, label: label, isMark: isMark))
    }
}

/// 違い1つ（「いま」の状態のカード、v1.14〜）：種類・向き・続いている秒数
struct DiffItem: Equatable {
    let target: DiffTarget
    let above: Bool
    let seconds: Int

    /// カードの大きな文字の短い言い方（見出し「いつもと違うこと」の下なので「いつもより」は省く。docs/wording-guide.md）
    var shortText: String {
        switch target {
        case .eyesClosed: DiffTarget.eyesClosedLabel
        case .voiceOn: DiffTarget.voiceOnLabel
        case .metric(.rmsDb): above ? "声が大きい" : "声が小さい"
        case .metric(.f0Hz): above ? "声が高い" : "声が低い"
        case .metric(let m): "\(m.label)動きが\(above ? "強い" : "弱い")"
        }
    }

    /// 光らせる顔の部位（声は顔の外に音の波のアイコン）
    var region: FaceRegion? {
        switch target {
        case .eyesClosed, .metric(.eyeSquint), .metric(.orbit): .eyes
        case .metric(.browDown): .brows
        case .metric(.noseLip): .nose
        case .metric(.mouthSmile), .metric(.jawOpen), .metric(.mouthTense), .metric(.cheekRaise): .mouth
        default: nil
        }
    }
    var isVoice: Bool { target == .voiceOn || target == .metric(.rmsDb) || target == .metric(.f0Hz) }
}

/// 「いま」のタブの真ん中（v1.14〜）：状態のカード。顔のイラスト（表情は変えない中立の形）の、違いが出ている部位を指標の色で光らせ、
/// 声の違いは横に音の波のアイコン。その下に大きな文字で「いつも通りです」か、違いを2つまで（種類の色、続いた秒数を添える）。
/// 気持ちを表す絵文字・表情は使わない（docs/wording-guide.md）
struct NowCard: View {
    @ObservedObject var model: AnalysisModel
    /// 映像の小さな窓の場所と幅：窓が上の角なら絵を、下の角なら文字を、窓の反対側へ寄せて重ならないようにする
    var windowCorner: Corner = .topTrailing
    var windowReserve: CGFloat = 0
    static let maxLines = 2

    var body: some View {
        GeometryReader { geo in
            let face = max(96, min(200, geo.size.height * 0.48))
            VStack(spacing: 6) {
                Text("いまの状態").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    // 表情に合わせて動かす（v1.15〜。v1.14 は中立の形）。違いが出た部位は光らせる
                    FaceSketch(shape: model.cameraActive ? model.faceShape : nil, size: face, highlights: highlights)
                    if !voiceItems.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(Array(voiceItems.enumerated()), id: \.offset) { _, d in
                                Image(systemName: "waveform").font(.system(size: face * 0.2, weight: .bold))
                                    .foregroundStyle(Palette.marker(d.target))
                            }
                        }
                        .accessibilityHidden(true)
                    }
                }
                .padding(windowCorner.isLeading ? .leading : .trailing, windowCorner.isTop ? windowReserve : 0)
                Spacer(minLength: 0)
                headline
                    .padding(windowCorner.isLeading ? .leading : .trailing, windowCorner.isTop ? 0 : windowReserve)
            }
            .padding(12)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var collecting: Bool { model.comparing == nil && model.baselineSec != nil }

    /// 光らせる部位：最初に出ている違いの色（普段を記録している間・いつも通りのときは光らせない）
    private var highlights: [FaceRegion: Color] {
        var h: [FaceRegion: Color] = [:]
        for d in model.diffItems { if let r = d.region, h[r] == nil { h[r] = Palette.marker(d.target) } }
        return h
    }
    private var voiceItems: [DiffItem] { model.diffItems.filter(\.isVoice) }

    @ViewBuilder private var headline: some View {
        VStack(spacing: 2) {
            if !model.diffItems.isEmpty {
                ForEach(Array(model.diffItems.prefix(Self.maxLines).enumerated()), id: \.offset) { _, d in
                    let line = Text(d.shortText).font(.largeTitle.bold()) + Text("（\(d.seconds)秒）").font(.title3.weight(.semibold))
                    // 1行で（途中で折り返すと読みにくいので、入らないときは縮める）
                    line.lineLimit(1).minimumScaleFactor(0.55)
                        .foregroundStyle(Palette.text(d.target))
                }
                if model.diffItems.count > Self.maxLines {
                    Text("ほか\(model.diffItems.count - Self.maxLines)つ").font(.headline).foregroundStyle(.secondary)
                }
            } else if collecting {
                Text("普段を記録しています").font(.title.bold()).foregroundStyle(Palette.progress).lineLimit(1).minimumScaleFactor(0.5)
                if let sec = model.baselineSec {
                    ProgressView(value: min(Double(sec), model.baselineTarget), total: model.baselineTarget).tint(Palette.progress)
                        .frame(maxWidth: 260)
                }
            } else {
                Text(model.faceReadable ? "いつも通りです" : "声は、いつも通りです")
                    .font(.largeTitle.bold()).foregroundStyle(Palette.face).lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 進み具合・声の補足（小さく。違いには数えない）。「いま」とデータの両方で使う
struct LiveNotes: View {
    @ObservedObject var model: AnalysisModel
    var showOther = true   // 「声：本人以外の声が入っています」（「いま」では映像の上に出すので出さない）

    var body: some View {
        if model.running {
            if model.baselineEyesClosedLong {   // 画面に出して取った普段の間に、目を閉じていた時間が長い（保存した普段で比べているときは出ない）
                NoteLine(text: "普段の間に目を閉じていた時間が長いです（取り直せます）", icon: "eye.slash", color: Palette.eyes, font: .caption.bold(), lines: 2)
            }
            if let v = model.voiceSec {
                NoteLine(text: "声の高さ：普段を集めています（本人の声 \(v)/\(Int(DiffCriteria.voiceBaselineS))秒）", icon: "hourglass", color: Palette.progress, lines: 2)
                if model.voiceRetaking {   // 声の高さの範囲を外している（v1.9.3〜）
                    NoteLine(text: "声の普段を集め直しています。この間は口の動きだけで本人の声を数えます", icon: "arrow.clockwise", color: Palette.progress, lines: 2)
                }
                if let w = model.voiceWait {   // 進み具合が3秒増えていないとき（v1.6.2〜）
                    NoteLine(text: "声の普段が増えない理由：\(w)", icon: "info.circle", color: Palette.progress, font: .caption2, lines: 2)
                }
            }
            if model.voiceSpreadWide, model.voiceSec == nil {   // 保存した声の普段で比べているとき（v1.9.1〜）
                NoteLine(text: "声の普段のばらつきが大きいです（取り直せます）", icon: "waveform", color: Palette.voice, lines: 2)
            }
            if let n = model.speakerEnrollNote {   // 声の登録（v1.10.1〜）
                NoteLine(text: n, icon: "person.wave.2", color: Palette.progress, lines: 3)
            }
            if showOther, model.otherVoice {
                NoteLine(text: "声：本人以外の声が入っています", icon: "waveform", color: Palette.voice, font: .caption.weight(.semibold))
            }
        }
    }
}

/// 画面の文（「いま」とデータで同じもの）
@MainActor
enum LiveText {
    /// 「顔：読めています・普段：記録しました」。保存した普段で比べているときは「普段：保存した普段（10/28 15:10）」
    /// だけを出す（うしろで記録している今日の普段は出さない、v1.3〜）
    static func baseline(_ model: AnalysisModel) -> String {
        let face = !model.cameraActive ? "顔：–" : model.faceReadable ? "顔：読めています" : "顔：読めません"
        if model.comparing == .saved {
            let at = model.savedFromMs.map { PersonPickerView.date(Date(timeIntervalSince1970: Double($0) / 1000)) } ?? ""
            return "\(face)・普段：保存した普段（\(at)）"
        }
        let today: String
        if let sec = model.baselineSec { today = "記録中 \(sec)/\(Int(model.baselineTarget))秒" }
        else if model.baselineReady { today = "記録しました" }
        else { today = "まだありません" }
        return "\(face)・普段：\(today)"
    }

    /// differences と、その種類（diffTargets、同じ順）
    static func diffLines(_ model: AnalysisModel) -> [(text: String, target: DiffTarget?)] {
        model.differences.enumerated().map { ($0.element, $0.offset < model.diffTargets.count ? model.diffTargets[$0.offset] : nil) }
    }
}

/// 「データ」のタブ（v1.11.3〜）：普段・顔の向き・本人の声の似ている度合い、指標ごとのずれのバー（数字付き）、直近60秒のグラフ、数字。
/// 表示だけで、記録・判定・見る側に送るものは「いま」のタブと同じ
struct DataTab: View {
    @ObservedObject var model: AnalysisModel
    @ObservedObject var graph: GraphStore

    init(model: AnalysisModel) { self.model = model; self.graph = model.graph }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("普段") {
                    NoteLine(text: LiveText.baseline(model), icon: "record.circle", color: Palette.face, font: .callout, lines: 2)
                    if model.comparing == nil, let sec = model.baselineSec {
                        ProgressView(value: min(Double(sec), model.baselineTarget), total: model.baselineTarget).tint(Palette.progress)
                    }
                    LiveNotes(model: model)
                    if !model.missingInSaved.isEmpty {   // v1.15〜
                        NoteLine(text: "保存した普段に無い指標：" + model.missingInSaved.map(\.label).joined(separator: "・")
                                 + (model.missingFilled ? "（今日の普段で比べています。普段を取り直すと保存した普段にも入ります）"
                                                        : "（今日の普段がたまったら比べます。普段を取り直すと保存した普段にも入ります）"),
                                 icon: "info.circle", color: Palette.progress, font: .caption, lines: 4)
                    }
                    Menu("普段を取り直す") {
                        ForEach(AnalysisModel.RestartPart.allCases) { p in Button(p.rawValue) { model.restart(p) } }
                    }
                    .font(.callout).buttonStyle(.bordered).disabled(!model.running)
                }
                section("顔の向き") {
                    Text(headText).font(.callout.weight(.medium)).foregroundStyle(Palette.head)
                }
                section("本人の声の似ている度合い（声紋）") { speaker }
                section("指標ごとのずれ（帯＝いつもの範囲、点＝今）") {
                    if model.eyesOffYaw {   // v1.16〜
                        NoteLine(text: "顔の向きが普段と違うので、目は比べていません", icon: "info.circle", color: Palette.progress, font: .caption)
                    }
                    meters
                }
                section("直近60秒") {
                    GraphPage(graph: graph).frame(height: 230)
                }
                section("数字") { NumbersGrid(model: model) }
            }
            .padding(.vertical, 6)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headText: String {
        guard model.cameraActive, let shape = model.faceShape else { return "顔の向き：読めません" }
        return shape["yaw"] != nil ? "顔の向き：\(FaceSketch.directionText(shape))" : "顔の向き：–"
    }

    @ViewBuilder private var speaker: some View {
        if let last = model.speakerLast {
            // 本人とするのは、0.3 以上で、ほかに登録した人より 0.15 以上高いとき（ほかに登録した人がいなければ 0.45 以上。v1.11〜、SpeakerCriteria）
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("選んでいる人（直近）"); Text(String(format: "%.2f", last.score)).monospacedDigit().bold() }
                GridRow {
                    Text("ほかに登録した人でいちばん高い")
                    Text(last.other.map { String(format: "%.2f", $0) } ?? "ほかに登録した人はいません").monospacedDigit()
                }
                GridRow { Text("その声の長さ"); Text(String(format: "%.1f秒", Double(last.windowMs) / 1000)).monospacedDigit() }
            }
            .font(.callout).foregroundStyle(Palette.voice)
            Text(last.other == nil
                 ? "本人とするのは \(String(format: "%.2f", SpeakerCriteria.selfThreshold)) 以上（1.5秒未満の声は使いません）"
                 : "本人とするのは \(String(format: "%.2f", SpeakerCriteria.relMinScore)) 以上で、ほかに登録した人より \(String(format: "%.2f", SpeakerCriteria.relMargin)) 以上高いとき（1.5秒未満の声は使いません）")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(model.otherVoiceBySpeaker ? "まだありません（声が出ると出ます）" : "記録する人の声の登録がないため、ありません（設定の「人」で登録できます）")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 指標ごとのずれのバー（見る側の「いま」と同じ描き方）と数字：ずれ（z）と、今の値（いつもの範囲）
    private var meters: some View {
        let last = graph.samples.last
        return VStack(spacing: 8) {
            ForEach(Metric.allCases, id: \.self) { m in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(m.color).frame(width: 9, height: 9)
                        Text(m.label).font(.callout).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer()
                        Text(model.meterZ[m].map { String(format: "ずれ %+.1f", $0) } ?? "ずれ –")
                            .font(.callout.monospacedDigit().weight(model.diffMetrics[m] != nil ? .bold : .regular))
                            .foregroundStyle(m.isFace ? Palette.face : Palette.voice)
                    }
                    MeterTrack(z: model.meterZ[m], hasRange: model.baselineStats?[m] != nil, outside: model.diffMetrics[m] != nil)
                        .frame(height: 18)
                    Text(valueLine(m, last)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if model.flatMetrics.contains(m) {   // v1.15〜：普段の間ほとんど動いていない（判定から外すかは記録を見てから決める）
                        NoteLine(text: "この顔では値がほとんど動いていません", icon: "info.circle", color: Palette.progress, font: .caption2)
                    }
                }
                .opacity(m.isFace && !model.faceReadable ? 0.4 : 1)
                .accessibilityElement(children: .combine)
            }
            Text("ずれは、今の値がいつもの平均から標準偏差の何倍離れているか（±2 の外が、いつもの範囲の外）").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func valueLine(_ m: Metric, _ s: GraphStore.Sample?) -> String {
        var text = "今 \(s?.values[m].map(m.valueText) ?? "–")"
        if let b = s?.baseline?[m] ?? model.baselineStats?[m] {
            let r = m.valueBounds
            let lo = min(max(b.mean - 2 * b.sd, r.lowerBound), r.upperBound), hi = min(max(b.mean + 2 * b.sd, r.lowerBound), r.upperBound)
            text += "・いつもの範囲 \(m.valueText(lo))〜\(m.valueText(hi))"
        } else {
            text += "・いつもの範囲はまだありません"
        }
        return text
    }
}

/// 2. グラフ：直近の指標ごとの z の線。いつもの範囲（±2）は薄い帯、家族の印・場面は縦線。
/// なぞると縦線がついてきて、その時刻の値といつもの範囲を上に出す（なぞっている間は止める。離すと今に戻る）
struct GraphPage: View {
    @ObservedObject var graph: GraphStore
    @State private var span = 60.0
    @State private var frozen: (samples: [GraphStore.Sample], events: [GraphStore.Event], closed: [GraphStore.Closed], end: Double)?
    @State private var touchX: CGFloat?

    static let spans: [(Double, String)] = [(20, "20秒"), (60, "1分"), (300, "5分")]
    static let zMax = 4.0

    var body: some View {
        let samples = frozen?.samples ?? graph.samples
        let events = frozen?.events ?? graph.events
        let end = frozen?.end ?? (graph.samples.last?.t ?? 0)
        let closed = frozen?.closed ?? graph.closed
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let sel = touchX.flatMap { x in sample(at: end - span + Double(x / max(w, 1)) * span, in: samples) }
                ZStack(alignment: .top) {
                    Canvas { ctx, size in draw(ctx, size, samples: samples, events: events, closed: closed, end: end, sel: sel) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if frozen == nil { frozen = (graph.samples, graph.events, graph.closed, graph.samples.last?.t ?? 0) }
                                touchX = min(max(v.location.x, 0), w)
                            }
                            .onEnded { _ in touchX = nil; frozen = nil })
                    if let sel { readout(sel, end: end, closed: closed.contains { $0.start <= sel.t && sel.t <= $0.end }).padding(4) }
                }
            }
            if touchX == nil {
                HStack(spacing: 8) {
                    legend
                    Picker("表示する長さ", selection: $span) {
                        ForEach(Self.spans, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
            } else {
                Text("指を離すと今に戻ります").font(.caption2).foregroundStyle(.secondary).frame(height: 24)
            }
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("指標ごとの、いつもの範囲からの離れ方のグラフ")
    }

    private var legend: some View {
        HStack(spacing: 4) {
            ForEach(Metric.main, id: \.self) { m in Circle().fill(m.color).frame(width: 7, height: 7) }
            Text("帯＝いつもの範囲").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            RoundedRectangle(cornerRadius: 2).fill(DiffTarget.eyesClosedColor.opacity(Self.closedOpacity)).frame(width: 12, height: 8)
            Text("目を閉じていた").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func sample(at t: Double, in s: [GraphStore.Sample]) -> GraphStore.Sample? {
        guard !s.isEmpty else { return nil }
        var lo = 0, hi = s.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if s[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let i = lo > 0 && abs(s[lo - 1].t - t) < abs(s[lo].t - t) ? lo - 1 : lo
        return abs(s[i].t - t) <= 1 ? s[i] : nil
    }

    /// 「12秒前」と、指標ごとの値（いつもの範囲）
    private func readout(_ s: GraphStore.Sample, end: Double, closed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Int((end - s.t).rounded()))秒前　（ ）内はいつもの範囲" + (closed ? "　目を閉じていた" : "")).font(.caption2.bold())
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach([Metric.main[row], Metric.main[row + 3]], id: \.self) { m in
                            Text(line(m, s)).font(.caption2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                }
            }
        }
        .foregroundStyle(ContentView.navy)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func line(_ m: Metric, _ s: GraphStore.Sample) -> String {
        var text = "\(m.label) \(s.values[m].map(m.valueText) ?? "–")"
        if let b = s.baseline?[m] {
            let r = m.valueBounds
            let lo = min(max(b.mean - 2 * b.sd, r.lowerBound), r.upperBound), hi = min(max(b.mean + 2 * b.sd, r.lowerBound), r.upperBound)
            text += "（\(m.valueText(lo))〜\(m.valueText(hi))）"
        }
        return text
    }

    static let closedOpacity = 0.22

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, samples: [GraphStore.Sample], events: [GraphStore.Event],
                      closed: [GraphStore.Closed], end: Double, sel: GraphStore.Sample?) {
        let w = size.width, h = size.height
        let start = end - span
        let x = { (t: Double) in CGFloat((t - start) / span) * w }
        let y = { (z: Double) in h / 2 - CGFloat(min(max(z, -Self.zMax), Self.zMax) / Self.zMax) * (h / 2 - 2) }

        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(.secondary.opacity(0.05)))
        ctx.fill(Path(CGRect(x: 0, y: y(2), width: w, height: y(-2) - y(2))), with: .color(ContentView.paleSlate))
        ctx.fill(Path(CGRect(x: 0, y: y(0) - 0.25, width: w, height: 0.5)), with: .color(ContentView.navy.opacity(0.25)))

        // 目を閉じていた時間（墨紫の薄い帯、上から下まで）
        for c in closed where c.end >= start && c.start <= end {
            let x0 = max(x(c.start), 0), x1 = min(x(c.end), w)
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1.5), height: h)),
                     with: .color(DiffTarget.eyesClosedColor.opacity(Self.closedOpacity)))
        }

        // 家族の印（濃紺の点線）・場面（灰の点線）
        for e in events where e.t >= start && e.t <= end {
            var p = Path()
            p.move(to: CGPoint(x: x(e.t), y: 0))
            p.addLine(to: CGPoint(x: x(e.t), y: h))
            ctx.stroke(p, with: .color(e.isMark ? ContentView.navy : .secondary.opacity(0.6)),
                       style: StrokeStyle(lineWidth: e.isMark ? 1.5 : 1, dash: [3, 3]))
        }

        // 指標ごとの z の線（点が多いときは幅に合わせて間引く。1秒より空いたら線を切る）
        let visible = samples.filter { $0.t >= start - 1 }
        let step = max(1, visible.count / max(Int(w), 1))
        for m in Metric.main {   // グラフの線は今までの6つ（表情のまとまりはずれのバーだけ、v1.12〜）
            var p = Path()
            var lastT: Double?
            for i in stride(from: 0, to: visible.count, by: step) {
                let s = visible[i]
                guard let z = s.z[m] else { lastT = nil; continue }
                let pt = CGPoint(x: x(s.t), y: y(z))
                if let l = lastT, s.t - l <= 1 { p.addLine(to: pt) } else { p.move(to: pt) }
                lastT = s.t
            }
            ctx.stroke(p, with: .color(m.color), lineWidth: 1.5)
        }

        if let sel {
            let px = x(sel.t)
            ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: h)), with: .color(ContentView.navy))
        }
    }
}

/// 数字（データのタブの下。v1.11.2 までは「数字」のページ）
struct NumbersGrid: View {
    @ObservedObject var model: AnalysisModel

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            stat("顔が映っている割合", model.faceRatio.map { "\(Int($0 * 100))%" })
            stat("解析コマ/秒", model.fps.map { String(format: "%.1f", $0) })
            stat("解析時間 ms", model.procMs.map { String(format: "%.0f", $0) })
            stat("撮影→結果 ms", model.latMs.map { String(format: "%.0f", $0) })
            stat("撮影→網目 ms", model.meshLagMs.map { String(format: "%.0f", $0) })
            stat("音量 dB", model.rmsDb.map { String(format: "%.0f", $0) })
            stat("声の高さ Hz", model.f0Hz.map { String(format: "%.0f", $0) })
            stat("声の高さが取れた割合（直近10秒、声が出ていたときのうち）", model.pitchRatio.map { "\(Int(($0 * 100).rounded()))%" })
            stat("カメラ", model.lensInUse?.label)
            stat("探す顔の数", "\(model.maxFaces)")
            stat("解析できた割合（10秒）", model.analyzedRatio.map { "\(Int(($0 * 100).rounded()))%" })
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "–").font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }
}
