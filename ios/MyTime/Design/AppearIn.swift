import SwiftUI

/// 表示されたときに、下から少し浮き上がってふわっと出る（順番に出すときは delay をずらす）。
/// 「動きを減らす」がオンのときは動かさない
struct AppearIn: ViewModifier {
    var delay: Double = 0
    var rise: CGFloat = 10
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : rise)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: .top)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(delay)) { shown = true }
            }
    }
}

extension View {
    /// 表示されたときにふわっと出る
    func appearIn(delay: Double = 0, rise: CGFloat = 10) -> some View { modifier(AppearIn(delay: delay, rise: rise)) }
}

/// 今日の印などが、表示されたときに「ぽん」と大きくなってから落ち着く
struct PopIn: ViewModifier {
    var delay: Double = 0.15
    @State private var scale: CGFloat = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : scale)
            .onAppear {
                guard !reduceMotion, scale != 1 else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(delay)) { scale = 1 }
            }
    }
}

extension View {
    func popIn(delay: Double = 0.15) -> some View { modifier(PopIn(delay: delay)) }
}
