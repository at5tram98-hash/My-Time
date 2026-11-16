import SwiftUI
import MyTimeCore

/// 時間を指でなぞって決めるバー（タップ以外の操作）。
/// 中ほどをなぞる＝時間ごと移動、左右の端をなぞる＝開始・終了だけを変える。5分刻みで、刻むたびに軽く震える。
/// VoiceOver では上下スワイプで15分ずつ動かせる。
struct TimeRangeBar: View {
    @Binding var start: Date
    @Binding var end: Date
    var tint: Color = .accentColor
    /// 表示する幅（時間）
    var hours: Int = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowStart: Date?
    @State private var drag: DragState?
    @State private var tick = 0

    private enum Part { case move, start, end }
    private struct DragState { var part: Part; var start: Date; var end: Date }
    private static let snap: TimeInterval = 5 * 60

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let win = windowStart ?? Self.window(for: start, hours: hours)
            let perPt = TimeInterval(hours * 3600) / Double(w)
            let x0 = CGFloat(start.timeIntervalSince(win) / perPt)
            let x1 = CGFloat(end.timeIntervalSince(win) / perPt)
            ZStack(alignment: .topLeading) {
                // 目盛り（1時間ごとの線と時刻）
                ForEach(0...hours, id: \.self) { h in
                    let x = CGFloat(h) * w / CGFloat(hours)
                    Rectangle().fill(Color(.separator)).frame(width: 0.5, height: h == 0 || h == hours ? 0 : 34).offset(x: x, y: 18)
                    if h < hours {
                        Text(Self.hourLabel(win.addingTimeInterval(TimeInterval(h * 3600))))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            .offset(x: x + 3, y: 0)
                    }
                }
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 34).offset(y: 18)
                // 選んだ時間
                let left = max(0, min(w, x0)), right = max(0, min(w, x1))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(drag == nil ? 0.85 : 1))
                    .overlay(alignment: .leading) { grip.padding(.leading, 5) }
                    .overlay(alignment: .trailing) { grip.padding(.trailing, 5) }
                    .frame(width: max(14, right - left), height: 34)
                    .offset(x: left, y: 18)
                    .shadow(color: tint.opacity(drag == nil ? 0 : 0.35), radius: 6, y: 2)
                    .scaleEffect(drag != nil && !reduceMotion ? 1.02 : 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if drag == nil {
                            // 触れた場所で、端（16pt 以内）か中ほどかを決める
                            let x = v.startLocation.x
                            let part: Part = abs(x - x1) < 16 ? .end : abs(x - x0) < 16 ? .start : .move
                            drag = DragState(part: part, start: start, end: end)
                            windowStart = win
                        }
                        guard let d = drag else { return }
                        let delta = Self.round(TimeInterval(v.translation.width) * perPt)
                        var s = d.start, e = d.end
                        switch d.part {
                        case .move: s = d.start.addingTimeInterval(delta); e = d.end.addingTimeInterval(delta)
                        case .start: s = min(d.start.addingTimeInterval(delta), d.end.addingTimeInterval(-Self.snap))
                        case .end: e = max(d.end.addingTimeInterval(delta), d.start.addingTimeInterval(Self.snap))
                        }
                        if s != start || e != end { tick += 1 }
                        start = s; end = e
                    }
                    .onEnded { _ in
                        drag = nil
                        withAnimation(reduceMotion ? nil : .snappy) { windowStart = Self.window(for: start, hours: hours) }
                    }
            )
            .sensoryFeedback(.selection, trigger: tick)
        }
        .frame(height: 56)
        .accessibilityElement()
        .accessibilityLabel("時間")
        .accessibilityValue("\(Self.hm(start))から\(Self.hm(end))まで")
        .accessibilityHint("上下にスワイプすると15分ずつ動かせます")
        .accessibilityAdjustableAction { dir in
            let d: TimeInterval = dir == .increment ? 900 : -900
            start = start.addingTimeInterval(d); end = end.addingTimeInterval(d)
        }
        .onChange(of: start) { _, new in
            // ほかの方法で開始が変わり、見えている範囲から外れたら範囲を合わせる
            guard drag == nil, let w = windowStart else { return }
            if new < w || new > w.addingTimeInterval(TimeInterval(hours * 3600 - 1800)) { windowStart = Self.window(for: new, hours: hours) }
        }
    }

    private var grip: some View {
        Capsule().fill(.white.opacity(0.85)).frame(width: 3, height: 14)
    }

    private static func round(_ t: TimeInterval) -> TimeInterval { (t / snap).rounded() * snap }

    /// 開始の1時間前の正時から
    private static func window(for d: Date, hours: Int) -> Date {
        let cal = Calendar.current
        let h = cal.dateInterval(of: .hour, for: d)?.start ?? d
        return h.addingTimeInterval(-3600)
    }

    private static func hourLabel(_ d: Date) -> String { "\(Calendar.current.component(.hour, from: d))時" }
    private static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// 日付の行。左右にスワイプ（またはボタン）で前日・翌日へ。時刻はそのまま
struct DaySwipeRow: View {
    @Binding var date: Date
    var onShift: (Int) -> Void
    @State private var offset: CGFloat = 0
    @State private var tick = 0

    var body: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("前の日")
            Spacer()
            VStack(spacing: 1) {
                Text(Self.label(date)).font(.headline)
                Text(Self.relative(date)).font(.caption).foregroundStyle(.secondary)
            }
            .offset(x: offset)
            .contentTransition(.numericText())
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("次の日")
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in offset = v.translation.width / 3 }
                .onEnded { v in
                    if v.translation.width < -50 { shift(1) } else if v.translation.width > 50 { shift(-1) }
                    withAnimation(.snappy) { offset = 0 }
                }
        )
        .sensoryFeedback(.selection, trigger: tick)
        .accessibilityElement(children: .combine)
        .accessibilityHint("左右にスワイプすると日を変えられます")
        .accessibilityAdjustableAction { onShift($0 == .increment ? 1 : -1) }
    }

    private func shift(_ n: Int) {
        tick += 1
        withAnimation(.snappy) { onShift(n) }
    }

    static func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（EEE）"
        return f.string(from: d)
    }

    static func relative(_ d: Date) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        switch n {
        case 0: return "今日"
        case 1: return "明日"
        case 2: return "あさって"
        case -1: return "昨日"
        default: return n > 0 ? "\(n)日後" : "\(-n)日前"
        }
    }
}
