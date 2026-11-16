import SwiftUI
import MyTimeCore

/// 今日（1日だけの画面）。
/// 上：今やること1枚と状況のチップ。下：共通の時刻軸に、左＝時間の決まった予定、右＝細かなタスク。
/// 横スワイプで日付を変える。レーンの見出しをタップすると、そのレーンを広くする。
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var day: EpochMs = DomainTime.current.startOfDay(EpochMs(Date().timeIntervalSince1970 * 1000))
    @State private var collapsed = false
    @State private var showDatePicker = false
    @State private var direction: Edge = .trailing
    /// 翌日計画のレーン（右端・灰色）を出すか
    @AppStorage("today.showTomorrow") private var showTomorrow = true

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let now = model.time.ms(ctx.date)
                content(now: now)
            }
            .navigationTitle(model.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 日付と今の時刻を5秒ごとに入れ替える
                ToolbarItem(placement: .principal) {
                    DateClockTitle(title: model.dayTitle(day), isToday: model.time.isSameDay(day, model.now)) { showDatePicker = true }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("今日へ移動", systemImage: "calendar.badge.clock") { go(to: model.time.startOfDay(model.now)) }
                            .disabled(model.time.isSameDay(day, model.now))
                        Button("日付を選択", systemImage: "calendar") { showDatePicker = true }
                        Divider()
                        Button("文章で追加", systemImage: "text.bubble") { router.open(.quickAdd) }
                        Button("計画の支援", systemImage: "wand.and.stars") { router.open(.planAssist) }
                        Divider()
                        Toggle(isOn: $showTomorrow.animation(Motion.sheet)) { Label("翌日計画を表示", systemImage: "moon.stars") }
                        Divider()
                        Picker("レーンの幅", selection: Binding(get: { model.settings.laneFocus }, set: { v in model.updateSettings { $0.laneFocus = v } })) {
                            Label("予定とタスクを同じ幅で", systemImage: "rectangle.split.2x1").tag("both")
                            Label("予定を広く", systemImage: "calendar").tag("main")
                            Label("タスクを広く", systemImage: "checklist").tag("detail")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("その他の操作")
                }
                MainToolbar()
            }
            .sheet(isPresented: $showDatePicker) {
                NavigationStack {
                    DatePicker("日付", selection: Binding(get: { model.time.date(day) }, set: { go(to: model.time.startOfDay(model.time.ms($0))); showDatePicker = false }), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .navigationTitle("日付を選択")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showDatePicker = false } } }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func go(to d: EpochMs) {
        direction = d > day ? .trailing : .leading
        if reduceMotion { day = d } else { withAnimation(Motion.sheet) { day = d } }
    }

    @ViewBuilder
    private func content(now: EpochMs) -> some View {
        let d1 = model.time.addDays(day, 1)
        let occ = model.visibleEvents(from: model.time.addDays(day, -1), to: model.time.addDays(day, 2))
        let dayTasks = orderHomeTasks(tasksForDay(model.tasks, day: day, time: model.time), now: now)
        let done = dayTasks.filter(\.isDone).count
        let busy = busyItems(events: occ, tasks: model.tasks)
        let freeMin = freeMinutes(day: day, now: now, busy: busy)
        let next = nextAction(events: occ, tasks: model.tasks, now: now, time: model.time)
        let dayEvents = occ.filter { $0.start < d1 && $0.end > day && !$0.event.allDay }
        let focus = model.settings.laneFocus
        let mainFraction: CGFloat = focus == "main" ? 0.68 : focus == "detail" ? 0.34 : 0.52
        // 翌日計画は、今日（とそれより前）を見ているときだけ右端に出す
        let tomorrowFraction: CGFloat? = showTomorrow && day <= model.time.startOfDay(now) ? 0.24 : nil
        let tomorrowCount = tomorrowItemCount(after: day)

        VStack(spacing: 8) {
            // 今日を見ているときだけ、状況に合わせたカード（何もなければ時計と明日の最初の予定）
            if !collapsed && model.time.isSameDay(day, now) {
                NowCard(next: next, now: now, occurrences: occ)
                    .padding(.horizontal)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            // 画面幅に収まる形を選ぶ：通常のラベル → 短いラベル → それでも入らなければ横スクロール（大きな文字サイズのとき）
            let taskValue = dayTasks.isEmpty ? "0" : "\(done)/\(dayTasks.count)"
            let isToday = model.time.isSameDay(day, now)
            ViewThatFits(in: .horizontal) {
                statusRow(taskLabel: isToday ? "今日のタスク" : "タスク", taskValue: taskValue, freeMin: freeMin, isToday: isToday, now: now)
                    .padding(.horizontal)
                statusRow(taskLabel: isToday ? "今日" : "タスク", taskValue: taskValue, freeMin: freeMin, isToday: isToday, now: now)
                    .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    statusRow(taskLabel: isToday ? "今日" : "タスク", taskValue: taskValue, freeMin: freeMin, isToday: isToday, now: now)
                        .padding(.horizontal)
                }
            }
            laneHeader(mainFraction: mainFraction, tomorrowFraction: tomorrowFraction, events: dayEvents.count, tasks: dayTasks.count, tomorrow: tomorrowCount, focus: focus)
            DayTimeline(day: day, now: now, events: occ, tasks: model.tasks, mainFraction: mainFraction, tomorrowFraction: tomorrowFraction)
                .id(day)
                .transition(reduceMotion ? .opacity : .push(from: direction))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 40).onEnded { v in
                        guard abs(v.translation.width) > 80, abs(v.translation.width) > abs(v.translation.height) * 1.6 else { return }
                        go(to: model.time.addDays(day, v.translation.width < 0 ? 1 : -1))
                    }
                )
        }
        .padding(.top, 4)
        .background(Color(.systemBackground))
    }

    private func laneHeader(mainFraction: CGFloat, tomorrowFraction: CGFloat?, events: Int, tasks: Int, tomorrow: Int, focus: String) -> some View {
        GeometryReader { geo in
            let full = geo.size.width - DayTimeline.gutter
            let w = full * (1 - (tomorrowFraction ?? 0))
            HStack(spacing: 0) {
                Color.clear.frame(width: DayTimeline.gutter)
                laneButton("予定", symbol: "calendar", count: events, on: focus == "main", width: w * mainFraction) { toggleFocus("main") }
                laneButton("タスク", symbol: "checklist", count: tasks, on: focus == "detail", width: w * (1 - mainFraction)) { toggleFocus("detail") }
                if let t = tomorrowFraction {
                    // 翌日計画の見出し（タップで明日の画面へ）
                    Button { go(to: model.time.addDays(model.time.startOfDay(model.now), 1)) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "moon.stars").imageScale(.small)
                            Text("明日").fontWeight(.semibold)
                            Text("\(tomorrow)").foregroundStyle(.tertiary).monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(width: full * t, height: 28, alignment: .leading)
                        .background(Color(.secondarySystemFill).opacity(0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("翌日計画 \(tomorrow)件。タップすると明日を表示します")
                }
            }
        }
        .frame(height: 28)
        .animation(reduceMotion ? nil : Motion.sheet, value: mainFraction)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func laneButton(_ title: String, symbol: String, count: Int, on: Bool, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).imageScale(.small)
                Text(title).fontWeight(.semibold)
                Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .frame(width: max(0, width), height: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 状況チップの1行（遅れ・締切・タスク・空き時間・未割当・要約をたたむ）。0件のものは出さない
    private func statusRow(taskLabel: String, taskValue: String, freeMin: Int, isToday: Bool, now: EpochMs) -> some View {
        let overdue = model.tasks.filter { t in
            !t.isDone && t.kind == .do && (t.plannedEnd.map { $0 < now } ?? false)
        }.count
        let dueSoon = model.tasks.filter { t in !t.isDone && (t.deadline.map { $0 >= now && $0 < now + 48 * HOUR } ?? false) }.count
        return HStack(spacing: 6) {
            if overdue > 0 {
                StatusChip(symbol: "exclamationmark.circle", label: "遅れ", value: "\(overdue)", tint: .red) { router.tab = .tasks }
            }
            if dueSoon > 0 {
                StatusChip(symbol: "flag", label: "締切", value: "\(dueSoon)", tint: .orange) { router.tab = .tasks }
            }
            StatusChip(symbol: "checklist", label: taskLabel, value: taskValue) { router.open(.dayTasks(day)) }
            // 「余白◯%」ではなく、この後に自由に使える時間をそのまま出す
            StatusChip(symbol: "hourglass", label: isToday ? "空き" : "空き時間", value: freeLabel(freeMin)) { router.open(.planAssist) }
            if !model.inbox.isEmpty {
                StatusChip(symbol: "tray", label: "未割当", value: "\(model.inbox.count)", tint: .indigo) { router.open(.inbox) }
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(reduceMotion ? nil : Motion.sheet) { collapsed.toggle() }
            } label: {
                Image(systemName: "chevron.up").rotationEffect(.degrees(collapsed ? 180 : 0)).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(collapsed ? "要約を広げる" : "要約をたたむ")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tomorrowItemCount(after day: EpochMs) -> Int {
        let d1 = model.time.addDays(model.time.startOfDay(model.now), 1), d2 = model.time.addDays(d1, 1)
        let ev = model.visibleEvents(from: d1, to: d2).filter { !$0.event.allDay && $0.start >= d1 && $0.start < d2 }.count
        let tk = model.tasks.filter { t in !t.isDone && ((t.kind == .check ? t.checkAt : t.plannedStart).map { $0 >= d1 && $0 < d2 } ?? false) }.count
        return ev + tk
    }

    private func freeLabel(_ m: Int) -> String {
        m <= 0 ? "なし" : m < 60 ? "\(m)分" : m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分"
    }

    /// 活動の時間帯のうち、予定・タスクの入っていない時間（今日は今から、ほかの日は1日分）
    private func freeMinutes(day: EpochMs, now: EpochMs, busy: [BusyItem]) -> Int {
        var from = day + EpochMs(model.settings.suggestFromHour) * HOUR
        let to = day + EpochMs(model.settings.suggestToHour) * HOUR
        if model.time.isSameDay(day, now) { from = max(from, now) }
        guard to > from else { return 0 }
        let parts = busy.map { (max($0.start, from), min($0.end, to)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var used: EpochMs = 0, cur: EpochMs = from
        for (s, e) in parts where e > cur { used += e - max(s, cur); cur = max(cur, e) }
        return Int((to - from - used) / MINUTE)
    }

    private func toggleFocus(_ f: String) {
        let next = model.settings.laneFocus == f ? "both" : f
        withAnimation(reduceMotion ? nil : Motion.sheet) { model.updateSettings { $0.laneFocus = next } }
    }
}

/// 今やることのカード。状況によって見せ方を変える。
/// 実行中：経過と進み具合／予定の最中：残り時間と進み具合・教室や場所／次の予定・授業：あと何分・教室や場所／
/// 出発：出発までの時間／何もない：大きな時計と、明日の最初の予定
struct NowCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    var next: NextAction
    var now: EpochMs
    var occurrences: [EventOccurrence] = []
    @State private var feedback = 0
    /// 右へなぞったときのずれ（タップ以外で開始・完了できる）
    @State private var swipe: CGFloat = 0

    private var occurrence: EventOccurrence? { next.eventId.flatMap { id in occurrences.first { $0.id == id } } }

    var body: some View {
        let task = next.taskId.flatMap { id in model.tasks.first { $0.id == id } }
        Group {
            if next.kind == .free { clockCard } else { mainCard(task) }
        }
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(alignment: .leading) {
            // なぞっている間、下から出てくる操作の名前
            if let p = swipePrimary(task) {
                Label(p.label, systemImage: p.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(p.tint)
                    .padding(.leading, 18)
                    .opacity(Double(min(1, swipe / 80)))
            }
        }
        .offset(x: swipe)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in
                    guard swipePrimary(task) != nil, v.translation.width > 0, abs(v.translation.width) > abs(v.translation.height) else { return }
                    swipe = min(140, v.translation.width * 0.8)
                }
                .onEnded { _ in
                    if swipe > 80, let p = swipePrimary(task) { p.run() }
                    withAnimation(.snappy) { swipe = 0 }
                }
        )
        .accessibilityActions {
            if let p = swipePrimary(task) { Button(p.label) { p.run() } }
        }
        .overlay {
            if next.kind == .continue { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.green.opacity(0.45), lineWidth: 1) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: feedback)
        .animation(.snappy, value: next)
    }

    // MARK: 予定・タスクがあるとき

    private func mainCard(_ task: MTTask?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if let id = next.taskId { router.open(.task(id)) } else if let id = next.eventId { router.open(.event(id)) }
                } label: {
                    HStack(spacing: 10) {
                        if let task {
                            ProgressRing(value: actualProgress(task, subtasks: model.subtasks(of: task.id)).value, ideal: idealProgress(task, now: now), symbol: IconMap.symbol(task.icon), size: 44, running: task.status == .running)
                        } else {
                            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44).background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(.caption.weight(.bold)).foregroundStyle(tint)
                            Text(next.title).font(.headline).lineLimit(1)
                            if let sub = subline(task) {
                                Label(sub.text, systemImage: sub.symbol).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    .labelStyle(CompactLabel())
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label)：\(next.title)、\(subline(task)?.text ?? "")、\(countdown?.big ?? "")")
                .accessibilityHint("詳細を開きます")

                if let task, task.status == .running {
                    circle("pause.fill", "停止", .secondary) { act(task.id, .pause, "停止しました") }
                    circle("checkmark", "完了", .green) { act(task.id, .finish, "完了しました", undo: .undoFinish) }
                } else if let task, next.kind == .start {
                    circle("play.fill", "開始", .accentColor) { act(task.id, .start, "開始しました", undo: .undoStart) }
                } else if next.kind == .plan {
                    circle("tray", "未割当を開く", .indigo) { router.open(.inbox) }
                } else if let c = countdown {
                    // 次の予定・出発まで：右に大きく残り時間
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(c.big).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(tint)
                            .contentTransition(.numericText())
                        Text(c.small).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                }
            }
            if let p = progress(task) {
                ProgressView(value: p.value)
                    .tint(tint)
                    .accessibilityLabel(p.label)
                HStack {
                    Text(p.left).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(p.right).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: 何もないとき：時計と明日の最初の予定

    private var clockCard: some View {
        let d = model.time.date(now)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(d, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(greeting).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let t = tomorrowFirst {
                    Text("明日の最初").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(t.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                } else {
                    Label("この後は空いています", systemImage: "sun.max.fill").font(.subheadline).foregroundStyle(.secondary)
                        .labelStyle(CompactLabel())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: model.time.date(now))
        let rest = "今日はこの後なにもありません"
        return h < 11 ? "おはようございます・\(rest)" : h < 18 ? rest : "おつかれさまでした・\(rest)"
    }

    /// 明日の最初の予定（終日を除く）か、時刻の決まったタスク
    private var tomorrowFirst: (title: String, detail: String)? {
        let d1 = model.time.addDays(model.time.startOfDay(now), 1), d2 = model.time.addDays(d1, 1)
        let ev = model.visibleEvents(from: d1, to: d2).filter { !$0.event.allDay && $0.start >= d1 }.min { $0.start < $1.start }
        let tk = model.tasks.filter { !$0.isDone && ($0.plannedStart.map { $0 >= d1 && $0 < d2 } ?? false) }.min { $0.plannedStart! < $1.plannedStart! }
        if let ev, ev.start <= (tk?.plannedStart ?? .max) {
            let extra = room(ev) ?? ev.event.placeName
            return (ev.title, "\(model.hm(ev.start))〜" + (extra.map { "・\($0)" } ?? ""))
        }
        if let tk { return (tk.title, "\(model.hm(tk.plannedStart!))〜") }
        return nil
    }

    // MARK: 中身

    private var label: String {
        switch next.kind {
        case .continue: return "実行中"
        case .start: return "次にやること"
        case .leave: return "出発"
        case .event:
            if isOngoing { return isClass ? "授業中" : "予定の最中" }
            return isClass ? "次の授業" : "次の予定"
        case .plan: return "時間を決める"
        case .free: return "この後"
        }
    }

    private var isOngoing: Bool { occurrence.map { $0.start <= now && $0.end > now } ?? next.detail.hasSuffix("まで") }
    private var isClass: Bool { occurrence.map { model.calendar($0.event.calendarId)?.kind == .class || $0.event.specType == .class } ?? false }
    private func room(_ o: EventOccurrence) -> String? {
        o.event.classInfo?["room"]?.stringValue.flatMap { $0.isEmpty ? nil : "\($0)教室" }
    }

    private var icon: String {
        switch next.kind {
        case .leave: return "tram.fill"
        case .event: return isClass ? "graduationcap.fill" : "calendar"
        case .plan: return "tray.fill"
        default: return "clock"
        }
    }
    private var tint: Color {
        switch next.kind {
        case .continue: return .green
        case .leave: return .orange
        case .event: return occurrence.map { Color(hex: model.eventColor($0.event)) } ?? .indigo
        case .plan: return .indigo
        default: return .blue
        }
    }

    /// 2行目：教室・場所・時刻など、そのとき役に立つ1つ
    private func subline(_ task: MTTask?) -> (text: String, symbol: String)? {
        if let task, task.status == .running {
            let p = actualProgress(task, subtasks: model.subtasks(of: task.id)).value
            return (formatDuration(workedMs(task, at: now)) + (p.map { "・実績\(Int(($0 * 100).rounded()))%" } ?? ""), "timer")
        }
        if let o = occurrence {
            let time = isOngoing ? "\(model.hm(o.end))まで" : "\(model.hm(o.start))〜\(model.hm(o.end))"
            if let r = room(o) { return ("\(time)・\(r)", "door.left.hand.open") }
            if let p = o.event.placeName, !p.isEmpty { return ("\(time)・\(p)", "mappin") }
            if o.event.extra?["meetingUrl"]?.stringValue != nil { return ("\(time)・オンライン", "video") }
            return (time, "clock")
        }
        return next.detail.isEmpty ? nil : (next.detail, "clock")
    }

    /// 右に大きく出す「あと◯分」
    private var countdown: (big: String, small: String)? {
        guard let at = next.at else { return nil }
        if next.kind == .event && isOngoing { return nil }
        guard next.kind == .event || next.kind == .leave else { return nil }
        let m = Int((at - now) / MINUTE)
        if m <= 0 { return ("今", next.kind == .leave ? "出発" : "開始") }
        let big = m < 60 ? "\(m)分" : m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60):\(String(format: "%02d", m % 60))"
        return (big, next.kind == .leave ? "で出発" : "で開始")
    }

    /// 進み具合のバー（予定の最中・実行中で予定時刻があるとき）
    private func progress(_ task: MTTask?) -> (value: Double, left: String, right: String, label: String)? {
        if let o = occurrence, isOngoing {
            let v = Double(now - o.start) / Double(max(1, o.end - o.start))
            let left = Int((o.end - now) / MINUTE)
            return (min(1, max(0, v)), model.hm(o.start), "あと\(left < 60 ? "\(left)分" : "\(left / 60)時間\(left % 60)分")で終わる", "予定の進み具合")
        }
        if let task, task.status == .running, let s = task.plannedStart, let e = task.plannedEnd, e > s {
            let v = Double(now - s) / Double(e - s)
            return (min(1, max(0, v)), model.hm(s), now < e ? "\(model.hm(e))まで" : "予定を\(Int((now - e) / MINUTE))分過ぎています", "予定の時間の進み具合")
        }
        return nil
    }

    private func circle(_ symbol: String, _ label: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.bold))
                .foregroundStyle(tint == .secondary ? Color.primary : Color.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint == .secondary ? Color(.tertiarySystemFill) : tint))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private struct Primary { var label: String; var symbol: String; var tint: Color; var run: () -> Void }

    /// 右へなぞったときの操作：実行中なら完了、始める時刻なら開始
    private func swipePrimary(_ task: MTTask?) -> Primary? {
        guard let task else { return nil }
        if task.status == .running {
            return Primary(label: "完了", symbol: "checkmark.circle.fill", tint: .green) { act(task.id, .finish, "完了しました", undo: .undoFinish) }
        }
        if next.kind == .start {
            return Primary(label: "開始", symbol: "play.circle.fill", tint: .accentColor) { act(task.id, .start, "開始しました", undo: .undoStart) }
        }
        return nil
    }

    private func act(_ id: String, _ a: TaskAction, _ msg: String, undo: TaskAction? = nil) {
        feedback += 1
        model.perform(msg, undo: undo.map { u in { try model.repo.taskAction(id, u) } }) { try model.repo.taskAction(id, a) }
    }
}

/// アイコンと文字の間を詰めたラベル
struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

/// 上の見出し：日付と「18:30:20」を5秒ごとに入れ替える（数字はなめらかに入れ替わる）
struct DateClockTitle: View {
    var title: String
    var isToday: Bool
    var onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let sec = Calendar.current.component(.second, from: ctx.date)
            // 今日を見ているときだけ時計を出す（5秒ごとに日付⇄時刻）
            let showClock = isToday && (sec / 5) % 2 == 1
            Button(action: onTap) {
                ZStack {
                    if showClock {
                        Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                            .font(.headline.monospacedDigit())
                            .contentTransition(.numericText(countsDown: false))
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
                                                                              removal: .move(edge: .top).combined(with: .opacity)))
                            .id("clock")
                    } else {
                        Text(title)
                            .font(.headline)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
                                                                              removal: .move(edge: .top).combined(with: .opacity)))
                            .id("date")
                    }
                }
                .frame(minWidth: 160)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: showClock)
                .animation(reduceMotion ? nil : .snappy, value: ctx.date)
                .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("日付を選びます")
        }
    }
}
