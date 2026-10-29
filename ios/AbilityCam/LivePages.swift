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

/// 1. いま：大きく「いつもとの違い」（最大3行）、小さいメーター6本、状態の小さな表示
struct NowPage: View {
    @ObservedObject var model: AnalysisModel
    static let maxLines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.6)
                Spacer(minLength: 2)
                // 表情だけ／声だけ／両方を選ぶ（v1.9.2〜）
                Menu("普段を取り直す") {
                    ForEach(AnalysisModel.RestartPart.allCases) { p in
                        Button(p.rawValue) { model.restart(p) }
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!model.running)
            }
            differences
            meters
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 「顔：読めています・普段：記録しました」。保存した普段で比べているときは「顔：読めています・普段：保存した普段（10/28 15:10）」
    /// だけを出す（うしろで記録している今日の普段は出さない、v1.3〜）
    private var statusText: String {
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

    private var differences: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.running {
                Text(PersonStore.shared.selected?.saved(for: (model.lensInUse ?? CameraLens.selected).rawValue) != nil
                     ? "記録が始まると、保存した普段で比べ始めます（カメラが違うときは、最初の\(Int(AnalysisModel.selectedBaselineSeconds))秒を「普段」として記録します）"
                     : "記録が始まると、最初の\(Int(AnalysisModel.selectedBaselineSeconds))秒を「普段」として記録します")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.7)
            } else if model.comparing == nil, let sec = model.baselineSec {
                Text("普段を記録しています").font(.title3.bold()).foregroundStyle(ContentView.navyText)
                ProgressView(value: min(Double(sec), model.baselineTarget), total: model.baselineTarget)
                    .tint(ContentView.navyText)
                Text(model.baselineWait ?? "落ち着いているときに。顔が映っている間だけ数えます")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                eyesClosedNote
                // 普段を記録している間も、普段と比べないもの（声が出た、v1.7〜）は出す
                ForEach(Array(model.differences.prefix(Self.maxLines)), id: \.self) {
                    Text($0).font(.callout.bold()).foregroundStyle(ContentView.navyText).lineLimit(1).minimumScaleFactor(0.6)
                }
            } else if model.differences.isEmpty {
                Text(model.faceReadable ? "いつもと大きな違いはありません" : "声は、いつもと大きな違いはありません")
                    .font(.title3.bold()).foregroundStyle(ContentView.navyText)
                    .lineLimit(1).minimumScaleFactor(0.6)
            } else {
                ForEach(Array(model.differences.prefix(Self.maxLines)), id: \.self) {
                    Text($0).font(.title3.bold()).foregroundStyle(ContentView.navyText).lineLimit(1).minimumScaleFactor(0.6)
                }
                if model.differences.count > Self.maxLines {
                    Text("ほか\(model.differences.count - Self.maxLines)件").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.running, model.comparing == .today { eyesClosedNote }   // 画面に出して取った普段を、取り終えたあとも
            voiceNote
        }
    }

    /// 声の普段を集めている間と、本人以外の声だけが入っているとき（v1.6〜。小さく出す。違いには数えない）
    @ViewBuilder private var voiceNote: some View {
        if model.running {
            if let v = model.voiceSec {
                Text("声の高さ：普段を集めています（本人の声 \(v)/\(Int(DiffCriteria.voiceBaselineS))秒）")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                if model.voiceRetaking {   // 声の高さの範囲を外している（v1.9.3〜）
                    Text("声の普段を集め直しています。この間は口の動きだけで本人の声を数えます")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.7)
                }
                if let w = model.voiceWait {   // 進み具合が3秒増えていないとき（v1.6.2〜）
                    Text("声の普段が増えない理由：\(w)").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            if model.voiceSpreadWide, model.voiceSec == nil {   // 保存した声の普段で比べているとき（v1.9.1〜）
                Text("声の普段のばらつきが大きいです（取り直せます）").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            if let n = model.speakerEnrollNote {   // 声の登録（v1.10.1〜）
                Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.7)
            }
            if model.otherVoice {
                Text("声：本人以外の声が入っています").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// 普段の間に目を閉じていた時間が、数えた時間の2割を超えたとき（保存した普段で比べながらうしろで取っている普段には出さない）
    @ViewBuilder private var eyesClosedNote: some View {
        if model.baselineEyesClosedLong {
            Text("普段の間に目を閉じていた時間が長いです（取り直せます）")
                .font(.caption.bold()).foregroundStyle(ContentView.navyText).lineLimit(2).minimumScaleFactor(0.7)
        }
    }

    /// 見る側の「いま」のメーターを小さくしたもの（縦1列6本。空いている高さに合わせて太くなる）。
    /// いつもの範囲の帯と今の点、外れたらアンバー。顔が読めないときに薄くするのは表情の4本だけ（声の2本は普通の濃さ）
    private var meters: some View {
        VStack(spacing: 3) {
            ForEach(Metric.allCases, id: \.self) { m in
                HStack(spacing: 6) {
                    Circle().fill(m.color).frame(width: 8, height: 8)
                    Text(m.label).font(.footnote).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: 84, alignment: .leading)
                    MeterTrack(z: model.meterZ[m], hasRange: model.baselineStats?[m] != nil,
                               outside: model.diffMetrics[m] != nil)
                        .frame(minHeight: 12, maxHeight: 26)
                }
                .frame(maxHeight: .infinity)
                .opacity(m.isFace && !model.faceReadable ? 0.35 : 1)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("指標ごとのメーター")
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
            ForEach(Metric.allCases, id: \.self) { m in Circle().fill(m.color).frame(width: 7, height: 7) }
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
                        ForEach([Metric.allCases[row], Metric.allCases[row + 3]], id: \.self) { m in
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
        for m in Metric.allCases {
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

/// 3. 数字
struct NumbersPage: View {
    @ObservedObject var model: AnalysisModel

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
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
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
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
