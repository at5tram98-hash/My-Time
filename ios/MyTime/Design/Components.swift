import SwiftUI
import MyTimeCore

/// 進捗リング（外周＝実績、細い目盛り＝理想）。中央に SF Symbol
struct ProgressRing: View {
    var value: Double?
    var ideal: Double?
    var symbol: String
    var tint: Color = .doTask
    var size: CGFloat = 40
    var running = false
    var done = false

    var body: some View {
        let line = max(3, size / 11)
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: line)
            if let ideal, ideal > 0 {
                Circle().trim(from: 0, to: ideal).stroke(Color.blue.opacity(0.85), style: StrokeStyle(lineWidth: max(1.5, line / 2.5), lineCap: .round)).rotationEffect(.degrees(-90))
            }
            if let value, value > 0 {
                Circle().trim(from: 0, to: value).stroke(running ? Color.green : tint, style: StrokeStyle(lineWidth: line, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(Motion.value, value: value)
            }
            Circle().fill(tint.opacity(done ? 0.9 : 0.14)).padding(line + 2)
            Image(systemName: done ? "checkmark" : symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(done ? Color.white : tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// タスクの SF Symbol（Web 版のアイコン ID を読み替える。保存値は変えない）
enum IconMap {
    static let symbols: [String: String] = [
        "book": "book.fill", "pencil": "pencil", "laptop": "laptopcomputer", "note": "doc.text.fill", "books": "books.vertical.fill", "flask": "flask.fill",
        "target": "target", "briefcase": "briefcase.fill", "run": "figure.run", "sparkles": "sparkles", "cart": "cart.fill", "pan": "frying.pan.fill",
        "headphones": "headphones", "chat": "bubble.left.fill", "bulb": "lightbulb.fill", "star": "star.fill", "calendar": "calendar", "graduation": "graduationcap.fill",
        "house": "house.fill", "heart": "heart.fill", "music": "music.note", "plane": "airplane", "dining": "fork.knife", "person": "person.fill", "circle": "circle",
        "yen": "yensign", "train": "tram.fill", "sun": "sun.max.fill", "people": "person.3.fill",
    ]
    /// 旧版が保存した絵文字
    static let emoji: [String: String] = ["📘": "book", "📗": "book", "📙": "book", "📕": "book", "📖": "book", "✏": "pencil", "💻": "laptop", "📝": "note", "📚": "books", "🧪": "flask", "🎯": "target", "💼": "briefcase", "🏃": "run", "🧹": "sparkles", "🛒": "cart", "🍳": "pan", "🎧": "headphones", "💬": "chat", "💡": "bulb", "⭐": "star", "📅": "calendar", "🎓": "graduation", "🏠": "house", "❤": "heart", "🎵": "music", "✈": "plane", "🍽": "dining", "👤": "person"]
    static func symbol(_ icon: String?) -> String {
        guard let icon else { return "circle" }
        if let s = symbols[icon] { return s }
        let key = icon.replacingOccurrences(of: "\u{FE0F}", with: "")
        return emoji[key].flatMap { symbols[$0] } ?? "circle"
    }
}

/// 専門の種類のしるし（予定＝角丸四角、タスク＝円）
struct SpecBadge: View {
    var type: SpecTypeId?
    var isEvent: Bool
    var size: CGFloat = 28
    /// 種類の設定でアイコン・色を変えていれば、それを使う
    @Environment(AppModel.self) private var model: AppModel?
    var body: some View {
        let def = type.flatMap { SPEC_BY_ID[$0] }
        let tint = type.flatMap { t in model.map { $0.specTint(t) } } ?? def?.tint ?? .gray
        let symbol = type.flatMap { t in model.map { $0.specSymbol(t) } } ?? def?.symbol
        ZStack {
            if isEvent { RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint) } else { Circle().fill(tint) }
            Image(systemName: symbol ?? (isEvent ? "calendar" : "circle")).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 今日の状況の小さなボタン（注意・未割当・タスク・余白）
struct StatusChip: View {
    var symbol: String
    var label: String
    var value: String
    var tint: Color = .secondary
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).imageScale(.small).foregroundStyle(tint)
                Text(label).foregroundStyle(.secondary)
                Text(value).fontWeight(.bold).monospacedDigit().foregroundStyle(tint == .secondary ? .primary : tint)
                    .contentTransition(.numericText())
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(tint == .secondary ? Color(.tertiarySystemFill) : tint.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(value)")
    }
}

/// 押したときに少し沈むボタン（触覚が使えないときも、形で反応を伝える）
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduce ? 0.94 : 1)
            .opacity(configuration.isPressed && reduce ? 0.7 : 1)
            .animation(reduce ? nil : Motion.pop, value: configuration.isPressed)
    }
}

/// 画面下の知らせ（取り消し付き）
struct ToastView: View {
    var toast: AppModel.Toast
    var onUndo: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.subheadline.weight(.medium)).lineLimit(2)
            if toast.undo != nil {
                Button("取り消す", action: onUndo).font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glass(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}

/// 右へスライドして決める操作（承認など、取り消しにくい操作の誤タップを防ぐ）。
/// 端まで運ぶと実行。途中で離すと戻る。VoiceOver ではボタンとして実行できる
struct SlideToConfirm: View {
    var title: String
    var symbol: String = "chevron.right.2"
    var tint: Color = .green
    var enabled = true
    var action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var done = false
    @State private var tick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let knob: CGFloat = 52

    var body: some View {
        GeometryReader { geo in
            let maxX = max(0, geo.size.width - knob - 8)
            let progress = maxX > 0 ? offset / maxX : 0
            ZStack(alignment: .leading) {
                Capsule().fill(enabled ? AnyShapeStyle(tint.opacity(0.18)) : AnyShapeStyle(Color.gray.opacity(0.18)))
                // 進んだ分だけ色が満ちる
                Capsule().fill(tint.gradient)
                    .frame(width: knob + 8 + offset)
                    .opacity(enabled ? 1 : 0)
                Text(done ? "承認しました" : title)
                    .font(.headline)
                    .foregroundStyle(enabled ? tint : .secondary)
                    .opacity(done ? 1 : 1 - Double(progress) * 1.4)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob)
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .overlay(Image(systemName: done ? "checkmark" : symbol).font(.title3.weight(.bold)).foregroundStyle(enabled ? tint : .gray))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .offset(x: 4 + offset)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard enabled, !done else { return }
                                let x = min(maxX, max(0, v.translation.width))
                                if Int(x / 24) != Int(offset / 24) { tick += 1 }
                                offset = x
                            }
                            .onEnded { _ in
                                guard enabled, !done else { return }
                                if offset > maxX * 0.88 {
                                    withAnimation(reduceMotion ? nil : .snappy) { offset = maxX; done = true }
                                    action()
                                    Task { try? await Task.sleep(for: .seconds(1.2)); withAnimation { done = false; offset = 0 } }
                                } else {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) { offset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: knob + 8)
        .sensoryFeedback(.selection, trigger: tick)
        .sensoryFeedback(.success, trigger: done)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("右へスライドすると実行します")
        .accessibilityAction { if enabled { action() } }
    }
}
