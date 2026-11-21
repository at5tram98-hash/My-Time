import SwiftUI
import MyTimeCore

/// 今日の上のカードの一番下に、5秒ごとに入れ替わるお知らせ（1行）。
/// 出発の時刻・遅れ・このあとの予定・持ち物・次の空き時間・明日の起床など、そのとき役に立つものだけを出す。
/// 純正アプリと同じく、色は記号だけに付け、文は短く。押すと次へ、長押し（読み上げの操作）で開く。
struct NowTicker: View {
    var now: EpochMs
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var paused = false

    struct Item: Identifiable, Equatable {
        var id: String
        var symbol: String
        var tint: Color
        var text: String
        /// 右に小さく（「あと12分」など）
        var trailing: String? = nil
        var open: SheetRoute? = nil
        var openTasks: TasksRoute? = nil
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.text == b.text && a.trailing == b.trailing }
    }

    var body: some View {
        let items = makeItems()
        if !items.isEmpty {
            let i = index % items.count
            let it = items[i]
            HStack(spacing: 8) {
                Image(systemName: it.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(it.tint)
                    .frame(width: 20)
                    .contentTransition(.symbolEffect(.replace))
                Text(it.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 6)
                if let t = it.trailing {
                    Text(t).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(it.tint)
                        .lineLimit(1)
                }
                // いくつ目か（2つ以上のとき）
                if items.count > 1 {
                    HStack(spacing: 3) {
                        ForEach(0..<min(items.count, 6), id: \.self) { k in
                            Capsule().fill(k == i ? Color.primary.opacity(0.55) : Color.primary.opacity(0.15))
                                .frame(width: k == i ? 10 : 4, height: 4)
                        }
                    }
                    .animation(reduceMotion ? nil : .snappy, value: i)
                    .accessibilityHidden(true)
                }
            }
            .id(it.id)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
            .frame(height: 22)
            .clipped()
            .contentShape(Rectangle())
            // 押すと次へ、長押しでそのお知らせを開く
            .onTapGesture { advance(items.count) }
            .onLongPressGesture(minimumDuration: 0.35) { open(it) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(it.text + (it.trailing.map { "、\($0)" } ?? ""))
            .accessibilityHint(items.count > 1 ? "ダブルタップで次のお知らせ" : "")
            .accessibilityAction { advance(items.count) }
            .accessibilityAction(named: "開く") { open(it) }
            .task(id: items.count) {
                // 5秒ごとに次へ（読み上げ中・動きを減らす設定では、自動では変えない）
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, !UIAccessibility.isVoiceOverRunning, !reduceMotion else { continue }
                    advance(items.count)
                }
            }
            .sensoryFeedback(.selection, trigger: index)
        }
    }

    private func advance(_ count: Int) {
        guard count > 1 else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.9)) { index = (index + 1) % count }
    }

    private func open(_ it: Item) {
        if let r = it.open { router.open(r) } else if let t = it.openTasks { router.openTasks(t) }
    }

    // MARK: お知らせを集める（大事な順）

    private func makeItems() -> [Item] {
        var out: [Item] = []
        let t = model.time
        let d0 = t.startOfDay(now), d1 = t.addDays(d0, 1)
        let mine = model.myEvents(from: now - 6 * HOUR, to: t.addDays(d0, 2)).filter { !$0.event.allDay }.sorted { $0.start < $1.start }
        let upcoming = mine.filter { $0.start > now }

        // 1. 出発の時刻（移動時間のある次の予定。出発の2時間前から）
        if let o = upcoming.first(where: { ($0.event.travelMinutes ?? 0) > 0 && $0.start < d1 }) {
            let leave = o.start - EpochMs(o.event.travelMinutes ?? 0) * MINUTE
            let left = Int((leave - now) / MINUTE)
            if left <= 120 {
                out.append(Item(id: "leave:\(o.id)", symbol: left <= 0 ? "figure.walk.departure" : "tram.fill", tint: left <= 10 ? .red : .orange,
                                text: left <= 0 ? "出発の時刻を過ぎています・\(o.title)" : "\(t.hm(leave))に出発・\(o.title)",
                                trailing: left <= 0 ? "今すぐ" : "あと\(durationShort(left))", open: .event(o.id)))
            }
        }
        // 2. 遅れ（予定の終わりを過ぎても終わっていないタスク）
        let late = model.tasks.filter { !$0.isDone && $0.kind == .do && ($0.plannedEnd.map { $0 < now && $0 >= d0 } ?? false) }
        if let f = late.first {
            out.append(Item(id: "late", symbol: "exclamationmark.circle.fill", tint: .red,
                            text: late.count == 1 ? "「\(f.title)」が遅れています" : "\(late.count)件のタスクが遅れています",
                            trailing: late.count == 1 ? lateText(now - (f.plannedEnd ?? now)) : nil,
                            open: late.count == 1 ? .task(f.id) : nil))
        }
        // 3. 締切が近いもの（24時間以内）
        if let due = model.tasks.filter({ !$0.isDone && ($0.deadline.map { $0 > now && $0 < now + 24 * HOUR } ?? false) }).min(by: { $0.deadline! < $1.deadline! }) {
            out.append(Item(id: "due:\(due.id)", symbol: "flag.fill", tint: .orange, text: "締切「\(due.title)」",
                            trailing: "\(t.hm(due.deadline!))まで", open: .task(due.id)))
        }
        // 4. このあとの予定（いま最中のものの次）
        if let n = upcoming.first(where: { $0.start < d1 }) {
            let place = n.event.classInfo?["room"]?.stringValue.flatMap { $0.isEmpty ? nil : "\($0)教室" } ?? n.event.placeName
            out.append(Item(id: "next:\(n.id)", symbol: "calendar", tint: model.occurrenceColor(n),
                            text: "\(t.hm(n.start)) \(n.title)" + (place.map { "・\($0)" } ?? ""),
                            trailing: "あと\(durationShort(Int((n.start - now) / MINUTE)))", open: .event(n.id)))
        }
        // 5. 持ち物（今日の予定のもの）
        let groups = BelongingsList.items(model: model).filter { g in g.left > 0 && (g.when.map { $0 < d1 } ?? true) }
        let left = groups.reduce(0) { $0 + $1.left }
        if left > 0 {
            out.append(Item(id: "bring", symbol: "bag.fill", tint: .brown, text: "持ち物の確認がまだ\(left)つ", openTasks: .belongings))
        }
        // 6. 次の空き時間（30分以上）
        if let gap = nextGap(mine.filter { $0.start < d1 }, d1: d1), gap.minutes >= 30 {
            out.append(Item(id: "gap", symbol: "hourglass", tint: .teal,
                            text: "空き時間 \(t.hm(gap.start))〜\(t.hm(gap.start + EpochMs(gap.minutes) * MINUTE))",
                            trailing: durationShort(gap.minutes)))
        }
        // 7. 今日のタスクの残り
        let dayTasks = tasksForDay(model.tasks, day: d0, time: t)
        let notDone = dayTasks.filter { !$0.isDone }.count
        if !dayTasks.isEmpty {
            out.append(Item(id: "tasks", symbol: notDone == 0 ? "checkmark.circle.fill" : "checklist", tint: notDone == 0 ? .green : .blue,
                            text: notDone == 0 ? "今日のタスクはすべて完了" : "今日のタスク あと\(notDone)件",
                            trailing: "\(dayTasks.count - notDone)/\(dayTasks.count)", openTasks: nil))
        }
        // 8. 夜は明日の起床アラームと最初の予定
        if t.minutesOfDay(now) >= 18 * 60 {
            if let a = model.morning.alarms.filter(\.enabled).compactMap({ $0.next(after: now, time: t) }).min(), a < t.addDays(d1, 1) {
                out.append(Item(id: "wake", symbol: "alarm.fill", tint: .orange, text: "明日は\(t.hm(a))に起床アラーム", openTasks: .morning))
            }
            if let f = mine.first(where: { $0.start >= d1 }) {
                out.append(Item(id: "tomorrow", symbol: "sunrise.fill", tint: .indigo, text: "明日の最初は\(t.hm(f.start)) \(f.title)", open: .event(f.id)))
            }
        }
        return Array(out.prefix(6))
    }

    /// 今から今日の終わりまでで、予定のない最初の時間
    private func nextGap(_ events: [EventOccurrence], d1: EpochMs) -> (start: EpochMs, minutes: Int)? {
        var cursor = ((now / (5 * MINUTE)) + 1) * 5 * MINUTE
        for o in events.sorted(by: { $0.start < $1.start }) where o.end > cursor {
            if o.start > cursor { return (cursor, Int((o.start - cursor) / MINUTE)) }
            cursor = max(cursor, o.end)
        }
        let end = min(d1, model.time.startOfDay(now) + 23 * HOUR)
        return end > cursor ? (cursor, Int((end - cursor) / MINUTE)) : nil
    }

    private func durationShort(_ m: Int) -> String {
        m >= 60 ? (m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分") : "\(max(0, m))分"
    }

    private func lateText(_ ms: EpochMs) -> String { "\(durationShort(Int(ms / MINUTE)))遅れ" }
}
