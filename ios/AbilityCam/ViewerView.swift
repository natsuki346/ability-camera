import SwiftUI

/// 見る側（Mac の全画面 / iPad）の1画面。「今の値が、いつもの範囲のどこにあるか」と「何が・どちらに・どれだけ続いているか」を出す。
/// 状態の名前や点数は出さない。撮る側から届いたものを出すだけで、何も保存しない（時間の流れもこの端末のメモリだけ）
struct ViewerView: View {
    @StateObject private var link = ViewerLink()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sketchTone") private var sketchTone = SketchTone.medium
    @State private var showSettings = false
    @State private var span = 5 * 60.0      // 時間の流れに出す長さ（1分・5分・15分）

    static let staleSeconds = 2.0
    static let usualBand = Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255)   // いつもの範囲：薄い青灰
    static let amber = Color(red: 0xE6 / 255, green: 0x9F / 255, blue: 0x00 / 255)       // いつもより上
    static let slate = Color(red: 0x5B / 255, green: 0x7F / 255, blue: 0xA6 / 255)       // いつもより下
    static let navy = ContentView.navy                                                  // 今の値

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let connected: Bool = { if case .connected = link.status { return true } else { return false } }()
                let fresh = link.lastReceived.map { ctx.date.timeIntervalSince($0) < Self.staleSeconds } ?? false
                let live = connected && fresh
                let s = live ? link.state : nil
                let video = live && (link.videoAt.map { ctx.date.timeIntervalSince($0) < Self.staleSeconds } ?? false) ? link.video : nil
                // 少し離れた所からも読めるよう、画面の幅に合わせて文字を大きくする
                let k = min(max(geo.size.width / 1300, 0.85), 1.5)
                let wide = geo.size.width >= 1000 && geo.size.width >= geo.size.height
                let sideW = geo.size.width * 0.24
                let sketch = wide
                    ? max(160, min(sideW - 24, geo.size.height * 0.42, 460))
                    : max(150, min((geo.size.width - 32) / (video != nil ? 2.1 : 1.1), geo.size.height * 0.3, 400))

                ZStack(alignment: .top) {
                    ScrollView {
                        VStack(spacing: 14 * k) {
                            topBar(k)
                            if wide {
                                HStack(alignment: .top, spacing: 14 * k) {
                                    left(s, size: sketch, video: video, stacked: true, k).frame(width: sideW)
                                    now(s, live: live, k).frame(maxWidth: .infinity)
                                    right(s, now: ctx.date, k).frame(width: sideW)
                                }
                            } else {
                                left(s, size: sketch, video: video, stacked: false, k)
                                now(s, live: live, k)
                                right(s, now: ctx.date, k)
                            }
                            timeline(live: live, now: ctx.date, k)
                            buttons(s, live: live, k)
                            Text("見る側は何も保存しません（時間の流れも、この端末のメモリにだけ最長15分置きます）。音声・顔の点・記録のファイルは届きません。")
                                .font(.system(size: 12 * k)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                        // 止まっているのを「違いがない」と見間違えないよう、全体を灰色に
                        .grayscale(live ? 0 : 1)
                        .opacity(live ? 1 : 0.45)
                        .padding(.top, live ? 0 : 150)
                    }
                    if !live { notConnected.padding() }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: link.start()       // 起動したら自動で探してつなぐ
            case .background: link.stop()
            default: break
            }
        }
        .onDisappear { link.stop() }
    }

    // MARK: 上

    private func topBar(_ k: CGFloat) -> some View {
        HStack {
            Text("見る側").font(.system(size: 17 * k, weight: .semibold))
            Text(statusText).font(.system(size: 15 * k)).foregroundStyle(.secondary)
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("設定")
        }
    }

    private var statusText: String {
        switch link.status {
        case .searching: "撮る側を探しています"
        case .requesting(let n): "\(n) の画面で、送るかどうかの確認を待っています"
        case .connecting(let n): "\(n) につないでいます"
        case .connected(let n): "\(n) とつながっています"
        case .retrying(let n, let at):
            "\(n) とつなぎ直し中（\(max(0, Int(at.timeIntervalSinceNow.rounded(.up))))秒後にもう一度）"
        case .needsApproval(let n):
            "\(n) で許可が取り消されています。見るには「見たいと申し込む」を押し、撮る側で確かめてもらってください"
        }
    }

    /// 手で申し込むボタンを出すか（探している・取り消されたとき）
    private var showRequestButtons: Bool {
        switch link.status {
        case .searching, .needsApproval: true
        default: false
        }
    }

    private var lastReceivedText: String {
        link.lastReceived.map { "最後に受け取った時刻 \(Self.time($0))" } ?? "まだ受け取っていません"
    }

    /// つながっていない・2秒以上来ないとき。大きく出し、手で申し込む操作もここに置く
    private var notConnected: some View {
        VStack(spacing: 8) {
            Text("つながっていません（\(lastReceivedText)）")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(statusText).font(.callout)
            if showRequestButtons {
                ForEach(link.found, id: \.self) { p in
                    Button("\(p.displayName) に見たいと申し込む") { link.request(p) }
                        .buttonStyle(.bordered)
                }
                if link.found.isEmpty {
                    Text("撮る側でアプリを開いて、同じ Wi‑Fi か Bluetooth の届く所に置いてください").font(.callout)
                }
            }
            if let n = link.notice { Text(n).font(.footnote) }
        }
        .foregroundStyle(Self.navy)
        .frame(maxWidth: 720)
        .padding(20)
        .background(Self.usualBand, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    // MARK: 左：顔の絵・映像・顔の向き

    private func left(_ s: LiveState?, size: CGFloat, video: UIImage?, stacked: Bool, _ k: CGFloat) -> some View {
        VStack(spacing: 10 * k) {
            if stacked {
                sketch(s, size: size)
                if let video { videoView(video, size: size, k) }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    sketch(s, size: size)
                    if let video { videoView(video, size: size, k) }
                }
            }
            VStack(spacing: 4) {
                if let shape = s?.shape, shape["yaw"] != nil {
                    Text("顔の向き：\(FaceSketch.directionText(shape))")
                        .font(.system(size: 20 * k, weight: .semibold)).foregroundStyle(Self.navy)
                    if abs(shape["yaw"] ?? 0) > FaceSketch.sideLimit {
                        Text("横を向いているため表情は参考程度").font(.system(size: 14 * k)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("顔の向き：–").font(.system(size: 20 * k)).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func sketch(_ s: LiveState?, size: CGFloat) -> some View {
        FaceSketch(shape: s?.shape, size: size, tone: sketchTone)   // 撮る側と同じ描き方。読めない・つながっていないときは灰色
            .contextMenu {
                Picker("絵の色", selection: $sketchTone) {
                    ForEach(SketchTone.allCases) { Text($0.rawValue).tag($0) }
                }
            }
    }

    private func videoView(_ video: UIImage, size: CGFloat, _ k: CGFloat) -> some View {
        VStack(spacing: 4) {
            Image(uiImage: video)
                .resizable().scaledToFit()
                .frame(maxWidth: size, maxHeight: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("映像（表示するだけで保存しません）").font(.system(size: 11 * k)).foregroundStyle(.secondary)
        }
    }

    // MARK: 真ん中：いま

    private func now(_ s: LiveState?, live: Bool, _ k: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * k) {
            card(k) {
                VStack(alignment: .leading, spacing: 8 * k) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("いま").font(.system(size: 26 * k, weight: .bold)).foregroundStyle(Self.navy)
                        Spacer()
                        if !live { Text(lastReceivedText).font(.system(size: 14 * k)).foregroundStyle(.secondary) }
                    }
                    groupHeader("表情", reason: faceReason(s), k)
                    ForEach(Metric.allCases.filter(\.isFace), id: \.self) { m in
                        meterRow(m, s, faded: faceReason(s) != nil, k)
                    }
                    groupHeader("声", reason: voiceReason(s), k).padding(.top, 4 * k)
                    ForEach(Metric.allCases.filter { !$0.isFace }, id: \.self) { m in
                        meterRow(m, s, faded: false, k)
                    }
                    meterLegend(k).padding(.top, 2 * k)
                }
            }
            card(k) { differences(s, k) }
        }
    }

    /// 表情のメーターを薄くする理由（nil なら薄くしない）
    private func faceReason(_ s: LiveState?) -> String? {
        guard let s else { return nil }
        if !s.recording { return "記録していません" }
        if !s.baselineReady {
            return "普段を記録中 \(s.baselineSec ?? 0)/\(s.baselineTotal)秒" + (s.baselineWait.map { "（\($0)）" } ?? "")
        }
        if !s.faceReadable { return "顔が読めません（映っていない・動きが大きい）" }
        return nil
    }

    /// 声のメーターは出したまま、範囲がまだ無い理由だけ書く
    private func voiceReason(_ s: LiveState?) -> String? {
        guard let s else { return nil }
        if !s.recording { return "記録していません" }
        if !s.baselineReady { return "普段を記録中のため、いつもの範囲はまだありません" }
        return nil
    }

    private func groupHeader(_ title: String, reason: String?, _ k: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 15 * k, weight: .semibold)).foregroundStyle(.secondary)
            if let reason { Text(reason).font(.system(size: 17 * k, weight: .semibold)).foregroundStyle(Self.navy) }
        }
    }

    /// 指標1本：いつもの範囲（普段の平均 ±2 標準偏差）を薄い青灰の帯、今の値を濃紺の点（範囲の外で違いが出ているときはアンバー）
    private func meterRow(_ m: Metric, _ s: LiveState?, faded: Bool, _ k: CGFloat) -> some View {
        let stat = s?.baselineReady == true ? link.baseline?.metrics[m.rawValue] : nil
        let usable = stat.flatMap { $0.insufficient ? nil : $0 }
        let sd = usable?.std.map { max($0, m.stdFloor) }
        let mean = usable?.mean
        let z = faded ? nil : s?.z?[m.rawValue]
        let diff = faded ? nil : s?.diffs?.first { $0.metric == m.rawValue }

        var status = "", strong = false
        if let diff {
            status = "\(m.directionText(above: diff.above))（\(diff.seconds)秒）"; strong = true
        } else if s == nil || faded || s?.baselineReady != true {
            status = ""
        } else if stat?.insufficient == true {
            status = "データ不足で比べていません"
        } else if mean == nil {
            status = "いつもの範囲が届いていません"
        } else if let z {
            status = z <= -2 ? m.directionText(above: false) : z >= 2 ? m.directionText(above: true) : "いつもの範囲"
        } else {
            status = m == .f0Hz ? "声が出ていない間は出ません" : m == .rmsDb ? "声の値がありません" : "今の値がありません"
        }

        var detail = ""
        if let mean, let sd {
            let b = m.valueBounds
            let lo = min(max(mean - 2 * sd, b.lowerBound), b.upperBound), hi = min(max(mean + 2 * sd, b.lowerBound), b.upperBound)
            detail = "いつもの範囲 \(m.valueText(lo))〜\(m.valueText(hi))"
            if let z { detail += "　今 \(m.valueText(mean + z * sd))" }
        }

        return HStack(alignment: .center, spacing: 12 * k) {
            HStack(spacing: 6) {
                Circle().fill(m.color).frame(width: 10 * k, height: 10 * k)
                Text(m.label).font(.system(size: 19 * k, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 140 * k, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                MeterTrack(z: z, hasRange: mean != nil && sd != nil, outside: diff != nil)
                    .frame(height: 26 * k)
                Text(detail.isEmpty ? " " : detail)
                    .font(.system(size: 12 * k).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(status)
                .font(.system(size: (strong ? 19 : 15) * k, weight: strong ? .bold : .regular).monospacedDigit())
                .foregroundStyle(strong ? Self.navy : .secondary)
                .lineLimit(2).minimumScaleFactor(0.7)
                .frame(width: 210 * k, alignment: .leading)
        }
        .opacity(faded ? 0.35 : 1)
        .accessibilityElement(children: .combine)
    }

    private func meterLegend(_ k: CGFloat) -> some View {
        HStack(spacing: 14 * k) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Self.usualBand).frame(width: 22 * k, height: 10 * k)
                Text("いつもの範囲（普段の平均 ±2 標準偏差）")
            }
            HStack(spacing: 4) { Circle().fill(Self.navy).frame(width: 10 * k, height: 10 * k); Text("今") }
            HStack(spacing: 4) { Circle().fill(Self.amber).frame(width: 10 * k, height: 10 * k); Text("範囲の外（いつもとの違い）") }
        }
        .font(.system(size: 12 * k)).foregroundStyle(.secondary)
    }

    /// いつもとの違いの一覧（大きな文字で、続いている秒数つき）
    private func differences(_ s: LiveState?, _ k: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6 * k) {
            Text("いつもとの違い").font(.system(size: 15 * k, weight: .semibold)).foregroundStyle(.secondary)
            if let s {
                if !s.faceReadable {
                    Text("顔が読めません（映っていない・動きが大きい）").font(.system(size: 20 * k, weight: .semibold))
                }
                if !s.recording || !s.baselineReady {
                    Text("普段を記録し終えると出ます").font(.system(size: 18 * k)).foregroundStyle(.secondary)
                } else if s.differences.isEmpty {
                    Text(s.faceReadable ? "いつもと大きな違いはありません" : "声は、いつもと大きな違いはありません")
                        .font(.system(size: 22 * k))
                } else {
                    ForEach(s.differences, id: \.self) {
                        Text($0).font(.system(size: 28 * k, weight: .bold)).foregroundStyle(Self.navy)
                    }
                }
                if !s.insufficient.isEmpty {
                    Text("データ不足で比べていません：\(s.insufficient.joined(separator: "・"))")
                        .font(.system(size: 13 * k)).foregroundStyle(.secondary)
                }
            } else {
                Text("–").font(.system(size: 22 * k)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 右：記録の状態・つながり・記録の質・違いが出た回数・印と場面

    private func right(_ s: LiveState?, now: Date, _ k: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * k) {
            card(k) { recordState(s, now: now, k) }
            card(k) {
                VStack(alignment: .leading, spacing: 4 * k) {
                    caption("つながり", k)
                    Text("最後に受け取った時刻 \(link.lastReceived.map(Self.time) ?? "–")")
                    Text("撮影→この画面 \(link.latencyMs.map { "\(Int($0.rounded())) ms" } ?? "– ms")")
                }
                .font(.system(size: 15 * k).monospacedDigit())
            }
            card(k) {
                VStack(alignment: .leading, spacing: 6 * k) {
                    caption("記録の質", k)
                    HStack(spacing: 20 * k) {
                        number("顔が映っている割合", s?.faceRatio.map { "\(Int($0 * 100))%" }, k)
                        number("解析コマ/秒", s?.fps.map { String(format: "%.1f", $0) }, k)
                    }
                }
            }
            card(k) {
                number("このセッションで違いが出た回数", s?.diffCount.map { "\($0)回" }, k)
            }
            card(k) { recentEvents(k) }
        }
    }

    private func recordState(_ s: LiveState?, now: Date, _ k: CGFloat) -> some View {
        // 経過時間は撮る側の時計どうしの差で出す（2台の時計のずれが入らない）
        let elapsed: Double? = s?.sessionStartedMs.map { start in
            Double((s?.sentMs ?? start) - start) / 1000 + now.timeIntervalSince(link.lastReceived ?? now)
        }
        return VStack(alignment: .leading, spacing: 6 * k) {
            Label(s?.recording == true ? "記録中 \(elapsed.map(ContentView.duration) ?? "")" : "記録していません",
                  systemImage: s?.recording == true ? "record.circle" : "pause.circle")
                .font(.system(size: 22 * k, weight: .bold)).foregroundStyle(Self.navy)
            if let s, s.recording {
                if let sec = s.baselineSec {
                    Text("普段を記録中 \(sec)/\(s.baselineTotal)秒")
                    ProgressView(value: Double(sec), total: Double(s.baselineTotal)).tint(Self.slate)
                    if let w = s.baselineWait { Text(w).foregroundStyle(.secondary) }
                } else if s.baselineReady {
                    Text("普段を記録しました\(link.baseline.map { "（\(Self.time(ms: $0.tMs))）" } ?? "")")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 15 * k).monospacedDigit())
    }

    /// 直近の家族の印・場面（時刻つき、新しい順）
    private func recentEvents(_ k: CGFloat) -> some View {
        let recent = Array(link.events.suffix(6).reversed())
        return VStack(alignment: .leading, spacing: 4 * k) {
            caption("家族の印・場面（直近）", k)
            if recent.isEmpty {
                Text("まだありません").foregroundStyle(.secondary)
            }
            ForEach(recent) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.time(ms: e.tMs)).monospacedDigit().foregroundStyle(.secondary)
                    Text((e.kind == "mark" ? "家族の印：" : "場面：") + e.value + (e.by.map { "（\($0)で）" } ?? ""))
                        .lineLimit(2)
                }
            }
        }
        .font(.system(size: 15 * k))
    }

    private func caption(_ text: String, _ k: CGFloat) -> some View {
        Text(text).font(.system(size: 13 * k, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func number(_ label: String, _ value: String?, _ k: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "–").font(.system(size: 26 * k, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 13 * k)).foregroundStyle(.secondary)
        }
    }

    private func card<C: View>(_ k: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12 * k)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
    }

    // MARK: 下：時間の流れ

    private func timeline(live: Bool, now: Date, _ k: CGFloat) -> some View {
        // 右端は「今」。届かなくなっても時間は進めて、届いていない間を空白で見せる
        let end: Double = {
            guard let last = link.state?.captureMs, let rec = link.lastReceived else { return now.timeIntervalSince1970 }
            return Double(last) / 1000 + now.timeIntervalSince(rec)
        }()
        return card(k) {
            VStack(alignment: .leading, spacing: 8 * k) {
                HStack(spacing: 14 * k) {
                    Text("時間の流れ").font(.system(size: 20 * k, weight: .bold)).foregroundStyle(Self.navy)
                    Picker("表示する長さ", selection: $span) {
                        Text("1分").tag(60.0)
                        Text("5分").tag(300.0)
                        Text("15分").tag(900.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240 * k)
                    Spacer()
                    if !live { Text(lastReceivedText).font(.system(size: 14 * k)).foregroundStyle(.secondary) }
                }
                TimelineChart(bands: link.bands, scenes: link.scenes,
                              marks: link.events.filter { $0.kind == "mark" },
                              start: end - span, end: end, k: k)
                timelineLegend(k)
            }
        }
    }

    private func timelineLegend(_ k: CGFloat) -> some View {
        let sw = { (c: Color) in RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 20 * k, height: 10 * k) }
        return HStack(spacing: 14 * k) {
            HStack(spacing: 4) { sw(Self.amber.opacity(TimelineChart.fillOpacity)); Text("いつもより上（強い・大きい・高い）") }
            HStack(spacing: 4) { sw(Self.slate.opacity(TimelineChart.fillOpacity)); Text("いつもより下（小さい・低い）") }
            HStack(spacing: 4) { sw(Self.usualBand); Text("いつもの範囲") }
            HStack(spacing: 4) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.08)))
                    var p = Path(), x = -size.height
                    while x < size.width { p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0)); x += 5 }
                    ctx.stroke(p, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                }
                .frame(width: 20 * k, height: 10 * k).clipShape(RoundedRectangle(cornerRadius: 2))
                Text("比べていない・届いていない")
            }
            HStack(spacing: 4) {
                Rectangle().fill(Self.navy).frame(width: 2, height: 12 * k)
                Text("家族の印")
            }
        }
        .font(.system(size: 12 * k)).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.6)
    }

    // MARK: 印と場面のボタン

    private func buttons(_ s: LiveState?, live: Bool, _ k: CGFloat) -> some View {
        VStack(spacing: 8 * k) {
            // 見る側から印と場面を付ける（撮る側の記録に、どの端末で押したかと一緒に残る）
            HStack(spacing: 8) {
                Text("家族の印").font(.system(size: 14 * k)).foregroundStyle(.secondary).frame(minWidth: 90 * k, alignment: .leading)
                ForEach(Mark.allCases) { m in
                    Button { link.sendEvent(kind: "mark", value: m.rawValue) } label: {
                        Text(m.rawValue).font(.system(size: 20 * k, weight: .bold)).frame(maxWidth: .infinity, minHeight: 44 * k)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(m == .pleasant ? .teal : m == .unpleasant ? .indigo : .gray)
                }
            }
            HStack(spacing: 8) {
                Text("場面：\(s?.scene ?? "なし")").font(.system(size: 14 * k)).foregroundStyle(.secondary)
                    .frame(minWidth: 90 * k, alignment: .leading)
                ForEach(CareScene.allCases) { c in
                    let on = s?.scene == c.rawValue
                    Button { link.sendEvent(kind: "scene", value: on ? "なし" : c.rawValue) } label: {
                        Text(c.rawValue).font(.system(size: 16 * k)).lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 34 * k)
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: on ? 2 : 0))
                }
            }
        }
        .disabled(!live || s?.recording != true)
    }

    // MARK: 時刻

    private static let hms: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ d: Date) -> String { hms.string(from: d) }
    static func time(ms: Int64) -> String { time(Date(timeIntervalSince1970: Double(ms) / 1000)) }
}

