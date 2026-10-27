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

    static let keepSeconds = 300.0
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var events: [Event] = []

    func reset() { samples = []; events = [] }

    func append(t: Double, z: [Metric: Double], values: [Metric: Double], baseline: [Metric: DiffEngine.Stat]?) {
        if let last = samples.last, t <= last.t { return }
        samples.append(Sample(t: t, z: z, values: values, baseline: baseline))
        if let i = samples.firstIndex(where: { $0.t >= t - Self.keepSeconds }), i > 0 { samples.removeFirst(i) }
        events.removeAll { $0.t < t - Self.keepSeconds }
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
            HStack(alignment: .center) {
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button("普段を取り直す") { model.restartBaseline() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!model.running)
            }
            differences
            Spacer(minLength: 0)
            meters
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 「顔：読めています・普段：記録しました」
    private var statusText: String {
        let face = !model.cameraActive ? "顔：–" : model.faceReadable ? "顔：読めています" : "顔：読めません"
        let base: String
        if let sec = model.baselineSec { base = "普段：記録中 \(sec)/\(Int(model.baselineTarget))秒" }
        else if model.baselineReady { base = "普段：記録しました" }
        else { base = "普段：まだありません" }
        return "\(face)・\(base)"
    }

    private var differences: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.running {
                Text("記録が始まると、最初の\(Int(AnalysisModel.selectedBaselineSeconds))秒を「普段」として記録します")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else if let sec = model.baselineSec {
                Text("普段を記録しています").font(.title3.bold()).foregroundStyle(ContentView.navy)
                ProgressView(value: min(Double(sec), model.baselineTarget), total: model.baselineTarget)
                Text(model.baselineWait ?? "落ち着いているときに。顔が映っている間だけ数えます")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if model.differences.isEmpty {
                Text(model.faceReadable ? "いつもと大きな違いはありません" : "声は、いつもと大きな違いはありません")
                    .font(.title3.bold()).foregroundStyle(ContentView.navy)
                    .lineLimit(1).minimumScaleFactor(0.6)
            } else {
                ForEach(Array(model.differences.prefix(Self.maxLines)), id: \.self) {
                    Text($0).font(.title3.bold()).foregroundStyle(ContentView.navy).lineLimit(1).minimumScaleFactor(0.6)
                }
                if model.differences.count > Self.maxLines {
                    Text("ほか\(model.differences.count - Self.maxLines)件").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 見る側の「いま」のメーターを小さくしたもの（2列×3段）。いつもの範囲の帯と今の点、外れたらアンバー
    private var meters: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach([Metric.allCases[row], Metric.allCases[row + 3]], id: \.self) { m in
                        HStack(spacing: 4) {
                            Circle().fill(m.color).frame(width: 6, height: 6)
                            Text(m.label).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: 58, alignment: .leading)
                            MeterTrack(z: model.meterZ[m], hasRange: model.baselineStats?[m] != nil,
                                       outside: model.diffMetrics[m] != nil)
                                .frame(height: 12)
                        }
                        .opacity(m.isFace && !model.faceReadable ? 0.35 : 1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("指標ごとのメーター")
    }
}

/// 2. グラフ：直近の指標ごとの z の線。いつもの範囲（±2）は薄い帯、家族の印・場面は縦線。
/// なぞると縦線がついてきて、その時刻の値といつもの範囲を上に出す（なぞっている間は止める。離すと今に戻る）
struct GraphPage: View {
    @ObservedObject var graph: GraphStore
    @State private var span = 60.0
    @State private var frozen: (samples: [GraphStore.Sample], events: [GraphStore.Event], end: Double)?
    @State private var touchX: CGFloat?

    static let spans: [(Double, String)] = [(20, "20秒"), (60, "1分"), (300, "5分")]
    static let zMax = 4.0

    var body: some View {
        let samples = frozen?.samples ?? graph.samples
        let events = frozen?.events ?? graph.events
        let end = frozen?.end ?? (graph.samples.last?.t ?? 0)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let sel = touchX.flatMap { x in sample(at: end - span + Double(x / max(w, 1)) * span, in: samples) }
                ZStack(alignment: .top) {
                    Canvas { ctx, size in draw(ctx, size, samples: samples, events: events, end: end, sel: sel) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if frozen == nil { frozen = (graph.samples, graph.events, graph.samples.last?.t ?? 0) }
                                touchX = min(max(v.location.x, 0), w)
                            }
                            .onEnded { _ in touchX = nil; frozen = nil })
                    if let sel { readout(sel, end: end).padding(4) }
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
    private func readout(_ s: GraphStore.Sample, end: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Int((end - s.t).rounded()))秒前　（ ）内はいつもの範囲").font(.caption2.bold())
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

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, samples: [GraphStore.Sample], events: [GraphStore.Event],
                      end: Double, sel: GraphStore.Sample?) {
        let w = size.width, h = size.height
        let start = end - span
        let x = { (t: Double) in CGFloat((t - start) / span) * w }
        let y = { (z: Double) in h / 2 - CGFloat(min(max(z, -Self.zMax), Self.zMax) / Self.zMax) * (h / 2 - 2) }

        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(.secondary.opacity(0.05)))
        ctx.fill(Path(CGRect(x: 0, y: y(2), width: w, height: y(-2) - y(2))), with: .color(ContentView.paleSlate))
        ctx.fill(Path(CGRect(x: 0, y: y(0) - 0.25, width: w, height: 0.5)), with: .color(ContentView.navy.opacity(0.25)))

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
            stat("カメラ", model.lensInUse?.label)
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
