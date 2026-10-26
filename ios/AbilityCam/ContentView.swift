import AVFoundation
import Charts
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

struct ContentView: View {
    @StateObject private var model = AnalysisModel()
    @State private var cameraLarge = false
    @AppStorage("sketchTone") private var sketchTone = SketchTone.medium
    @Environment(\.scenePhase) private var scenePhase
    @State private var framingNote = ""

    private let series = ["口角を上げる", "眉を寄せる", "目を細める", "口を開ける", "音量", "声の高さ"]
    private let colors: [Color] = [Metric.mouthSmile, .browDown, .eyeSquint, .jawOpen, .rmsDb, .f0Hz].map(\.color)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                notRecordingBanner

                ZStack(alignment: .topTrailing) {
                    faceSketch
                        .padding(.top, 140)   // 右上の小さな映像と重ならないように
                        .opacity(cameraLarge ? 0 : 1)
                    camera
                }

                Button {
                    Task { await model.toggle() }
                } label: {
                    Text(model.running ? "停止して保存" : "開始")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.running ? Color(red: 0x6B / 255, green: 0x7A / 255, blue: 0x8C / 255) : .accentColor)   // 赤は使わない
                .disabled(model.framingSince != nil)

                Button {
                    Task { await model.toggleFramingCheck() }
                } label: {
                    Text(model.framingSince != nil ? "映り方チェックを終える" : "映り方チェック")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.running)

