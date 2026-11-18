import SwiftUI
import MyTimeCore

/// カレンダー。上にガラスの「日・週・月・一覧」と週の帯、下にそれぞれの表示。
/// 日：今日の画面と同じ時刻軸（予定が主、右にタスクの細いレーン）／週：日ごとの列を左右になぞって1週間／
/// 月：純正カレンダーと同じ操作の月表示／一覧：30日分
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected = Date()
    @AppStorage("calendarMode") private var mode = "day"
    @State private var swipeEdge: Edge = .trailing
    @State private var todayTick = 0
    /// 月から日へ広がるときの起点（タップした位置）
    @State private var zoomAnchor: UnitPoint = .center

    var body: some View {
        NavigationStack {
            let day = model.time.startOfDay(model.time.ms(selected))
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let now = model.time.ms(ctx.date)
                VStack(spacing: 8) {
                    GlassSegmented(items: [
                        .init(value: "day", title: "日"), .init(value: "week", title: "週"),
                        .init(value: "month", title: "月"), .init(value: "list", title: "一覧"),
                    ], selection: $mode.animation(reduceMotion ? nil : Motion.sheet))
                    .padding(.horizontal)
                    if mode == "day" || mode == "list" {
                        WeekStrip(selected: $selected)
                            .padding(.horizontal)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if mode == "day" { allDayChips(day) }
                    Group {
                        switch mode {
                        case "week":
                            WeekTimeline(selected: $selected, now: now) { d in open(d, from: .center) }
                        case "month":
                            MonthView(selected: $selected, todayTick: todayTick) { d, p in open(d, from: p) }
                                // 日へ行くとき：月はタップした所へ吸い込まれるように拡大して消える
                                .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 2.2, anchor: zoomAnchor).combined(with: .opacity)))
                        case "list":
                            AgendaList(from: day, days: 30, now: now, selected: day, hideEmpty: true) { selected = model.time.date($0) }
                        default:
                            dayView(day: day, now: now)
                                // 月から来たとき：タップした日の位置から「ひゅっ」と広がる
                                .transition(.asymmetric(insertion: .scale(scale: 0.08, anchor: zoomAnchor).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.top, 4)
            }
            .background(Color(.systemBackground))
            .navigationTitle(title(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(reduceMotion ? nil : Motion.sheet) { selected = Date() }
                        todayTick += 1
                    } label: {
                        Text("今日").font(.subheadline.weight(.semibold))
                            .foregroundStyle(model.time.isSameDay(day, model.now) ? Color.secondary : Color.red)
                    }
                    .accessibilityLabel("今日へ移動")
                }
                MainToolbar(addKind: .event)
            }
        }
    }

    private func title(_ day: EpochMs) -> String {
        switch mode {
        case "month": return "カレンダー"
        case "week":
            let ws = model.time.addDays(day, -model.time.weekday(day))
            return "\(model.time.calendar.component(.month, from: model.time.date(ws)))月\(model.time.calendar.component(.day, from: model.time.date(ws)))日の週"
        default: return model.dayTitle(day)
        }
    }

    /// 週・月から日の表示へ（月からは、タップした所から広がる）
    private func open(_ d: EpochMs, from anchor: UnitPoint) {
        zoomAnchor = anchor
        selected = model.time.date(d)
        withAnimation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.82)) { mode = "day" }
    }

    /// 終日の予定（ガラスの札）
    @ViewBuilder
    private func allDayChips(_ day: EpochMs) -> some View {
        let allDay = model.visibleEvents(from: day, to: model.time.addDays(day, 1), includeStruck: true).filter { $0.event.allDay }
        if !allDay.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(allDay.prefix(allDay.count > 3 ? 2 : 3)) { o in
                            let c = model.occurrenceColor(o)
                            Button { router.open(.event(o.id)) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(c).frame(width: 7, height: 7)
                                    Text(o.title).strikethrough(o.isStruck).font(.caption.weight(.semibold)).lineLimit(1)
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .glass(Capsule(), interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                        // 4件以上は「ほか N件」にまとめる（時刻のある予定の場所を取らない）
                        if allDay.count > 3 {
                            Menu {
                                ForEach(allDay.dropFirst(2)) { o in
                                    Button(o.title) { router.open(.event(o.id)) }
                                }
                            } label: {
                                Text("ほか\(allDay.count - 2)件").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .glass(Capsule(), interactive: true)
                            }
                            .accessibilityLabel("終日の予定 ほか\(allDay.count - 2)件")
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// 日の表示：予定が主、右にタスクの細いレーン（今日の画面より細く）
    private func dayView(day: EpochMs, now: EpochMs) -> some View {
        let occ = model.visibleEvents(from: model.time.addDays(day, -1), to: model.time.addDays(day, 2), includeStruck: true)
        return VStack(spacing: 0) {
            GeometryReader { geo in
                let w = geo.size.width - DayTimeline.gutter
                HStack(spacing: 0) {
                    Color.clear.frame(width: DayTimeline.gutter)
                    Label("予定", systemImage: "calendar").frame(width: w * 0.7, alignment: .leading).padding(.leading, 6)
                    Label("タスク", systemImage: "checklist").frame(width: w * 0.3, alignment: .leading).padding(.leading, 4)
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(height: 18)
            Divider()
            DayTimeline(day: day, now: now, events: occ, tasks: model.tasks, mainFraction: 0.7, onSwipeDay: { n in
                swipeEdge = n < 0 ? .trailing : .leading
                withAnimation(Motion.sheet) { selected = Calendar.current.date(byAdding: .day, value: n < 0 ? 1 : -1, to: selected) ?? selected }
            })
                .id(day)
                .transition(reduceMotion ? .opacity : .push(from: swipeEdge))
        }
    }
}

struct AgendaList: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let from: EpochMs
    let days: Int
    let now: EpochMs
    let selected: EpochMs
    var hideEmpty = false
    let select: (EpochMs) -> Void

    private enum Item: Identifiable {
        case event(EventOccurrence), task(MTTask, EpochMs), due(MTTask, EpochMs)
        var id: String {
            switch self {
            case .event(let o): return "e:\(o.id)"
            case .task(let t, _): return "t:\(t.id)"
            case .due(let t, _): return "d:\(t.id)"
            }
        }
        var at: EpochMs {
            switch self {
            case .event(let o): return o.event.allDay ? o.start - 1 : o.start
            case .task(_, let a), .due(_, let a): return a
            }
        }
    }

    var body: some View {
        let to = model.time.addDays(from, days)
        let occ = model.visibleEvents(from: from, to: to, includeStruck: true)
        let dayList = (0..<days).map { model.time.addDays(from, $0) }
        ScrollViewReader { proxy in
            List {
                ForEach(dayList, id: \.self) { d in
                    let items = items(on: d, occ: occ)
                    if !(hideEmpty && items.isEmpty) {
                        Section {
                            if items.isEmpty {
                                // 空の日：その日に予定を追加できる
                                Button { router.open(.editor(EditorSeed(kind: .event, start: d + 9 * HOUR, end: d + 10 * HOUR))) } label: {
                                    HStack {
                                        Text("予定はありません").foregroundStyle(.tertiary)
                                        Spacer()
                                        Label("追加", systemImage: "plus").font(.subheadline.weight(.semibold))
                                    }
                                    .font(.subheadline)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(model.time.dayLabel(d))に予定を追加")
                            }
                            ForEach(items) { row($0) }.tint(.primary)
                        } header: {
                            Button { select(d) } label: {
                                HStack {
                                    Text(model.time.dayLabel(d)).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(model.time.isSameDay(d, now) ? Color.accentColor : d == selected ? .primary : .secondary)
                                    if model.time.isSameDay(d, now) { Text("今日").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .id(d)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onAppear { proxy.scrollTo(selected, anchor: .top) }
        }
    }

    private func items(on d: EpochMs, occ: [EventOccurrence]) -> [Item] {
        let d1 = model.time.addDays(d, 1)
        var out: [Item] = occ.filter { $0.start < d1 && $0.end > d && ($0.event.allDay || model.time.isSameDay($0.start, d) || $0.start < d) }.map { .event($0) }
        for t in model.tasks {
            if t.kind == .do, let s = t.plannedStart, s >= d, s < d1 { out.append(.task(t, s)) }
            else if t.kind == .check, let c = t.checkAt, c >= d, c < d1 { out.append(.task(t, c)) }
            if let due = t.deadline, due >= d, due < d1, !t.isDone { out.append(.due(t, due)) }
        }
        return out.sorted { $0.at < $1.at }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .event(let o):
            Button { router.open(.event(o.id)) } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(model.occurrenceColor(o)).frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.title).strikethrough(o.isStruck).foregroundStyle(.primary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(o.event.allDay ? "終日" : "\(model.hm(o.start))〜\(model.hm(o.end))").monospacedDigit()
                            if let p = o.event.placeName, !p.isEmpty { Label(p, systemImage: "mappin").lineLimit(1) }
                            if o.event.recurrence != nil { Image(systemName: "repeat").accessibilityLabel("繰り返し") }
                            if isShiftPending(o.event) { PendingBadge() }
                            if o.isStruck { StruckBadge() }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu {
                Button("開く", systemImage: "arrow.up.forward.app") { router.open(.event(o.id)) }
                Button("編集", systemImage: "pencil") { router.open(.editor(EditorSeed(kind: .event, eventId: o.masterId))) }
                Divider()
                Button(o.isOccurrence ? "この回を削除" : "削除", systemImage: "trash", role: .destructive) { deleteEvent(o) }
            }
            // 純正カレンダー・リマインダーと同じく、左へなぞると削除（取り消せる）
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleteEvent(o) } label: {
                    Label(o.isOccurrence ? "この回を削除" : "削除", systemImage: "trash")
                }
            }
        case .task(let t, let at):
            taskButton(t, at: at)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleteTask(t) } label: { Label("削除", systemImage: "trash") }
                }
        case .due(let t, let at):
            dueRow(t, at: at)
        }
    }

    private func deleteEvent(_ o: EventOccurrence) {
        let snapshot = o.event
        if let os = o.originalStart, o.event.recurrence != nil {
            model.perform("この回を削除しました", undo: { try model.repo.saveEvent(snapshot, isNew: false) }) { try model.repo.cancelOccurrence(masterId: o.masterId, originalStart: os) }
        } else {
            model.perform("削除しました", undo: { try model.repo.saveEvent(snapshot, isNew: true) }) { try model.repo.deleteEvent(o.masterId) }
        }
    }

    private func deleteTask(_ t: MTTask) {
        let snapshot = t
        model.perform("削除しました", undo: { try model.repo.saveTask(snapshot, isNew: true) }) { try model.repo.deleteTask(t.id) }
    }

    private func taskButton(_ t: MTTask, at: EpochMs) -> some View {
            Button { router.open(.task(t.id)) } label: {
                HStack(spacing: 10) {
                    Image(systemName: t.isDone ? "checkmark.circle.fill" : t.kind == .check ? "circle" : "play.circle").foregroundStyle(t.isDone ? .green : .secondary).frame(width: 4 + 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).foregroundStyle(t.isDone ? .secondary : .primary).strikethrough(t.isDone).lineLimit(1)
                        Text(t.kind == .check ? "\(model.hm(at)) 確認" : "\(model.hm(at))〜\(t.plannedEnd.map(model.hm) ?? "")").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
    }

    private func dueRow(_ t: MTTask, at: EpochMs) -> some View {
            Button { router.open(.task(t.id)) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "flag.fill").foregroundStyle(.red).frame(width: 22)
                    Text("締切：\(t.title)").foregroundStyle(.primary).lineLimit(1)
                    Spacer()
                    Text(model.hm(at)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
    }
}