/// いつもの範囲のメーター。横軸は z（−5〜+5）。±2 の間を薄い青灰の帯にし、今の値を点で置く
struct MeterTrack: View {
    let z: Double?
    let hasRange: Bool
    let outside: Bool          // いつもとの違いとして出ている（点をアンバーにする）

    static let zMax = 5.0

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, mid = h / 2
            let x = { (z: Double) in CGFloat((min(max(z, -Self.zMax), Self.zMax) + Self.zMax) / (2 * Self.zMax)) * w }
            // 軸
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: mid - h * 0.12, width: w, height: h * 0.24), cornerRadius: h * 0.12),
                     with: .color(.secondary.opacity(0.15)))
            if hasRange {
                ctx.fill(Path(roundedRect: CGRect(x: x(-2), y: mid - h * 0.36, width: x(2) - x(-2), height: h * 0.72),
                              cornerRadius: h * 0.2),
                         with: .color(ViewerView.usualBand))
                ctx.fill(Path(CGRect(x: x(0) - 0.75, y: mid - h * 0.36, width: 1.5, height: h * 0.72)),
                         with: .color(ViewerView.navy.opacity(0.25)))   // 普段の平均
            }
            if let z, hasRange {
                let r = h * 0.3
                let c = CGPoint(x: min(max(x(z), r + 1), w - r - 1), y: mid)
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(outside ? ViewerView.amber : ViewerView.navy))
                ctx.stroke(dot, with: .color(.white), lineWidth: 2)
                if abs(z) > Self.zMax {   // 目盛りの外：端に置き、外向きの印を付ける
                    let s: CGFloat = z > 0 ? 1 : -1, tip = c.x + s * (r + 7)
                    var p = Path()
                    p.move(to: CGPoint(x: tip, y: mid))
                    p.addLine(to: CGPoint(x: tip - s * 6, y: mid - 5))
                    p.addLine(to: CGPoint(x: tip - s * 6, y: mid + 5))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(outside ? ViewerView.amber : ViewerView.navy))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 時間の流れ：上から 家族の印・場面・指標6段。範囲の外に出ていた時間を塗る。家族の印は縦線
