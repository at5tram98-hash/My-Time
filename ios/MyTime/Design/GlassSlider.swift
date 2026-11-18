import SwiftUI

/// ガラスのスライダー（コントロールセンターの明るさの調節のような、指でなぞって値を決める太いバー）。
/// 決まった段（steps）にだけ止まり、段が変わるたびに軽く震える。なぞっている間は上に大きく値を出す。
/// VoiceOver では上下のスワイプで1段ずつ変えられる。
struct GlassSlider: View {
    @Binding var value: Int
    var steps: [Int]
    var label: (Int) -> String
    var tint: Color = .accentColor
    var symbol: String? = nil
    var title: String = ""
    var height: CGFloat = 44

    @State private var dragging = false
    @State private var dragIndex: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var index: Int { steps.firstIndex(of: value) ?? steps.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0 }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                if !title.isEmpty {
                    if let symbol { Label(title, systemImage: symbol).foregroundStyle(.primary) } else { Text(title) }
                }
                Spacer()
                Text(label(value))
                    .font(dragging ? .title3.weight(.bold) : .body.weight(.semibold))
                    .foregroundStyle(dragging ? tint : .secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .animation(reduceMotion ? nil : .snappy, value: dragging)
            GeometryReader { g in
                let w = g.size.width
                let knob = height - 8
                let n = max(1, steps.count - 1)
                let pos = dragIndex ?? Double(index)
                let x = 4 + (w - knob - 8) * CGFloat(pos / Double(n))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
                    // 段の目印（両端と途中）
                    HStack(spacing: 0) {
                        ForEach(0..<min(steps.count, 13), id: \.self) { i in
                            Circle().fill(Color.primary.opacity(0.18)).frame(width: 5, height: 5)
                            if i < min(steps.count, 13) - 1 { Spacer(minLength: 0) }
                        }
                    }
                    .padding(.horizontal, knob / 2 + 4 - 2.5)
                    Capsule().fill(tint.gradient)
                        .frame(width: x + knob + 4)
                        .padding(.vertical, 0)
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.22), radius: dragging ? 8 : 3, y: 1)
                        .frame(width: knob, height: knob)
                        .scaleEffect(dragging ? 1.08 : 1)
                        .offset(x: x)
                }
                .frame(height: height)
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !dragging { withAnimation(.snappy) { dragging = true } }
                            let p = Double((v.location.x - 4 - knob / 2) / max(1, w - knob - 8)) * Double(n)
                            let c = min(Double(n), max(0, p))
                            dragIndex = c
                            let i = Int(c.rounded())
                            if steps[i] != value { value = steps[i] }
                        }
                        .onEnded { _ in
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) { dragIndex = nil; dragging = false }
                        }
                )
            }
            .frame(height: height)
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.isEmpty ? "値" : title)
        .accessibilityValue(label(value))
        .accessibilityAdjustableAction { d in
            let i = index
            switch d {
            case .increment: if i + 1 < steps.count { value = steps[i + 1] }
            case .decrement: if i > 0 { value = steps[i - 1] }
            @unknown default: break
            }
        }
    }
}


/// 分を「45分」「1時間」「1時間30分」で表す
func durationLabel(_ m: Int) -> String { m < 60 ? "\(m)分" : m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分" }
