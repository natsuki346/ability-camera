import AVFoundation
import Charts
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AnalysisModel()
    @State private var cameraLarge = false
    @AppStorage("sketchTone") private var sketchTone = SketchTone.medium
    @AppStorage("cameraLens") private var cameraLens = CameraLens.wide.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    private let series = ["口角を上げる", "眉を寄せる", "目を細める", "口を開ける", "音量", "声の高さ"]
    private let colors: [Color] = [Metric.mouthSmile, .browDown, .eyeSquint, .jawOpen, .rmsDb, .f0Hz].map(\.color)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    recordingBanner
                    Button { showSettings = true } label: { Image(systemName: "gearshape").padding(10) }
                        .accessibilityLabel("設定")
                }
                ViewersBar(link: model.link)

                ZStack(alignment: .topTrailing) {
                    faceSketch
                        .padding(.top, 140)   // 右上の小さな映像と重ならないように
                        .opacity(cameraLarge ? 0 : 1)
                    camera
                }

                differencesCard
                marks
                scenes

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 8) {
                    stat("顔が映っている割合", model.faceRatio.map { "\(Int($0 * 100))%" })
                    stat("解析コマ/秒", model.fps.map { String(format: "%.1f", $0) })
                    stat("解析時間 ms", model.procMs.map { String(format: "%.0f", $0) })
                    stat("撮影→結果 ms", model.latMs.map { String(format: "%.0f", $0) })
                    stat("撮影→網目 ms", model.meshLagMs.map { String(format: "%.0f", $0) })
                    stat("音量 dB", model.rmsDb.map { String(format: "%.0f", $0) })
                    stat("声の高さ Hz", model.f0Hz.map { String(format: "%.0f", $0) })
                    stat("カメラ", model.lensInUse?.label)
                }

                Chart(model.points) { p in
                    LineMark(x: .value("秒", p.t), y: .value("値", p.value), series: .value("系列", p.series))
                        .foregroundStyle(by: .value("系列", p.series))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartForegroundStyleScale(domain: series, range: colors)
                .chartYScale(domain: 0...1)
                .chartXAxis(.hidden)
                .frame(height: 200)

                sessionList

                Text(model.status).font(.footnote).foregroundStyle(.secondary)
                Text("映像と音声は保存せず、この端末の中でその場で解析します。記録（JSONL）は「ファイル」アプリ > このiPhone内 > Ability Cam に保存されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .sheet(isPresented: $showSettings) { SettingsView(link: model.link) }
        .onChange(of: cameraLens) { model.applyLens() }   // 設定で広角／超広角を変えた
        .onDisappear { model.shutdown() }   // 役割を「見る側」に変えた
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: Task { await model.appBecameActive() }   // 開いたら記録（新しいセッション、5秒以内なら同じセッション）
            case .background: model.appEnteredBackground()          // 裏に回ったら止めて、整理する
            default: break
            }
        }
    }

    /// いつも出す：記録中かどうかと経過時間
    private var recordingBanner: some View {
        Group {
            if model.running, let since = model.sessionStartedAt {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Label("記録中 \(Self.duration(ctx.date.timeIntervalSince(since)))", systemImage: "record.circle")
                        .monospacedDigit()
                }
            } else {
                Label("記録の準備中…", systemImage: "hourglass")
            }
        }
        .font(.callout.bold())
        .foregroundStyle(Self.navy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255), in: RoundedRectangle(cornerRadius: 8))   // 薄い青灰
    }

    /// これまでの記録（新しい順）
    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("これまでの記録").font(.caption).foregroundStyle(.secondary)
            if model.sessions.isEmpty {
                Text("まだありません（アプリを閉じると、ここに足されます）").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.sessions.prefix(100)) { s in
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.dateText(s.startedMs)).monospacedDigit()
                    Spacer()
                    Text(Self.duration(s.durationS)).monospacedDigit()
                    Text("顔 \(s.faceRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")").monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                    Text("区間 \(s.segments)").monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .font(.callout)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    static let navy = Color(red: 0x1F / 255, green: 0x3A / 255, blue: 0x5F / 255)   // 濃紺

    static func duration(_ s: Double) -> String {
        let n = Int(s.rounded())
        if n >= 3600 { return "\(n / 3600)時間\(String(format: "%02d", n / 60 % 60))分" }
        return n >= 60 ? "\(n / 60)分\(String(format: "%02d", n % 60))秒" : "\(n)秒"
    }

    static func dateText(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// いつもとの違い（普段の記録中は進み具合）。状態の名前は出さない
    private var differencesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("いつもとの違い").font(.caption).foregroundStyle(.secondary)
            if !model.running {
                Text("記録が始まると、最初の60秒を「普段」として記録します").foregroundStyle(.secondary)
            } else {
                if !model.faceReadable {
                    Text("顔が読めません（映っていない・動きが大きい）").foregroundStyle(.secondary)
                }
                if let sec = model.baselineSec {
                    Text("普段を記録中 \(sec)/\(Int(AnalysisModel.baselineSeconds))秒（落ち着いているときに）")
                    ProgressView(value: Double(sec), total: AnalysisModel.baselineSeconds)
                    if let wait = model.baselineWait {
                        Text(wait).foregroundStyle(.secondary)
                    } else {
                        Text("顔が映っていて、横を向きすぎていない間だけ数えます").font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.baselineReady {
                    if model.differences.isEmpty {
                        Text(model.faceReadable ? "いつもと大きな違いはありません" : "声は、いつもと大きな違いはありません")
                    } else {
                        ForEach(model.differences, id: \.self) { Text($0).bold() }
                    }
                    if !model.insufficient.isEmpty {
                        Text("データ不足で比べていません：\(model.insufficient.map(\.label).joined(separator: "・"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("普段を取り直す") { model.restartBaseline() }
                .buttonStyle(.bordered)
                .disabled(!model.running)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    /// カメラ映像（網目つき）。普段は右上に小さく（幅の1/3）、タップで大きく、もう一度タップで戻る
    private var camera: some View {
        CameraPreview(session: model.camera.session, fill: !cameraLarge)
            .overlay {
                // 網目は解析の遅れの分だけ映像より遅れて見える（即時性そのものなので、隠さない）
                if model.meshEnabled, let mesh = model.mesh { MeshOverlay(mesh: mesh, fill: !cameraLarge) }
            }
            .overlay(alignment: .topTrailing) {
                if cameraLarge {
                    Button { model.meshEnabled.toggle() } label: {
                        Label("網目", systemImage: model.meshEnabled ? "circle.grid.cross.fill" : "circle.grid.cross")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.meshEnabled ? .white : .gray)
                    .padding(6)
                }
            }
            .aspectRatio(cameraLarge ? 9.0 / 16.0 : 3.0 / 4.0, contentMode: .fit)
            .containerRelativeFrame(.horizontal) { w, _ in cameraLarge ? w - 32 : w / 3 }   // 32 = 左右の余白
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { cameraLarge.toggle() } }
    }

    /// 動きを写す顔の絵（映像と同じ見え方・同じ向き）。読めないときは灰色で中立
    private var faceSketch: some View {
        let shape = model.cameraActive ? model.faceShape : nil
        let sketch = FaceSketch(shape: shape, size: 220, tone: sketchTone)
        return VStack(spacing: 4) {
            sketch
                .contextMenu {   // 長押しで絵の色を選ぶ
                    Picker("絵の色", selection: $sketchTone) {
                        ForEach(SketchTone.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            if !model.cameraActive {
                Text(" ").font(.callout)
            } else if let shape {
                Text(shape["yaw"] != nil ? "顔の向き：\(FaceSketch.directionText(shape))" : " ").font(.callout)
                if sketch.turnedAway {
                    Text("横を向いているため表情は参考程度").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("読めません").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 家族の印。介助しながら片手で押せる大きさ
    private var marks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("家族の印").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Mark.allCases) { m in
                    Button { model.tapMark(m) } label: {
                        Text(m.rawValue)
                            .font(.title2.bold())
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(m == .pleasant ? .teal : m == .unpleasant ? .indigo : .gray)
                }
            }
            .disabled(!model.running)
            Text(model.markMessage ?? " ").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// 場面。同時に一つだけ。もう一度押すと「場面なし」
    private var scenes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("場面：\(model.scene?.rawValue ?? "なし")").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                ForEach(CareScene.allCases) { s in
                    Button { model.tapScene(s) } label: {
                        Text(s.rawValue).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.scene == s ? .accentColor : .secondary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: model.scene == s ? 2 : 0))
                }
            }
            .disabled(!model.running)
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "–").font(.title3.monospacedDigit()).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }
}

/// 見ている端末（だれが見ているか）と、見たいという申し込みの確認
struct ViewersBar: View {
    @ObservedObject var link: CameraLink
    @AppStorage("sendVideo") private var sendVideo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sendVideo {   // オンのあいだは必ず出す
                Label(link.viewers.isEmpty ? "映像を送る設定です（今は見ている端末がありません）" : "映像を送っています",
                      systemImage: "video")
                    .font(.callout.bold())
                    .foregroundStyle(ContentView.navy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(link.viewers, id: \.self) { p in
                HStack {
                    Label("\(p.displayName)が見ています", systemImage: "ipad.and.iphone")
                    Spacer()
                    Button("切る") { link.disconnect(p) }
                        .buttonStyle(.bordered)
                        .tint(Color(red: 0x6B / 255, green: 0x7A / 255, blue: 0x8C / 255))   // 青灰（赤は使わない）
                }
                .font(.callout)
                .foregroundStyle(ContentView.navy)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .alert(link.requests.first.map { "\($0.peer.displayName)に状態を送りますか？" } ?? "",
               isPresented: Binding(get: { !link.requests.isEmpty }, set: { _ in })) {
            if let r = link.requests.first {
                Button("送る") { link.answer(r, send: true) }
                Button("送らない", role: .cancel) { link.answer(r, send: false) }
            }
        } message: {
            Text("顔の絵を動かす数値・顔の向き・いつもとの違い・記録の状態・家族の印と場面を、その場で送ります。音声・記録のファイルは送りません（映像は設定でオンにしたときだけ）。「送る」を選ぶと、この端末を覚えて次からは確認なしでつなぎます（設定で取り消せます）。")
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var fill = false   // true: 枠いっぱいに（はみ出す分は切る）

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

