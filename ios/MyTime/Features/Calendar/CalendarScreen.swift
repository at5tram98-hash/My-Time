import SwiftUI
import MyTimeCore

/// カレンダー。上に月（標準の日付選択）、下に選んだ日の時刻軸。終日の予定は時刻軸の上に並べる
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var selected = Date()
    @State private var showMonth = true
    /// 表示：日（時刻軸）・週（7日の一覧）・一覧（30日）
    @AppStorage("calendarMode") private var mode = "day"
    @State private var swipeEdge: Edge = .trailing

    var body: some View {
        NavigationStack {
            let day = model.time.startOfDay(model.time.ms(selected))
            let occ = model.visibleEvents(from: model.time.addDays(day, -1), to: model.time.addDays(day, 2))
            let allDay = occ.filter { $0.event.allDay && $0.start < model.time.addDays(day, 1) && $0.end > day }
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                VStack(spacing: 0) {
                    if showMonth {
                        DatePicker("日付", selection: $selected, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .padding(.horizontal)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !allDay.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(allDay) { o in
                                    Button { router.open(.event(o.id)) } label: {
                                        Label(o.title, systemImage: "sun.max").font(.caption.weight(.semibold))
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(Capsule().fill(Color(hex: model.eventColor(o.event)).opacity(0.2)))
                                            .foregroundStyle(Color(hex: model.eventColor(o.event)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical, 6)
                    }
                    Picker("表示", selection: $mode.animation(Motion.sheet)) {
                        Text("日").tag("day")
                        Text("週").tag("week")
                        Text("一覧").tag("list")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    Divider()
                    switch mode {
                    case "week":
                        AgendaList(from: model.time.addDays(day, -model.time.weekday(day)), days: 7, now: model.time.ms(ctx.date), selected: day) { selected = model.time.date($0) }
                    case "list":
                        AgendaList(from: day, days: 30, now: model.time.ms(ctx.date), selected: day, hideEmpty: true) { selected = model.time.date($0) }
                    default:
                        DayTimeline(day: day, now: model.time.ms(ctx.date), events: occ, tasks: model.tasks, mainFraction: nil)
                            .id(day)
                            .transition(.push(from: swipeEdge))
                            // 左右にスワイプで前の日・次の日（今日の画面と同じ操作）
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 40).onEnded { v in
                                    guard abs(v.translation.width) > 80, abs(v.translation.width) > abs(v.translation.height) * 1.6 else { return }
                                    let n = v.translation.width < 0 ? 1 : -1
                                    swipeEdge = n > 0 ? .trailing : .leading
                                    withAnimation(Motion.sheet) { selected = Calendar.current.date(byAdding: .day, value: n, to: selected) ?? selected }
                                }
                            )
                    }
                }
            }
            .navigationTitle(model.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(showMonth ? "月をたたむ" : "月を表示", systemImage: showMonth ? "chevron.up" : "calendar") {
                        withAnimation(Motion.sheet) { showMonth.toggle() }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("今日") { withAnimation(Motion.sheet) { selected = Date() } }
                        .disabled(Calendar.current.isDateInToday(selected))
                }
                MainToolbar(addKind: .event)
            }
        }
    }
}


/// 複数日の一覧（予定・時刻のあるタスク・締切）。日付をタップするとその日を選ぶ
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
        let occ = model.visibleEvents(from: from, to: to)
        let dayList = (0..<days).map { model.time.addDays(from, $0) }
        ScrollViewReader { proxy in
            List {
                ForEach(dayList, id: \.self) { d in
                    let items = items(on: d, occ: occ)
                    if !(hideEmpty && items.isEmpty) {
                        Section {
                            if items.isEmpty {
                                Text("予定はありません").font(.subheadline).foregroundStyle(.tertiary)
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
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: model.eventColor(o.event))).frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.title).foregroundStyle(.primary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(o.event.allDay ? "終日" : "\(model.hm(o.start))〜\(model.hm(o.end))").monospacedDigit()
                            if let p = o.event.placeName, !p.isEmpty { Label(p, systemImage: "mappin").lineLimit(1) }
                            if o.event.recurrence != nil { Image(systemName: "repeat").accessibilityLabel("繰り返し") }
                            if isShiftPending(o.event) { PendingBadge() }
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
