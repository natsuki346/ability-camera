import Charts
import SwiftUI

/// 見る側（Mac / iPad）の1画面。撮る側から届いた状態を出すだけで、何も保存しない（グラフ用の60秒もメモリだけ）
struct ViewerView: View {
    @StateObject private var link = ViewerLink()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sketchTone") private var sketchTone = SketchTone.medium
    @State private var showSettings = false

    static let staleSeconds = 2.0
    private static let band = Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255)   // 薄い青灰
    private static let seriesNames = Metric.allCases.map(\.label)
    private static let seriesColors = Metric.allCases.map(\.color)

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let connected: Bool = { if case .connected = link.status { return true } else { return false } }()
                let fresh = link.lastReceived.map { ctx.date.timeIntervalSince($0) < Self.staleSeconds } ?? false
                let live = connected && fresh
                let s = live ? link.state : nil
                let videoOn = live && (link.videoAt.map { ctx.date.timeIntervalSince($0) < Self.staleSeconds } ?? false)
                let wide = geo.size.width >= geo.size.height && geo.size.width >= 700
                let rightW = wide ? min(400, geo.size.width * 0.36) : geo.size.width - 32
                let leftW = wide ? geo.size.width - rightW - 48 : geo.size.width - 32
                let sketchSize = max(160, min(leftW / (videoOn ? 2.1 : 1.1), geo.size.height * (wide ? 0.55 : 0.36), 440))

                ZStack(alignment: .top) {
                    ScrollView {
                        VStack(spacing: 12) {
                            topBar
                            if wide {
                                HStack(alignment: .top, spacing: 16) {
                                    face(s, size: sketchSize, video: videoOn ? link.video : nil).frame(maxWidth: .infinity)
                                    right(s, now: ctx.date).frame(width: rightW)
                                }
                            } else {
                                face(s, size: sketchSize, video: videoOn ? link.video : nil)
                                right(s, now: ctx.date)
                            }
                            bottom(s, live: live)
                            Text("見る側は何も保存しません（グラフの60秒もこの端末のメモリにだけ置きます）。音声・顔の点・記録のファイルは届きません。")
                                .font(.caption).foregroundStyle(.secondary)
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

    private var topBar: some View {
        HStack {
            Text("見る側").font(.headline)
            Text(statusText).font(.callout).foregroundStyle(.secondary)
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
        }
    }

    /// つながっていない・2秒以上来ないとき。大きく出し、手で申し込む操作もここに置く
    private var notConnected: some View {
        let last = link.lastReceived.map { "最後に受け取った時刻 \(Self.time($0))" } ?? "まだ受け取っていません"
        return VStack(spacing: 8) {
            Text("つながっていません（\(last)）")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(statusText).font(.callout)
            if case .searching = link.status {
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
        .foregroundStyle(ContentView.navy)
        .frame(maxWidth: 720)
        .padding(20)
        .background(Self.band, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    // MARK: 左：顔の絵（と映像）

    private func face(_ s: LiveState?, size: CGFloat, video: UIImage?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            FaceSketch(shape: s?.shape, size: size, tone: sketchTone)   // 撮る側と同じ描き方。読めない・つながっていないときは灰色
                .contextMenu {
                    Picker("絵の色", selection: $sketchTone) {
                        ForEach(SketchTone.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            if let video {
                VStack(spacing: 4) {
                    Image(uiImage: video)
                        .resizable().scaledToFit()
                        .frame(maxWidth: size, maxHeight: size)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("映像（表示するだけで保存しません）").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 右

    private func right(_ s: LiveState?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            card { recordState(s, now: now) }
            card { differences(s) }
            card { quality(s) }
        }
    }

    /// 右上：記録の状態とつながりの状態
    private func recordState(_ s: LiveState?, now: Date) -> some View {
        // 経過時間は撮る側の時計どうしの差で出す（2台の時計のずれが入らない）
        let elapsed: Double? = s?.sessionStartedMs.map { start in
            Double((s?.sentMs ?? start) - start) / 1000 + now.timeIntervalSince(link.lastReceived ?? now)
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label(s?.recording == true ? "記録中 \(elapsed.map(ContentView.duration) ?? "")" : "記録していません",
                  systemImage: s?.recording == true ? "record.circle" : "pause.circle")
                .font(.title3.bold()).foregroundStyle(ContentView.navy).monospacedDigit()
            if let s, s.recording {
                if let sec = s.baselineSec {
                    Text("普段を記録中 \(sec)/\(s.baselineTotal)秒")
                    ProgressView(value: Double(sec), total: Double(s.baselineTotal))
                    if let w = s.baselineWait { Text(w).font(.callout).foregroundStyle(.secondary) }
                } else if s.baselineReady {
                    Text("普段を記録しました").font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("最後に受け取った時刻 \(link.lastReceived.map(Self.time) ?? "–")")
            Text("撮影→この画面 \(link.latencyMs.map { "\(Int($0.rounded())) ms" } ?? "– ms")")
        }
        .font(.callout).monospacedDigit()
    }

    /// 右中：いつもとの違い、顔の向き、顔が読めません
    private func differences(_ s: LiveState?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("いつもとの違い").font(.caption).foregroundStyle(.secondary)
            if let s {
                if !s.faceReadable {
                    Text("顔が読めません（映っていない・動きが大きい）").font(.title3.bold())
                }
                if !s.recording || !s.baselineReady {
                    Text("普段を記録し終えると出ます").foregroundStyle(.secondary)
                } else if s.differences.isEmpty {
                    Text(s.faceReadable ? "いつもと大きな違いはありません" : "声は、いつもと大きな違いはありません")
                } else {
                    ForEach(s.differences, id: \.self) { Text($0).font(.title3.bold()) }
                }
                if !s.insufficient.isEmpty {
                    Text("データ不足で比べていません：\(s.insufficient.joined(separator: "・"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let shape = s.shape {
                    Divider()
                    Text(shape["yaw"] != nil ? "顔の向き：\(FaceSketch.directionText(shape))" : "顔の向き：–")
                    if abs(shape["yaw"] ?? 0) > FaceSketch.sideLimit {
                        Text("横を向いているため表情は参考程度").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        }
    }

    /// 右下：記録の質
    private func quality(_ s: LiveState?) -> some View {
        HStack(spacing: 20) {
            number("顔が映っている割合", s?.faceRatio.map { "\(Int($0 * 100))%" })
            number("解析コマ/秒", s?.fps.map { String(format: "%.1f", $0) })
        }
    }

    private func number(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "–").font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    // MARK: 下：直近60秒のグラフと、印・場面

    private func bottom(_ s: LiveState?, live: Bool) -> some View {
        let end = Double(link.state?.captureMs ?? 0) / 1000
        let start = end - ViewerLink.chartWindow
        return VStack(alignment: .leading, spacing: 8) {
            Text("直近60秒（縦線は家族の印・場面）").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(link.points) { p in
                    LineMark(x: .value("秒", p.t - end), y: .value("値", p.value), series: .value("指標", p.series))
                        .foregroundStyle(by: .value("指標", p.series))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(link.events.filter { Double($0.tMs) / 1000 >= start }) { e in
                    RuleMark(x: .value("秒", Double(e.tMs) / 1000 - end))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(e.kind == "mark" ? "家族の印" : "場面")：\(e.value) \(Self.time(ms: e.tMs))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartForegroundStyleScale(domain: Self.seriesNames, range: Self.seriesColors)
            .chartXScale(domain: -ViewerLink.chartWindow...0)
            .chartYScale(domain: 0...1)
            .chartXAxis { AxisMarks(values: [-60, -45, -30, -15, 0]) { v in
                AxisGridLine()
                AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))秒") }
            } }
            .frame(height: 180)

            // 見る側から印と場面を付ける（撮る側の記録に、どの端末で押したかと一緒に残る）
            HStack(spacing: 8) {
                Text("家族の印").font(.caption).foregroundStyle(.secondary)
                ForEach(Mark.allCases) { m in
                    Button { link.sendEvent(kind: "mark", value: m.rawValue) } label: {
                        Text(m.rawValue).font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(m == .pleasant ? .teal : m == .unpleasant ? .indigo : .gray)
                }
            }
            HStack(spacing: 8) {
                Text("場面：\(s?.scene ?? "なし")").font(.caption).foregroundStyle(.secondary).frame(minWidth: 90, alignment: .leading)
                ForEach(CareScene.allCases) { c in
                    let on = s?.scene == c.rawValue
                    Button { link.sendEvent(kind: "scene", value: on ? "なし" : c.rawValue) } label: {
                        Text(c.rawValue).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: on ? 2 : 0))
                }
            }
        }
        .disabled(!live || s?.recording != true)
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private static func time(ms: Int64) -> String { time(Date(timeIntervalSince1970: Double(ms) / 1000)) }
}
