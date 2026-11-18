import SwiftUI

/// 取り消した予定の印（灰色の小さな札）
struct StruckBadge: View {
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "xmark.circle.fill").imageScale(.small)
            if !compact { Text("取り消し") }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, compact ? 3 : 5).padding(.vertical, 1)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .fixedSize()
        .accessibilityLabel("取り消し")
    }
}
