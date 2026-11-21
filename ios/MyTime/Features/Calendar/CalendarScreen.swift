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

    /// 月の表示で、いま画面の一番上に見えている月（大きな見出しに出す）
    @State private var visibleMonth = Date()
    /// 年の表示（純正カレンダーの「< 2026年」）
    @State private var showYear = false
    @State private var searching = false
    @State private var showCalendars = false
    /// 月の表示の密度（純正の「コンパクト・スタック・詳細」）。月の表示の行の高さと同じ値
    @AppStorage("calendar.monthRowHeight2") private var monthRow: Double = 128
    @Namespace private var zoom

    var body: some View {
        NavigationStack {
            let day = model.time.startOfDay(model.time.ms(selected))
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let now = model.time.ms(ctx.date)
                VStack(spacing: 6) {
                    // 日・週・月・一覧の切り替えは右上のボタンへ（純正と同じく、画面の上を空ける）
                    // 見出しの行：左に月（日の表示は日付）、右に日・週・月の切り替え（純正と同じく1回で切り替える）
                    if !showYear && mode != "list" {
                        headerRow(day: day)
                            .transition(.opacity)
                    }
                    if mode == "day" || mode == "list" {
                        WeekStrip(selected: $selected)
                            .padding(.horizontal)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if mode == "day" {
                        allDayChips(day)
                    }
                    Group {
                        if showYear {
                            YearView(year: model.time.calendar.component(.year, from: visibleMonth), now: now) { m in
                                visibleMonth = m
                                selected = m
                                withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)) { showYear = false }
                                todayTick += 0
                            }
                            .transition(.asymmetric(insertion: .scale(scale: 1.15).combined(with: .opacity), removal: .scale(scale: 1.15).combined(with: .opacity)))
                        } else {
                            switch mode {
                            case "week":
                                WeekTimeline(selected: $selected, now: now) { d in open(d, from: .center) }
                            case "month":
                                MonthView(selected: $selected, todayTick: todayTick, visibleMonth: $visibleMonth) { d, p in open(d, from: p) }
                                    // 日へ行くとき：月はタップした所へ吸い込まれるように拡大して消える
                                    .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .scale(scale: 2.2, anchor: zoomAnchor).combined(with: .opacity)))
                            case "list":
                                AgendaList(from: day, days: 30, now: now, selected: day, hideEmpty: true) { selected = model.time.date($0) }
                            default:
                                dayView(day: day, now: now)
                                    // 月から来たとき：タップした日の位置から「ひゅっ」と広がる
                                    .transition(.asymmetric(insertion: .scale(scale: 0.08, anchor: zoomAnchor).combined(with: .opacity), removal: .opacity))
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.top, 2)
            }
            .background(Color(.systemBackground))
            .navigationTitle(mode == "list" ? title(day) : "")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCalendars) { CalendarsSheet().environment(model) }
            .animation(reduceMotion ? nil : .snappy, value: isShowingToday(day))
            .toolbar {
                // 左上：戻る（年・月）と「今日」（下に浮かべず、バーの空いている所に）
                ToolbarItem(placement: .topBarLeading) { backButton }
                ToolbarItem(placement: .topBarLeading) {
                    if !isShowingToday(day) {
                        Button { goToday() } label: {
                            Text("今日").font(.body.weight(.semibold)).foregroundStyle(Color.red)
                        }
                        .accessibilityLabel("今日へ移動")
                        .transition(.opacity)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    modeMenu
                    Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("検索")
                }
                MainToolbar(addKind: .event)
            }
            .sheet(isPresented: $searching) { CalendarSearchView().environment(model).environment(router) }
            .sensoryFeedback(.selection, trigger: mode)
            .sensoryFeedback(.impact(weight: .light), trigger: showYear)
        }
    }

    /// 見出しの行。月：大きな月の名前（今月は赤）／週：月の名前／日：2026年11月21日・土曜日。右に日・週・月の切り替え
    private func headerRow(day: EpochMs) -> some View {
        let isNow = model.time.calendar.isDate(visibleMonth, equalTo: Date(), toGranularity: .month)
        return HStack(alignment: .center, spacing: 8) {
            Group {
                switch mode {
                case "month":
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // 月の名前を押すと今月（今日の週）へ戻る
                        Text(visibleMonth.formatted(.dateTime.month(.wide)))
                            .onTapGesture { if !isNow { goToday() } }
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(isNow ? Color.red : Color.primary)
                            .contentTransition(.numericText())
                        if !model.time.calendar.isDate(visibleMonth, equalTo: Date(), toGranularity: .year) {
                            Text(visibleMonth.formatted(.dateTime.year())).font(.headline).foregroundStyle(.secondary)
                        }
                    }
                case "week":
                    Text(selected.formatted(.dateTime.year().month(.wide)))
                        .font(.title3.weight(.bold))
                default:
                    Text(model.time.date(day).formatted(.dateTime.month().day()) + " " + model.time.date(day).formatted(.dateTime.weekday(.wide)))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(model.time.isSameDay(day, model.now) ? Color.red : Color.primary)
                        .contentTransition(.numericText())
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            ModeSwitch(mode: Binding(get: { mode }, set: { v in
                showYear = false
                if v == "month" { visibleMonth = selected }
                withAnimation(reduceMotion ? nil : Motion.sheet) { mode = v }
            }))
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .animation(reduceMotion ? nil : .snappy, value: visibleMonth)
        .animation(reduceMotion ? nil : .snappy, value: day)
        .accessibilityAddTraits(.isHeader)
    }

    /// 左上：月なら「< 2026年」（年の表示へ）、日・週・一覧なら「< 11月」（月へ戻る）
    @ViewBuilder
    private var backButton: some View {
        if mode == "month" {
            if showYear {
                EmptyView()
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)) { showYear = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        Text(visibleMonth.formatted(.dateTime.year())).font(.body.weight(.medium))
                    }
                    .padding(.horizontal, 4)
                }
                .accessibilityLabel("年の表示へ")
            }
        } else {
            Button {
                visibleMonth = selected
                withAnimation(reduceMotion ? nil : Motion.sheet) { mode = "month" }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    Text(selected.formatted(.dateTime.month(.wide))).font(.body.weight(.medium))
                }
                .padding(.horizontal, 4)
            }
            .accessibilityLabel("月の表示へ")
        }
    }

    /// 表示の切り替え（純正と同じ）：月の密度「コンパクト・スタック・詳細」、日・週、「リスト」
    private var modeMenu: some View {
        Menu {
            Section {
                densityButton("コンパクト", "rectangle.compress.vertical", 56)
                densityButton("スタック", "rectangle.split.1x2", 96)
                densityButton("詳細", "rectangle.grid.1x2", 128)
            }
            Section {
                modeButton("日", "calendar.day.timeline.left", "day")
                modeButton("週", "calendar.badge.clock", "week")
                modeButton("リスト", "list.bullet", "list")
            }
            // 表示する人（自分・みお）。右上のボタンを減らすため、ここにまとめる
            if model.calendars.count > 1 {
                Section("表示する人") {
                    ForEach(model.calendars, id: \.id) { c in
                        Toggle(isOn: Binding(get: { c.visible }, set: { v in
                            if !v && model.calendars.filter(\.visible).count <= 1 { return }
                            model.setCalendarVisible(c.id, v)
                        })) { Label(c.name, systemImage: c.visible ? "person.crop.circle.fill" : "person.crop.circle") }
                    }
                }
            }
            // カレンダーの一覧と未割当（下に浮かべていたボタンをここへ）
            Section {
                Button { showCalendars = true } label: { Label("カレンダー", systemImage: "calendar") }
                Button { router.open(.inbox) } label: {
                    Label(model.inbox.isEmpty ? "未割当" : "未割当（\(model.inbox.count)）", systemImage: "tray")
                }
            }
        } label: {
            // 日・週・月は見出しの行で切り替えるので、ここは「その他の表示」のボタン
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("表示とカレンダー")
    }

    /// 月の表示で、その密度にする（今の表示が月でなければ月へ）
    private func densityButton(_ title: String, _ symbol: String, _ h: Double) -> some View {
        let on = mode == "month" && abs(monthRow - h) < 20 || (h == 128 && mode == "month" && monthRow > 148)
        return Button {
            showYear = false
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86)) { mode = "month"; monthRow = h }
        } label: {
            Label(title, systemImage: on ? "checkmark" : symbol)
        }
    }

    private func modeButton(_ title: String, _ symbol: String, _ m: String) -> some View {
        Button {
            showYear = false
            withAnimation(reduceMotion ? nil : Motion.sheet) { mode = m }
        } label: {
            Label(title, systemImage: mode == m ? "checkmark" : symbol)
        }
    }

    private func isShowingToday(_ day: EpochMs) -> Bool {
        if showYear { return false }
        if mode == "month" { return model.time.calendar.isDate(visibleMonth, equalTo: Date(), toGranularity: .month) }
        return model.time.isSameDay(day, model.now)
    }

    private func goToday() {
        withAnimation(reduceMotion ? nil : Motion.sheet) {
            showYear = false
            selected = Date()
            visibleMonth = Date()
        }
        todayTick += 1
    }

    private func title(_ day: EpochMs) -> String {
        switch mode {
        case "month": return "カレンダー"
        case "week":
            // 純正と同じく、週の表示の見出しは月の名前だけ
            return model.time.date(day).formatted(.dateTime.month(.wide))
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
                        ForEach(allDay.prefix(allDay.count > 2 ? 1 : 2)) { o in
                            let c = model.occurrenceColor(o)
                            Button { router.open(.event(o.id)) } label: {
                                HStack(spacing: 5) {
                                    if o.isStruck { Circle().fill(Color.gray).frame(width: 7, height: 7) }
                                    else { PersonAvatar(calendar: model.calendar(o.event.calendarId), size: 14) }
                                    Text(o.title).strikethrough(o.isStruck).font(.caption.weight(.semibold)).lineLimit(1)
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .glass(Capsule(), interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                        // 4件以上は「ほか N件」にまとめる（時刻のある予定の場所を取らない）
                        if allDay.count > 2 {
                            Menu {
                                ForEach(allDay.dropFirst(1)) { o in
                                    Button(o.title) { router.open(.event(o.id)) }
                                }
                            } label: {
                                Text("ほか\(allDay.count - 1)件").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .glass(Capsule(), interactive: true)
                            }
                            .accessibilityLabel("終日の予定 ほか\(allDay.count - 1)件")
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
        // 純正と同じく、見出しの行（予定・タスク）は出さずに時間軸を広く
        return VStack(spacing: 0) {
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
                                    // 純正の一覧と同じ見出し：今日は赤
                                    Text(model.time.dayLabel(d)).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(model.time.isSameDay(d, now) ? Color.red : .primary)
                                    if model.time.isSameDay(d, now) { Text("今日").font(.caption.weight(.bold)).foregroundStyle(Color.red) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .id(d)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.refreshAll() }
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
                    // 人のしるし（取り消した予定は灰色）
                    // ほかの人の予定は小さく・うすく（自分の予定を目立たせる）
                    let other = model.dimOther(o.event.calendarId)
                    PersonAvatar(calendar: model.calendar(o.event.calendarId), size: other ? 18 : 24)
                        .saturation(o.isStruck || other ? 0.2 : 1).opacity(o.isStruck ? 0.5 : other ? 0.6 : 1)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.title).strikethrough(o.isStruck).foregroundStyle(o.isStruck || model.dimOther(o.event.calendarId) ? .secondary : .primary).lineLimit(1)
                            .font(model.dimOther(o.event.calendarId) ? .subheadline : .body)
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
            // 右へなぞると取り消す（灰色と線だけ。削除はしない）・もう一度なぞると戻す
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    let snap = o.event
                    model.perform(o.isStruck ? "取り消しを戻しました" : "予定を取り消しました", undo: { try model.repo.saveEvent(snap, isNew: false) }) {
                        try model.repo.setStruck(eventId: o.masterId, originalStart: o.originalStart, struck: !o.isStruck)
                    }
                } label: { Label(o.isStruck ? "戻す" : "取り消す", systemImage: o.isStruck ? "arrow.uturn.backward" : "strikethrough") }
                .tint(o.isStruck ? .blue : .gray)
            }
        case .task(let t, let at):
            taskButton(t, at: at)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleteTask(t) } label: { Label("削除", systemImage: "trash") }
                }
                // 右へなぞると完了（確認のタスクは確認済み）
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        if t.kind == .check {
                            model.perform(t.checked ? "未確認に戻しました" : "確認しました", undo: { try model.repo.toggleCheck(t.id) }) { try model.repo.toggleCheck(t.id) }
                        } else if t.status != .done {
                            model.perform("完了しました", undo: { try model.repo.taskAction(t.id, .undoFinish) }) { try model.repo.taskAction(t.id, .finish) }
                        }
                    } label: { Label(t.isDone ? "済み" : "完了", systemImage: "checkmark") }
                    .tint(.green)
                }
        case .due(let t, let at):
            dueRow(t, at: at)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { model.perform("完了しました", undo: { try model.repo.taskAction(t.id, .undoFinish) }) { try model.repo.taskAction(t.id, .finish) } } label: {
                        Label("完了", systemImage: "checkmark")
                    }.tint(.green)
                }
                .swipeActions(edge: .trailing) {
                    // 締切を1日のばす（予定の種類の締切 dueAt を動かす）
                    Button {
                        var x = t
                        var spec = x.extra?["spec"]?.objectValue ?? [:]
                        var det = spec["details"]?.objectValue ?? [:]
                        det["dueAt"] = .number(Double(at + DAY))
                        spec["details"] = .object(det)
                        x.extra = (x.extra ?? .object([:])).merging(.object(["spec": .object(spec)]))
                        model.perform("締切を1日のばしました", undo: { try model.repo.saveTask(t, isNew: false) }) { try model.repo.saveTask(x, isNew: false) }
                    } label: { Label("1日のばす", systemImage: "calendar.badge.plus") }.tint(.orange)
                }
        }
    }

    private func deleteEvent(_ o: EventOccurrence) {
        guard let snapshot = model.repo.event(o.masterId) else { return }
        if let os = o.originalStart, snapshot.recurrence != nil {
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


/// ナビゲーションバーの「人」のボタン。押すと自分・みおの予定を出す／隠すを選べる（予定は消えない）
struct PeopleMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shown = model.calendars.filter(\.visible)
        Menu {
            Section("表示する人") {
                ForEach(model.calendars, id: \.id) { c in
                    Toggle(isOn: Binding(get: { c.visible }, set: { v in
                        // 全員を隠すことはしない（何も出ない画面にしない）
                        if !v && shown.count <= 1 { return }
                        model.setCalendarVisible(c.id, v)
                    })) {
                        Label(c.name, systemImage: c.visible ? "person.crop.circle.fill" : "person.crop.circle")
                    }
                }
            }
            Section {
                Button("全員を表示", systemImage: "person.2.fill") {
                    for c in model.calendars where !c.visible { model.setCalendarVisible(c.id, true) }
                }
                .disabled(shown.count == model.calendars.count)
            }
        } label: {
            // 出している人のしるしを重ねて見せる（全員なら2人、片方ならその人）
            HStack(spacing: -6) {
                ForEach(shown.prefix(2), id: \.id) { c in
                    PersonAvatar(calendar: c, size: 22)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityLabel("表示する人：" + shown.map(\.name).joined(separator: "・"))
    }
}


/// カレンダーの一覧（純正の「カレンダー」と同じ形：人ごとに色の丸のチェック、押して出す・隠す）
struct CalendarsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.calendars, id: \.id) { c in
                        Button {
                            // 全員を隠すことはしない
                            if c.visible && model.calendars.filter(\.visible).count <= 1 { return }
                            model.setCalendarVisible(c.id, !c.visible)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: c.visible ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(Color(hex: c.color))
                                    .contentTransition(.symbolEffect(.replace))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).foregroundStyle(.primary)
                                    Text(c.id == MTCalendar.selfId ? "今日の画面にも出ます" : "カレンダーにだけ、うすく出ます")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                PersonAvatar(calendar: c, size: 26)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // 左へなぞると「この人だけ」
                        .swipeActions(edge: .trailing) {
                            Button {
                                for x in model.calendars { model.setCalendarVisible(x.id, x.id == c.id) }
                            } label: { Label("この人だけ", systemImage: "person.crop.circle.badge.checkmark") }
                            .tint(Color(hex: c.color))
                        }
                    }
                } header: {
                    Text("人")
                } footer: {
                    Text("チェックを外した人の予定は、カレンダーに出しません（予定は消えません）。")
                }
                Section {
                    Button("すべて表示") {
                        for c in model.calendars where !c.visible { model.setCalendarVisible(c.id, true) }
                    }
                    .disabled(model.calendars.allSatisfy(\.visible))
                }
            }
            .navigationTitle("カレンダー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("閉じる")
                }
            }
            .sensoryFeedback(.selection, trigger: model.calendars.map(\.visible))
        }
        .presentationDetents([.medium, .large])
    }
}


/// 日・週・月の小さな切り替え（見出しの行の右。押すとすぐ切り替わる）
struct ModeSwitch: View {
    @Binding var mode: String
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let items = [("day", "日"), ("week", "週"), ("month", "月")]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                let on = mode == item.0
                Button { mode = item.0 } label: {
                    Text(item.1)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .frame(width: 38, height: 28)
                        .background {
                            if on {
                                // 明るい画面では白、暗い画面では一段明るい灰色（純正の切り替えと同じ）
                                Capsule().fill(Color(.tertiarySystemBackground))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.1 + "の表示")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: mode)
        .sensoryFeedback(.selection, trigger: mode)
    }
}
