import SwiftUI
import MyTimeCore

/// Liquid Glass の部品をまとめて置くための入れ物（iOS 26 以降は GlassEffectContainer で溶け合わせる）
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// ガラスの分段コントロール（選んだ項目の下を、ガラスの丸い板がなめらかに移動する）
struct GlassSegmented<T: Hashable>: View {
    struct Item { var value: T; var title: String; var symbol: String? = nil }
    var items: [Item]
    @Binding var selection: T
    var tint: Color = .accentColor
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { it in
                let on = it.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.8)) { selection = it.value }
                } label: {
                    HStack(spacing: 4) {
                        if let s = it.symbol { Image(systemName: s).imageScale(.small) }
                        Text(it.title)
                    }
                    .font(.subheadline.weight(on ? .semibold : .medium))
                    .foregroundStyle(on ? tint : Color.primary.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background {
                        if on {
                            Capsule().fill(tint.opacity(0.16))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.6))
                                .shadow(color: tint.opacity(0.18), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .glass(Capsule(), interactive: true)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// ガラスの丸いボタン（ツールバーや画面の上に浮かせる）
struct GlassCircleButton: View {
    var symbol: String
    var label: String
    var tint: Color = .primary
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .glass(Circle(), interactive: true)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// ガラスの小さな札（件数・状態）
struct GlassPill: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .glass(Capsule())
    }
}

/// 週の帯（7日。選んだ日はガラスの円、今日は赤。左右になぞって前後の週へ）
struct WeekStrip: View {
    @Binding var selected: Date
    /// 週表示で見えている日（薄く帯で示す）
    var highlighted: ClosedRange<EpochMs>? = nil
    @Environment(AppModel.self) private var model
    @State private var dx: CGFloat = 0

    var body: some View {
        let day = model.time.startOfDay(model.time.ms(selected))
        let start = model.time.addDays(day, -model.time.weekday(day))
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                let d = model.time.addDays(start, i)
                let on = d == day
                let today = model.time.isSameDay(d, model.now)
                let inRange = highlighted.map { $0.contains(d) } ?? false
                let dots = dotCount(d)
                Button { withAnimation(.snappy) { selected = model.time.date(d) } } label: {
                    VStack(spacing: 3) {
                        Text(DomainTime.weekdayJa[i]).font(.caption2.weight(.semibold))
                            .foregroundStyle(i == 0 ? Color.red.opacity(0.8) : i == 6 ? Color.blue.opacity(0.8) : .secondary)
                        Text("\(model.time.calendar.component(.day, from: model.time.date(d)))")
                            .font(.callout.weight(on || today ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle(on ? Color.white : today ? Color.red : Color.primary)
                            .frame(width: 34, height: 34)
                            .background {
                                if on { Circle().fill(today ? Color.red.gradient : Color.accentColor.gradient).shadow(color: .black.opacity(0.15), radius: 4, y: 2) }
                            }
                        HStack(spacing: 2) {
                            ForEach(0..<dots, id: \.self) { _ in Circle().fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 4) }
                        }
                        .frame(height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background { if inRange && !on { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.08)) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.time.dayLabel(d))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .offset(x: dx)
        .gesture(DragGesture(minimumDistance: 20)
            .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { dx = v.translation.width / 4 } }
            .onEnded { v in
                if abs(v.translation.width) > 60 {
                    let n = v.translation.width < 0 ? 7 : -7
                    withAnimation(.snappy) { selected = model.time.date(model.time.addDays(day, n)); dx = 0 }
                } else { withAnimation(.snappy) { dx = 0 } }
            })
        .sensoryFeedback(.selection, trigger: day)
    }

    private func dotCount(_ d: EpochMs) -> Int {
        let n = model.visibleEvents(from: d, to: model.time.addDays(d, 1)).count
        return min(3, n)
    }
}
