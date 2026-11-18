import SwiftUI
import MyTimeCore

/// タスクタブの「生活」：朝・清掃・持ち物。設定アプリと同じ、アイコン＋名前＋ひとことの行
struct LifeTaskRows: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let m = model.morning
        let b = model.cleaning
        let bring = BelongingsList.items(model: model)
        row(title: "朝", symbol: "sunrise.fill", tint: .orange, line: morningLine(m), running: m.active != nil,
            progress: m.active.map { Double($0.doneCount) / Double(max(1, $0.steps.count)) }) {
            router.tasksPath = [m.active != nil ? .morningRun : .morning]
        }
        row(title: "清掃", symbol: "bubbles.and.sparkles.fill", tint: .teal, line: cleaningLine(b), running: b.active != nil,
            progress: b.active.map { CleaningSession.completion($0.statuses(in: b.areas).map(\.status)).ratio ?? 0 }) {
            router.tasksPath = [b.active != nil ? .cleaningRun : .cleaning]
        }
        let left = bring.reduce(0) { $0 + $1.items.filter { !$0.done }.count }
        row(title: "持ち物", symbol: "bag.fill", tint: .indigo,
            line: bring.isEmpty ? "今日・明日の持ち物はありません" : left == 0 ? "すべて確認しました" : "まだ \(left)個（\(bring.count)件の予定・リスト）",
            running: false, progress: nil) {
            router.tasksPath = [.belongings]
        }
    }

    private func morningLine(_ m: MorningRoutine) -> String {
        if let r = m.active, let c = r.current { return "準備中 \(r.index + 1)/\(r.steps.count)・\(c.name)" }
        if let n = m.alarms.compactMap({ $0.next(after: model.now, time: model.time) }).min() {
            let t = model.time
            let d = t.isSameDay(n, model.now) ? "今日" : t.isSameDay(n, t.addDays(model.now, 1)) ? "明日" : t.dayLabel(n)
            return "起床 \(d) \(model.hm(n))・\(m.enabledSteps.count)工程"
        }
        return "\(m.enabledSteps.count)工程・アラームなし"
    }

    private func cleaningLine(_ b: CleaningBook) -> String {
        if let s = b.active {
            let c = CleaningSession.completion(s.statuses(in: b.areas).map(\.status))
            return "清掃中 \(c.done)/\(c.total)"
        }
        let n = b.neglected(now: model.now, time: model.time).count
        return n > 0 ? "そろそろ清掃する箇所 \(n)" : "すべて目標どおり"
    }

    private func row(title: String, symbol: String, tint: Color, line: String, running: Bool, progress: Double?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient)
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).foregroundStyle(.primary)
                        if running {
                            Text("進行中").font(.caption2.weight(.bold)).foregroundStyle(tint)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(tint.opacity(0.14)))
                        }
                    }
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let p = progress {
                    ZStack {
                        Circle().stroke(tint.opacity(0.2), lineWidth: 3)
                        Circle().trim(from: 0, to: p).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 20, height: 20)
                    .animation(Motion.value, value: p)
                    .accessibilityLabel("進み具合 \(Int(p * 100))%")
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("開きます")
    }
}
