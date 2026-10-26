import SwiftUI

/// 見る側（iPad / Mac）。撮る側から届いた状態を出すだけで、何も保存しない
struct ViewerView: View {
    @StateObject private var link = ViewerLink()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sketchTone") private var sketchTone = SketchTone.medium
    @State private var showSettings = false

    static let staleSeconds = 2.0
    private static let band = Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255)   // 薄い青灰

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let connected: Bool = { if case .connected = link.status { return true } else { return false } }()
            let fresh = link.lastReceived.map { ctx.date.timeIntervalSince($0) < Self.staleSeconds } ?? false
            let live = connected && fresh
            let s = live ? link.state : nil

            ScrollView {
                VStack(spacing: 16) {
                    header
                    if !live { notConnected }
                    sketch(s)
                    VStack(alignment: .leading, spacing: 12) {
                        if let s { differences(s); recording(s, now: ctx.date) }
                        events
                        connection
                        Text("見る側は何も保存しません。届くのは顔の絵を動かす数値・顔の向き・いつもとの違い・記録の状態・家族の印と場面だけで、映像・音声・顔の点は届きません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 560)
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: link.start()
            case .background: link.stop()
            default: break
            }
        }
        .onDisappear { link.stop() }
    }

    private var header: some View {
        HStack {
            Text("見る側").font(.headline)
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("設定")
        }
        .frame(maxWidth: 560)
    }

    /// 止まっているのを「違いがない」と見間違えないよう、大きく出す
    private var notConnected: some View {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let last = link.lastReceived.map { "最後に受け取った時刻 \(f.string(from: $0))" } ?? "まだ受け取っていません"
        return Text("つながっていません（\(last)）")
            .font(.title2.bold())
            .foregroundStyle(ContentView.navy)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 560)
            .padding(16)
            .background(Self.band, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 撮る側と同じ描き方。つながっていない・読めないときは灰色・中立
    private func sketch(_ s: LiveState?) -> some View {
        let shape = s?.shape
        let sketch = FaceSketch(shape: shape, size: 300, tone: sketchTone)
        return VStack(spacing: 4) {
            sketch
                .contextMenu {
                    Picker("絵の色", selection: $sketchTone) {
                        ForEach(SketchTone.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            if let shape {
                Text(shape["yaw"] != nil ? "顔の向き：\(FaceSketch.directionText(shape))" : " ").font(.callout)
                if sketch.turnedAway {
                    Text("横を向いているため表情は参考程度").font(.caption).foregroundStyle(.secondary)
                }
            } else if s != nil {
                Text("読めません").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(" ").font(.callout)
            }
        }
    }

    private func differences(_ s: LiveState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("いつもとの違い").font(.caption).foregroundStyle(.secondary)
            if !s.faceReadable {
                Text("顔が読めません（映っていない・動きが大きい）").foregroundStyle(.secondary)
            }
            if !s.recording {
                Text("記録の準備中です").foregroundStyle(.secondary)
            } else if let sec = s.baselineSec {
                Text("普段を記録中 \(sec)/\(s.baselineTotal)秒")
                ProgressView(value: Double(sec), total: Double(s.baselineTotal))
                if let w = s.baselineWait { Text(w).foregroundStyle(.secondary) }
            } else if s.baselineReady {
                if s.differences.isEmpty {
                    Text(s.faceReadable ? "いつもと大きな違いはありません" : "声は、いつもと大きな違いはありません")
                } else {
                    ForEach(s.differences, id: \.self) { Text($0).font(.title3.bold()) }
                }
                if !s.insufficient.isEmpty {
                    Text("データ不足で比べていません：\(s.insufficient.joined(separator: "・"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    private func recording(_ s: LiveState, now: Date) -> some View {
        // 経過時間は撮る側の時計どうしの差で出す（2台の時計のずれが入らない）
        let elapsed: Double? = s.sessionStartedMs.map {
            Double(s.sentMs - $0) / 1000 + now.timeIntervalSince(link.lastReceived ?? now)
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(s.recording ? "記録中 \(elapsed.map(ContentView.duration) ?? "")" : "記録していません",
                      systemImage: s.recording ? "record.circle" : "pause.circle")
                    .font(.callout.bold()).foregroundStyle(ContentView.navy).monospacedDigit()
                Spacer()
            }
            HStack(spacing: 16) {
                Text("顔が映っている割合 \(s.faceRatio.map { "\(Int($0 * 100))%" } ?? "–")")
                Text("解析コマ/秒 \(s.fps.map { String(format: "%.1f", $0) } ?? "–")")
                Text("撮影→この画面 \(link.latencyMs.map { "\(Int($0.rounded())) ms" } ?? "– ms")")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(10)
        .background(Self.band.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !link.events.isEmpty {
                Text("家族の印・場面（直近）").font(.caption).foregroundStyle(.secondary)
                ForEach(link.events) { e in
                    Text("\(e.kind == "mark" ? "家族の印" : "場面")：\(e.value)（\(Self.time(e.tMs))）").font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("つなぐ相手").font(.caption).foregroundStyle(.secondary)
            switch link.status {
            case .connected(let name):
                HStack {
                    Text("\(name) を見ています")
                    Spacer()
                    Button("やめる") { link.leave() }.buttonStyle(.bordered)
                }
            case .requesting(let name):
                HStack {
                    ProgressView()
                    Text("\(name) の画面で、送るかどうかの確認を待っています")
                }
            case .idle:
                if link.found.isEmpty {
                    Text("近くに撮る側が見つかりません（撮る側でアプリを開いて、同じ Wi‑Fi か Bluetooth の届く所に）")
                        .foregroundStyle(.secondary)
                }
                ForEach(link.found, id: \.self) { p in
                    HStack {
                        Text(p.displayName)
                        Spacer()
                        Button("見たいと申し込む") { link.request(p) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            if let n = link.notice { Text(n).font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    private static func time(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
