import AVFoundation
import Charts
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AnalysisModel()

    private let series = ["口角を上げる", "眉を寄せる", "目を細める", "口を開ける", "音量", "声の高さ"]
    private let colors: [Color] = [.green, .orange, .yellow, .blue, .purple, .pink]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CameraPreview(session: model.camera.session)
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .background(Color.black)
                    .overlay {
                        // 網目は解析の遅れの分だけ映像より遅れて見える（即時性そのものなので、隠さない）
                        if model.meshEnabled, let mesh = model.mesh { MeshOverlay(mesh: mesh) }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { model.meshEnabled.toggle() } label: {
                            Label("網目", systemImage: model.meshEnabled ? "circle.grid.cross.fill" : "circle.grid.cross")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.meshEnabled ? .white : .gray)
                        .padding(6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    Task { await model.toggle() }
                } label: {
                    Text(model.running ? "停止して保存" : "開始")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.running ? .red : .accentColor)

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

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
