import SwiftUI

/// 横にめくるカード（純正の「ヘルスケア」「天気」の横並びのカードと同じ考え方）。
/// 次のカードが少しだけ見えるので、めくれることが分かる。カードの境目でぴたっと止まり、下に小さな点で何枚目かを出す。
/// 画面を縦に長くしないで、関係するものを1か所にまとめるために使う
struct CardCarousel<Content: View>: View {
    var count: Int
    /// カードの高さ
    var height: CGFloat
    /// 次のカードがのぞく幅
    var peek: CGFloat = 28
    @ViewBuilder var content: (Int) -> Content

    @State private var current: Int? = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(0..<count, id: \.self) { i in
                        content(i)
                            .frame(height: height)
                            .containerRelativeFrame(.horizontal) { w, _ in count > 1 ? w - peek - 10 : w }
                            .scrollTransition(.interactive, axis: .horizontal) { v, phase in
                                // 端に寄ったカードは少し小さく薄く（めくっている感じを出す）
                                v.scaleEffect(reduceMotion ? 1 : 1 - abs(phase.value) * 0.05)
                                    .opacity(1 - abs(phase.value) * 0.25)
                            }
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $current)
            .scrollClipDisabled()
            if count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule().fill(i == (current ?? 0) ? Color.primary.opacity(0.6) : Color.primary.opacity(0.18))
                            .frame(width: i == (current ?? 0) ? 14 : 5, height: 5)
                    }
                }
                .animation(.snappy, value: current)
                .accessibilityHidden(true)
            }
        }
        .sensoryFeedback(.selection, trigger: current)
    }
}

/// カルーセルの1枚（角丸の面に、見出しのアイコンと名前）
struct CarouselCard<Content: View>: View {
    var title: String
    var symbol: String
    var tint: Color
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if action != nil { Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary) }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        if let action {
            Button(action: action) { card }.buttonStyle(PressableStyle())
        } else {
            card
        }
    }
}
