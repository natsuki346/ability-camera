import SwiftUI

/// 試すモードの指示（v1.18〜）：画面いっぱいに大きく出す。「やめる」でいつでもやめられる
struct CueOverlay: View {
    @ObservedObject var model: AnalysisModel

    var body: some View {
        VStack(spacing: 20) {
            Text("試すモード").font(.headline).foregroundStyle(.secondary)
            Spacer()
            switch model.cueStage {
            case .baseline:
                Text("普段を取っています").font(.title2.bold())
                Text(CueKind.calm.instruction).font(.system(size: 44, weight: .bold)).multilineTextAlignment(.center)
                if let sec = model.baselineSec {
                    ProgressView(value: min(Double(sec), model.baselineTarget), total: model.baselineTarget).tint(Palette.progress)
                        .frame(maxWidth: 320)
                }
            case .step(let i):
                let st = CuePlan.steps[i]
                Text(st.kind.instruction).font(.system(size: 48, weight: .bold)).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                Text("\(model.cueRemaining)秒").font(.system(size: 64, weight: .semibold).monospacedDigit())
                Text("\(i + 1)／\(CuePlan.steps.count)").font(.title3).foregroundStyle(.secondary)
                if i + 1 < CuePlan.steps.count {
                    Text("次：\(CuePlan.steps[i + 1].kind.instruction)").font(.title3).foregroundStyle(.secondary)
                }
            case .computing:
                ProgressView()
                Text("結果を出しています").font(.title2.bold())
            case nil:
                EmptyView()
            }
            Spacer()
            if model.cueStage != .computing {
                Button("やめる") { model.stopCues() }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .foregroundStyle(ContentView.navyText)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }
}

/// 試すモードの結果（v1.18〜）：今の下限と、その人の最大から決めた下限で並べる。Mac の face_check.py --cues と同じ表
struct CueResultView: View {
    let result: CueTrial
    @Environment(\.dismiss) private var dismiss

    private static let names: [CueKind: String] = [.frown: "眉を寄せる", .smile: "笑う", .calm: "何もしない", .turn: "顔を横に向ける", .rest: "戻す"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // v1.19〜：どちらの数が今使われているかを先に出す
                    Label("この結果は、今の普段の下限で比べたもの。最大から決めた下限は次の普段から使います", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(ContentView.navyText)
                }
                Section {
                    ForEach([CueKind.frown, .smile], id: \.self) { k in
                        compare(Self.names[k] ?? "", hitText(result.before.hit(k)), result.after.map { hitText($0.hit(k)) })
                    }
                } header: { Text("指示どおりに動かしたとき") } footer: {
                    Text("「いつもとの違い」（眉を寄せる・口角を上げるの「いつもより強い」）が、指示の始まりから終わりの\(Int(CueReport.graceS))秒後までに出た回数と、出るまでの秒数（中央値）")
                }
                Section {
                    ForEach([CueKind.calm, .turn, .rest], id: \.self) { k in
                        compare("\(Self.names[k] ?? "")の間", quietText(result.before.quiet(k)), result.after.map { quietText($0.quiet(k)) })
                    }
                } header: { Text("動かしていないとき") } footer: {
                    Text("その間に始まった「いつもとの違い」（声が出たは入れない）と重なりのできごとの数（1分あたり）")
                }
                ForEach([CueKind.frown, .smile], id: \.self) { k in
                    Section {
                        ForEach(CueReport.metrics, id: \.m) { item in
                            compare(item.m.label, rowText(result.before.row(item.m, k)), result.after.map { rowText($0.row(item.m, k)) })
                        }
                    } header: { Text("指標ごと（\(Self.names[k] ?? "")の間）") } footer: {
                        Text("z の中央値（眉を寄せる・笑う向きがプラス）と、z が \(Int(CueReport.hitZ)) 以上になった回数")
                    }
                }
                Section {
                    if result.max.isEmpty {
                        Text("求まりませんでした（顔が映っていなかった・点の距離が無い）").foregroundStyle(.secondary)
                    }
                    ForEach(result.max.keys.sorted(), id: \.self) { k in
                        let m = Metric(rawValue: k)
                        LabeledContent(m?.label ?? k, value: m.map { $0.valueText(result.max[k] ?? 0) } ?? "")
                    }
                } header: { Text("その人の最大") } footer: {
                    Text("「いちばん強く眉を寄せる」「いちばん大きく笑う」の間の値（動く向きの 95%）。人ごとに保存し、次に普段を決めたときから、標準偏差の下限を「普段の中央値と最大の差の 10%」と今の下限の小さい方にします（仮の値）。Mac では analysis/face_check.py 記録.jsonl --cues で同じ表が出ます")
                }
            }
            .navigationTitle("試すモードの結果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    /// 左に名前、右に「今の下限 → その人の最大から決めた下限」
    private func compare(_ label: String, _ before: String, _ after: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline.bold())
            Text("今の下限（今使っている）：\(before)").font(.caption)
            Text("最大から決めた下限（次の普段から）：\(after ?? "–")").font(.caption)
        }
    }

    private func hitText(_ h: CueReport.Hit?) -> String {
        guard let h else { return "–" }
        let lat = h.latencyS.isEmpty ? "" : String(format: "・出るまで %.1f秒", DiffCriteria.quantile(h.latencyS.sorted(), 0.5))
        return "出た \(h.hit)／\(h.n)回\(lat)"
    }

    private func quietText(_ q: CueReport.Quiet?) -> String {
        guard let q else { return "–" }
        let pm = { (n: Int) in CueReport.perMin(n, q.seconds).map { String(format: "%.1f", $0) } ?? "–" }
        return "違い \(q.diffs)件（\(pm(q.diffs))/分）・重なり \(q.co)件（\(pm(q.co))/分）・\(Int(q.seconds.rounded()))秒"
    }

    private func rowText(_ r: CueReport.Row?) -> String {
        guard let r else { return "–" }
        return (r.zMedian.map { String(format: "z %+.1f", $0) } ?? "z –") + "・\(r.hit)／\(r.n)回"
    }
}
