import SwiftUI

/// 記録のリプレイ（iPhone と Mac・iPad で同じ画面）。読むだけで、印は付けない。
/// 映像は無いので、記録した表情の数値と顔の向きで顔の絵を動かす。下の帯は「カラオケの歌詞」のように右から左へ流れ、
/// 真ん中の縦線が今の位置。研究用の合計は出さない（docs/wording-guide.md）
struct ReplayView: View {
    let data: ReplayData
    @State private var pos: Double
    @State private var playing = false
    @State private var speed = 1.0
    @State private var span = 60.0              // 帯に出す長さ（秒）
    @AppStorage("sketchTone") private var sketchTone = SketchTone.medium

    static let speeds = [1.0, 2.0, 4.0]
    static let spans: [(Double, String)] = [(30, "30秒"), (60, "1分"), (300, "5分")]

    init(data: ReplayData) {
        self.data = data
        _pos = State(initialValue: data.startT)
    }

    private var endT: Double { max(data.endT, data.startT + 1) }
    private var current: ReplayEvent? { data.events.last { $0.t <= pos + 0.05 } }
    private var next: ReplayEvent? { data.events.first { $0.t > pos + 0.05 } }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if wide {
                        HStack(alignment: .center, spacing: 24) {
                            sketch(size: min(260, geo.size.height * 0.35))
                            lyrics(large: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        sketch(size: min(130, geo.size.width * 0.4)).frame(maxWidth: .infinity)
                    }
                    ReplayTimeline(data: data, pos: pos, span: span)
                    if !wide { lyrics(large: false) }
                    controls
                    explanation
                }
                .padding()
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("リプレイ")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playing) { await play() }
    }

    // MARK: 上

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RecordRow.date.string(from: Date(timeIntervalSince1970: data.startT))).font(.headline)
            Text(["長さ \(ContentView.duration(data.durationS))",
                  "顔 \(data.faceRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")",
                  "違い \(data.diffCount)回", "家族の印 \(data.markCount)",
                  data.camera.map { "カメラ \($0)" }].compactMap { $0 }.joined(separator: "・"))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            ForEach(data.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var explanation: some View {
        Text("映像は記録していません。記録した表情の数値と顔の向きで絵を動かしています。いつもとの違いは、記録の普段と撮る側と同じ決まりで計算し直したものです（読むだけで、印は付けません）")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: 顔の絵

    private func sketch(size: CGFloat) -> some View {
        let shape = data.shape(at: pos)
        let s = FaceSketch(shape: shape, size: size, tone: sketchTone)
        let recorded = data.index(at: pos).map { pos - data.times[$0] <= 1 } ?? false
        return VStack(spacing: 6) {
            s
            Group {
                if !recorded {
                    Text("記録が無い時間（カメラが止まっていた）")
                } else if let shape {
                    Text(s.turnedAway ? "横を向いているため表情は参考程度"
                         : shape["yaw"] != nil ? "顔の向き：\(FaceSketch.directionText(shape))" : " ")
                } else {
                    Text("顔が読めません")
                }
            }
            .font(.callout).foregroundStyle(shape == nil ? .secondary : ContentView.navy)
            .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // MARK: 今の出来事（大きく）と、次に来る出来事（薄く）

    private func lyrics(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = current {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.time(e.t)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(e.text)
                        .font(large ? .largeTitle.bold() : .title2.bold())
                        .foregroundStyle(ContentView.navy)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("まだ出来事はありません").font(large ? .title.bold() : .title3.bold()).foregroundStyle(.secondary)
            }
            if let n = next {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.time(n.t)).font(.caption.monospacedDigit())
                    Text(n.text).font(large ? .title3 : .body)
                }
                .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, minHeight: large ? 120 : 84, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    // MARK: 操作

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(Self.time(pos)).monospacedDigit().font(.callout.bold())
                Spacer()
                Text("\(ContentView.duration(pos - data.startT)) / \(ContentView.duration(endT - data.startT))")
                    .monospacedDigit().font(.callout).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { pos }, set: { pos = min(max($0, data.startT), endT) }), in: data.startT...endT)
                .accessibilityLabel("時刻")
            HStack(spacing: 16) {
                Button { jump(back: true) } label: { Label("前の出来事", systemImage: "backward.end.fill") }
                    .disabled(data.events.last { $0.t < pos - 0.5 } == nil)
                Button {
                    if !playing && pos >= endT { pos = data.startT }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.title).frame(width: 56, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(ContentView.navy)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(playing ? "一時停止" : "再生")
                Button { jump(back: false) } label: { Label("次の出来事", systemImage: "forward.end.fill") }
                    .disabled(next == nil)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            HStack {
                Picker("速さ", selection: $speed) {
                    ForEach(Self.speeds, id: \.self) { Text("\(Int($0))倍").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("帯の長さ", selection: $span) {
                    ForEach(Self.spans, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func jump(back: Bool) {
        let e = back ? data.events.last { $0.t < pos - 0.5 } : next
        if let e { pos = e.t }
    }

    private func play() async {
        guard playing else { return }
        var last = Date()
        while playing && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            let now = Date()
            pos = min(pos + now.timeIntervalSince(last) * speed, endT)
            last = now
            if pos >= endT { playing = false }
        }
    }

    static func time(_ t: Double) -> String { ViewerView.time(Date(timeIntervalSince1970: t)) }
}

/// 流れる時間の帯。真ん中の縦線（今の位置）は動かず、帯が右から左へ流れる。
/// 段は上から 場面・家族の印・いつもとの違い・顔の向き
struct ReplayTimeline: View {
    let data: ReplayData
    let pos: Double
    let span: Double

    private static let laneH: CGFloat = 26
    private static let diffRowH: CGFloat = 8
    private static let gap: CGFloat = 4
    private static let labels = ["場面", "家族の印", "いつもとの違い", "顔の向き"]
    private var heights: [CGFloat] { [Self.laneH, Self.laneH, Self.diffRowH * CGFloat(DiffTarget.all.count), Self.laneH] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: Self.gap) {
                    ForEach(Array(Self.labels.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.caption2).lineLimit(1).minimumScaleFactor(0.7).frame(height: heights[i])
                    }
                }
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 18)
                Canvas { ctx, size in draw(ctx, size) }
                    .frame(height: 18 + heights.reduce(0, +) + Self.gap * 3 + 16)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text("いつもとの違いの段は、上から \(DiffTarget.all.map(\.label).joined(separator: "・"))。アンバー＝いつもより強い・大きい・高い、青灰＝いつもより小さい・低い、墨紫＝目を閉じていた。斜線は普段が無く比べていない時間")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("時間の帯")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width
        let x = { (t: Double) in w / 2 + CGFloat((t - pos) / span) * w }
        let t0 = pos - span / 2, t1 = pos + span / 2
        let top: CGFloat = 18
        var ys: [CGFloat] = []
        var y = top
        for h in heights { ys.append(y); y += h + Self.gap }
        let bottom = y - Self.gap
        func visible(_ a: Double, _ b: Double) -> CGRect? {
            guard b >= t0, a <= t1 else { return nil }
            let x0 = max(x(a), 0), x1 = min(x(b), w)
            return CGRect(x: x0, y: 0, width: max(x1 - x0, 2), height: 0)
        }
        func label(_ s: String, in r: CGRect, color: Color) {
            guard r.width > 40 else { return }
            var c = ctx
            c.clip(to: Path(r))
            c.draw(Text(s).font(.caption2).foregroundColor(color), at: CGPoint(x: r.minX + 4, y: r.midY), anchor: .leading)
        }

        // 下地と、記録が無い時間（始まりより前・終わりより後）
        for (i, h) in heights.enumerated() {
            ctx.fill(Path(CGRect(x: 0, y: ys[i], width: w, height: h)), with: .color(.secondary.opacity(0.07)))
        }
        for (a, b) in [(t0, data.startT), (data.endT, t1)] where b > a {
            ctx.fill(Path(CGRect(x: x(a), y: top, width: x(b) - x(a), height: bottom - top)), with: .color(.secondary.opacity(0.12)))
        }

        // 場面
        for r in data.scenes {
            guard var rr = visible(r.start, r.end) else { continue }
            rr.origin.y = ys[0]; rr.size.height = heights[0]
            ctx.fill(Path(roundedRect: rr, cornerRadius: 3), with: .color(ViewerView.navy.opacity(0.16)))
            label(r.value, in: rr, color: ViewerView.navy)
        }

        // いつもとの違い：普段が無い時間は斜線。指標ごとに細い段
        for r in data.noBaseline {
            guard var rr = visible(r.start, r.end) else { continue }
            rr.origin.y = ys[2]; rr.size.height = heights[2]
            hatch(ctx, rr)
        }
        for s in data.segments {
            guard var rr = visible(s.startT, s.endT), let i = DiffTarget.all.firstIndex(of: s.target) else { continue }
            rr.origin.y = ys[2] + CGFloat(i) * Self.diffRowH + 1; rr.size.height = Self.diffRowH - 2
            let color = s.target == .eyesClosed ? DiffTarget.eyesClosedColor : s.above ? ViewerView.amber : ViewerView.slate
            ctx.fill(Path(roundedRect: rr, cornerRadius: 2), with: .color(color.opacity(TimelineChart.fillOpacity)))
        }

        // 顔の向き
        for r in data.heads {
            guard var rr = visible(r.start, r.end) else { continue }
            rr.origin.y = ys[3]; rr.size.height = heights[3]
            ctx.fill(Path(rr), with: .color(r.value.color))
            if r.value != .oblique { label(r.value.label, in: rr, color: r.value == .front ? ViewerView.navy : .white) }
        }

        // 家族の印：縦線と名前（近すぎて重なる名前は出さない）
        var lastLabelX = -CGFloat.infinity
        for e in data.marks where e.t >= t0 && e.t <= t1 {
            let px = x(e.t)
            var line = Path()
            line.move(to: CGPoint(x: px, y: ys[1]))
            line.addLine(to: CGPoint(x: px, y: bottom))
            ctx.stroke(line, with: .color(ViewerView.navy.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let name = e.text.replacingOccurrences(of: "家族の印：", with: "")
            guard px - lastLabelX > 56 else { continue }
            lastLabelX = px
            ctx.draw(Text(name).font(.caption2.weight(.semibold)).foregroundColor(ViewerView.navy),
                     at: CGPoint(x: px + 3, y: ys[1] + heights[1] / 2), anchor: .leading)
        }

        // 目盛り
        let step: Double = span <= 30 ? 5 : span <= 60 ? 15 : 60
        var t = (t0 / step).rounded(.up) * step
        while t <= t1 {
            let px = x(t)
            ctx.fill(Path(CGRect(x: px - 0.25, y: top, width: 0.5, height: bottom - top)), with: .color(.secondary.opacity(0.25)))
            if abs(px - w / 2) > 40 {
                ctx.draw(Text(ViewerView.time(Date(timeIntervalSince1970: t))).font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: px, y: bottom + 2), anchor: .top)
            }
            t += step
        }

        // 今の位置（動かない）
        ctx.fill(Path(CGRect(x: w / 2 - 1, y: top - 4, width: 2, height: bottom - top + 8)), with: .color(ViewerView.navy))
        ctx.draw(Text(ReplayView.time(pos)).font(.caption2.monospacedDigit().weight(.semibold)).foregroundColor(ViewerView.navy),
                 at: CGPoint(x: w / 2, y: 0), anchor: .top)
    }

    private func hatch(_ ctx: GraphicsContext, _ r: CGRect) {
        var c = ctx
        c.clip(to: Path(r))
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 7
        }
        c.stroke(p, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
    }
}
