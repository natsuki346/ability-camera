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
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    Task { await model.toggle() }
                } label: {
                    Text(model.running ? "停止して保存" : "開始")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.running ? .red : .accentColor)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 8) {
                    stat("顔が映っている割合", model.faceRatio.map { "\(Int($0 * 100))%" })
                    stat("解析コマ/秒", model.fps.map { String(format: "%.1f", $0) })
                    stat("解析時間 ms", model.procMs.map { String(format: "%.0f", $0) })
                    stat("撮影→結果 ms", model.latMs.map { String(format: "%.0f", $0) })
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
