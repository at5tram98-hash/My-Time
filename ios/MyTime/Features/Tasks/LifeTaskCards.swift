import SwiftUI
import MyTimeCore

/// タスクタブの上の「朝」「清掃」。進行中なら進み具合、そうでなければ次にやることを1行で
struct LifeTaskCards: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let m = model.morning
        let b = model.cleaning
        HStack(spacing: 10) {
            card(title: "朝", symbol: "sunrise.fill", tint: .orange,
                 value: m.active.map { Double($0.doneCount) / Double(max(1, $0.steps.count)) },
                 line: morningLine(m), running: m.active != nil) {
                router.tasksPath = [m.active != nil ? .morningRun : .morning]
            }
            card(title: "清掃", symbol: "bubbles.and.sparkles.fill", tint: .teal,
                 value: b.active.map { CleaningSession.completion($0.statuses(in: b.areas).map(\.status)).ratio ?? 0 },
                 line: cleaningLine(b), running: b.active != nil) {
                router.tasksPath = [b.active != nil ? .cleaningRun : .cleaning]
            }
        }
    }

    private func morningLine(_ m: MorningRoutine) -> String {
        if let r = m.active, let c = r.current { return "\(r.index + 1)/\(r.steps.count)・\(c.name)" }
        if let n = m.alarms.compactMap({ $0.next(after: model.now, time: model.time) }).min() {
            return "アラーム \(model.time.isSameDay(n, model.now) ? "" : model.time.isSameDay(n, model.time.addDays(model.now, 1)) ? "明日 " : model.time.dayLabel(n) + " ")\(model.hm(n))"
        }
        return "\(m.enabledSteps.count)工程・アラームなし"
    }

    private func cleaningLine(_ b: CleaningBook) -> String {
        if let s = b.active {
            let c = CleaningSession.completion(s.statuses(in: b.areas).map(\.status))
            return "清掃中 \(c.done)/\(c.total)"
        }
        let n = b.neglected(now: model.now, time: model.time).count
        return n > 0 ? "そろそろ \(n)箇所" : "すべて目標どおり"
    }

    private func card(title: String, symbol: String, tint: Color, value: Double?, line: String, running: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    if let v = value {
                        Circle().trim(from: 0, to: v).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                            .animation(Motion.value, value: v)
                    }
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: running)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title).font(.subheadline.weight(.bold))
                        if running { Text("進行中").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(tint)) }
                    }
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)、\(line)")
        .accessibilityHint("開きます")
    }
}
