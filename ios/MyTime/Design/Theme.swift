import SwiftUI
import MyTimeCore

extension Color {
    /// "#RRGGBB"（Web 版と同じ色の値）
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x0A84FF
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    /// 種別色：実行は赤、確認は青（Web 版と同じ考え方）
    static let doTask = Color.red
    static let checkTask = Color.blue
}

extension SpecDef {
    var tint: Color { Color(hex: color) }
}

/// Liquid Glass（iOS 26 以降）。それより前の iOS では、標準の素材（すりガラス）で近い見た目にする。
/// Xcode 26 より前の SDK でもビルドできるよう、コンパイラのバージョンで切り替える。
struct GlassBackground<S: Shape>: ViewModifier {
    var shape: S
    var interactive = false
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
        #else
        content.background(.regularMaterial, in: shape)
        #endif
    }
}

extension View {
    func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View { modifier(GlassBackground(shape: shape, interactive: interactive)) }
    /// 角丸のカード（グループ化された一覧と同じ背景）
    func card(radius: CGFloat = 18) -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// アニメーションの共通値。動きを減らす設定では呼び出し側で nil にする
enum Motion {
    static let sheet = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let pop = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let value = Animation.spring(response: 0.5, dampingFraction: 0.9)
}