                if let since = model.framingSince {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text("映り方チェック中 \(Self.duration(ctx.date.timeIntervalSince(since)))（表情・音声は記録していません）")
                            .font(.callout.monospacedDigit())
                    }
                } else if let r = model.framingResult {
                    framingCard(r)
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

                Text(model.status).font(.footnote).foregroundStyle(.secondary)
                Text("映像と音声は保存せず、この端末の中でその場で解析します。記録（JSONL）は「ファイル」アプリ > このiPhone内 > Ability Cam に保存されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(TouchActivityView { model.noteActivity() })   // 画面のどこかを触ったら、止めるまでの5分を数え直す
        .task { await model.prepareCamera() }   // カメラの許可を得たら、すぐ映像を出す（記録はしない）
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.enterBackground()
            case .active: Task { await model.enterForeground() }
            default: break
            }
        }
    }

    /// 「開始」前・「停止」後は、記録していないことをはっきり出す
    @ViewBuilder private var notRecordingBanner: some View {
        if !model.running {
            Group {
                if model.cameraPausedForIdle {
                    Button { Task { await model.prepareCamera() } } label: {
                        Label("カメラを止めています（タップで再開）", systemImage: "camera")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Label(model.framingSince != nil ? "映り方チェック中（表情・音声は記録していません）" : "まだ記録していません（映り方の確認中）",
                          systemImage: "eye")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(10)
            .background(Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEA / 255).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// いつもとの違い（普段の記録中は進み具合）。状態の名前は出さない
    private var differencesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("いつもとの違い").font(.caption).foregroundStyle(.secondary)
            if !model.running {
                Text("「開始」後の最初の60秒を「普段」として記録します").foregroundStyle(.secondary)
            } else {
                if !model.faceReadable {
                    Text("顔が読めません（映っていない・動きが大きい）").foregroundStyle(.secondary)
                }
                if let sec = model.baselineSec {
                    Text("普段を記録中 \(sec)/\(Int(AnalysisModel.baselineSeconds))秒（落ち着いているときに）")
                    ProgressView(value: Double(sec), total: AnalysisModel.baselineSeconds)
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
            .overlay {
                if model.cameraPausedForIdle {
                    Text("タップで再開").font(.caption).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if model.cameraPausedForIdle {
                    Task { await model.prepareCamera() }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { cameraLarge.toggle() }
                }
            }
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
            if model.cameraPausedForIdle {
                Text("カメラを止めています（タップで再開）").font(.callout).foregroundStyle(.secondary)
            } else if !model.cameraActive {
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
        .contentShape(Rectangle())
        .onTapGesture { if model.cameraPausedForIdle { Task { await model.prepareCamera() } } }
    }

    /// 映り方チェックの要約。要約だけを framing-checks.jsonl に残している
    private func framingCard(_ r: FramingSummary) -> some View {
        let pc = { (x: Double?) in x.map { "（\(Int(($0 * 100).rounded()))%）" } ?? "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let from = f.string(from: Date(timeIntervalSince1970: Double(r.startedMs) / 1000))
        let to = f.string(from: Date(timeIntervalSince1970: Double(r.endedMs) / 1000))
        let bins = r.binFaceRatio.enumerated().compactMap { i, v in v.map { (i, $0) } }
        return VStack(alignment: .leading, spacing: 6) {
            Text("映り方チェックの結果（\(from)〜\(to)）").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("計測した時間", Self.duration(r.durationS))
                row("顔が映っていた時間", Self.duration(r.faceS) + pc(r.faceRatio))
                row("顔が横を向きすぎていなかった時間（左右\(Int(r.yawLimitDeg))°未満）", Self.duration(r.facingS) + pc(r.facingRatio))
                row("顔が映らなかった時間のうち、一番長く続いた時間", Self.duration(r.longestNoFaceS))
                row("解析コマ/秒（平均）", r.fpsMean.map { String(format: "%.1f", $0) } ?? "–")
                row("撮影→網目の遅れ（中央値）", r.meshLagMsMedian.map { "\(Int($0)) ms" } ?? "–（網目を出していません）")
            }
            .font(.callout)

            Text("\(Int(r.binS))秒ごとの、顔が映っていた割合").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            Chart(bins, id: \.0) { i, v in
                BarMark(x: .value("秒", Double(i) * r.binS + r.binS / 2), y: .value("割合", v), width: .ratio(0.8))
                    .foregroundStyle(Color(red: 0x1F / 255, green: 0x3A / 255, blue: 0x5F / 255))   // 濃紺
            }
            .chartXScale(domain: 0...(Double(max(r.binFaceRatio.count, 1)) * r.binS))
            .chartYScale(domain: 0...1)
            .chartYAxis { AxisMarks(values: [0, 0.5, 1]) { v in
                AxisGridLine()
                AxisValueLabel { Text("\(Int((v.as(Double.self) ?? 0) * 100))%") }
            } }
            .chartXAxis { AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))秒") }
            } }
            .frame(height: 100)

            HStack {
                TextField("メモ（任意）例：胸ポケット・姉・食事", text: $framingNote)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { model.saveFramingNote(framingNote) }
                Button("保存") { model.saveFramingNote(framingNote) }
                    .buttonStyle(.bordered)
                    .disabled(framingNote.trimmingCharacters(in: .whitespaces).isEmpty || framingNote == model.framingNoteSaved)
            }
            if let saved = model.framingNoteSaved {
                Text("メモを保存しました：\(saved)").font(.footnote).foregroundStyle(.secondary)
            }
            Text("1コマごとの値・表情の数値・顔の点は残していません（要約だけを \(FramingLog.fileName) に保存）")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .onChange(of: r.id) { framingNote = "" }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(value).monospacedDigit().bold()
        }
    }

    static func duration(_ s: Double) -> String {
        let n = Int(s.rounded())
        return n >= 60 ? "\(n / 60)分\(String(format: "%02d", n % 60))秒" : "\(n)秒"
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

/// 画面のどこかが触られたことを知らせる（タッチは横取りしない）
struct TouchActivityView: UIViewRepresentable {
    let onTouch: @MainActor () -> Void

    func makeUIView(context: Context) -> HostView { HostView(onTouch: onTouch) }
    func updateUIView(_ uiView: HostView, context: Context) { uiView.recognizer.onTouch = onTouch }

    final class HostView: UIView {
        let recognizer: Recognizer
        init(onTouch: @escaping @MainActor () -> Void) {
            recognizer = Recognizer(onTouch: onTouch)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }

        override func willMove(toWindow newWindow: UIWindow?) {
            recognizer.view?.removeGestureRecognizer(recognizer)
            newWindow?.addGestureRecognizer(recognizer)
        }
    }

    final class Recognizer: UIGestureRecognizer {
        var onTouch: @MainActor () -> Void
        init(onTouch: @escaping @MainActor () -> Void) {
            self.onTouch = onTouch
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch()
            state = .failed   // 何も認識しない（ほかの操作の邪魔をしない）
        }
    }
}
