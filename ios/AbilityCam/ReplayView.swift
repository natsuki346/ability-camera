import SwiftUI

/// 記録のリプレイ（次の段階で作る）
struct ReplayView: View {
    let data: ReplayData

    var body: some View {
        RecordRow(started: Date(timeIntervalSince1970: data.startT), durationS: data.durationS,
                  faceRatio: data.faceRatio, diffs: data.diffCount, marks: data.markCount)
            .padding()
    }
}
