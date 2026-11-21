import SwiftUI

/// 読み込み中の仮の形（スケルトン）。灰色の面に、光が左から右へゆっくり流れる。
/// 中身が来るまで、くるくる回る印の代わりに出す（形が先に見えるので、待っている感じが少ない）
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 8
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6)
                            .offset(x: phase * g.size.width * 1.6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .accessibilityLabel("読み込み中")
    }
}

/// 一覧の1行のスケルトン（丸いアイコンと2本の線）
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(cornerRadius: 15).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(cornerRadius: 4).frame(width: 150, height: 12)
                SkeletonBlock(cornerRadius: 4).frame(width: 90, height: 10)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("読み込み中")
    }
}