struct TimelineChart: View {
    let bands: [Metric: [ViewerLink.Run<ViewerLink.Band>]]
    let scenes: [ViewerLink.Run<String>]
    let marks: [LiveEvent]
    let start: Double
    let end: Double
    let k: CGFloat

    static let fillOpacity = 0.7

    var body: some View {
        let rowH = 22 * k, gap = 4 * k, markH = 20 * k, axisH = 18 * k
        let labels = ["家族の印", "場面"] + Metric.allCases.map(\.label)
        let heights = [markH, rowH] + Array(repeating: rowH, count: Metric.allCases.count)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: gap) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                    HStack(spacing: 4) {
                        if i >= 2 { Circle().fill(Metric.allCases[i - 2].color).frame(width: 8 * k, height: 8 * k) }
                        Text(l).font(.system(size: 13 * k)).lineLimit(1)
                    }
                    .frame(height: heights[i])
                }
            }
            .frame(width: 120 * k, alignment: .trailing)
            Canvas { ctx, size in draw(ctx, size: size, rowH: rowH, gap: gap, markH: markH, axisH: axisH) }
                .frame(height: heights.reduce(0, +) + gap * CGFloat(heights.count - 1) + axisH)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("時間の流れ")
    }

    /// 「比べていない・届いていない」の斜線（いつもの範囲の青灰と見分けやすくする）
    private func hatch(_ ctx: GraphicsContext, _ r: CGRect) {
        var c = ctx
        c.clip(to: Path(r))
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 7 * k
        }
        c.stroke(p, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, rowH: CGFloat, gap: CGFloat, markH: CGFloat, axisH: CGFloat) {
        let w = size.width, span = max(end - start, 1)
        let x = { (t: Double) in CGFloat((t - start) / span) * w }
        let sceneY = markH + gap
        let rowY = { (i: Int) in sceneY + rowH + gap + CGFloat(i) * (rowH + gap) }
        let bottom = rowY(Metric.allCases.count) - gap

        func rect(_ r: ViewerLink.Run<some Equatable>, y: CGFloat) -> CGRect? {
            guard r.end >= start, r.start <= end else { return nil }
            let x0 = max(x(r.start), 0), x1 = min(x(r.end), w)
            return CGRect(x: x0, y: y, width: max(x1 - x0, 1.5), height: rowH)   // 短い区間も見えるように
        }

        // 場面の段
        ctx.fill(Path(CGRect(x: 0, y: sceneY, width: w, height: rowH)), with: .color(.secondary.opacity(0.06)))
        for r in scenes {
            guard let rr = rect(r, y: sceneY) else { continue }
            ctx.fill(Path(roundedRect: rr, cornerRadius: 3), with: .color(ViewerView.navy.opacity(0.16)))
            if rr.width > 44 * k {
                var c = ctx
                c.clip(to: Path(rr))
                c.draw(Text(r.value).font(.system(size: 12 * k)).foregroundColor(ViewerView.navy),
                       at: CGPoint(x: rr.minX + 4, y: rr.midY), anchor: .leading)
            }
        }

        // 指標の段：下地は「比べていない・届いていない」の灰色。その上に、いつもの範囲・上・下を塗る
        for (i, m) in Metric.allCases.enumerated() {
            let y = rowY(i)
            ctx.fill(Path(CGRect(x: 0, y: y, width: w, height: rowH)), with: .color(.secondary.opacity(0.08)))
            hatch(ctx, CGRect(x: 0, y: y, width: w, height: rowH))
            for r in bands[m] ?? [] {
                guard let rr = rect(r, y: y) else { continue }
                switch r.value {
                case .usual: ctx.fill(Path(rr), with: .color(ViewerView.usualBand))
                case .above: ctx.fill(Path(rr), with: .color(ViewerView.amber.opacity(Self.fillOpacity)))
                case .below: ctx.fill(Path(rr), with: .color(ViewerView.slate.opacity(Self.fillOpacity)))
                case .notCompared: break
                }
            }
        }

        // 目盛り（撮る側の時計の時刻）
        let step: Double = span <= 60 ? 15 : span <= 300 ? 60 : 180
        var t = (start / step).rounded(.up) * step
        while t <= end {
            let px = x(t)
            ctx.fill(Path(CGRect(x: px - 0.5, y: sceneY, width: 1, height: bottom - sceneY)), with: .color(.secondary.opacity(0.25)))
            let d = Date(timeIntervalSince1970: t)
            let label = span <= 60 ? ViewerView.time(d) : ViewerView.hm.string(from: d)
            if px > 24 * k, px < w - 40 * k {
                ctx.draw(Text(label).font(.system(size: 11 * k).monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: px, y: bottom + 3), anchor: .top)
            }
            t += step
        }
        ctx.draw(Text("今").font(.system(size: 11 * k, weight: .semibold)).foregroundColor(.secondary),
                 at: CGPoint(x: w, y: bottom + 3), anchor: .topTrailing)

        // 家族の印：縦線と、上の段に名前と時刻
        for e in marks {
            let tt = Double(e.tMs) / 1000
            guard tt >= start, tt <= end else { continue }
            let px = x(tt)
            var line = Path()
            line.move(to: CGPoint(x: px, y: markH))
            line.addLine(to: CGPoint(x: px, y: bottom))
            ctx.stroke(line, with: .color(ViewerView.navy), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let label = "\(e.value) \(ViewerView.hm.string(from: Date(timeIntervalSince1970: tt)))"
            ctx.draw(Text(label).font(.system(size: 12 * k, weight: .semibold)).foregroundColor(ViewerView.navy),
                     at: CGPoint(x: px, y: markH / 2), anchor: px > w - 80 * k ? .trailing : .leading)
        }
    }
}
