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

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let now = model.time.ms(ctx.date)
                content(now: now)
            }
            .navigationTitle(model.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("今日へ移動", systemImage: "calendar.badge.clock") { go(to: model.time.startOfDay(model.now)) }
                            .disabled(model.time.isSameDay(day, model.now))
                        Button("日付を選択", systemImage: "calendar") { showDatePicker = true }
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
        let free = freeRatio(day: day, busy: busy, fromHour: model.settings.suggestFromHour, toHour: model.settings.suggestToHour, time: model.time)
        let next = nextAction(events: occ, tasks: model.tasks, now: now, time: model.time)
        let dayEvents = occ.filter { $0.start < d1 && $0.end > day && !$0.event.allDay }
        let focus = model.settings.laneFocus
        let mainFraction: CGFloat = focus == "main" ? 0.68 : focus == "detail" ? 0.34 : 0.52

        VStack(spacing: 8) {
            if !collapsed {
                NowCard(next: next, now: now)
                    .padding(.horizontal)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            // 画面幅に収まる形を選ぶ：通常のラベル → 短いラベル → それでも入らなければ横スクロール（大きな文字サイズのとき）
            let taskValue = dayTasks.isEmpty ? "0" : "\(done)/\(dayTasks.count)"
            let isToday = model.time.isSameDay(day, now)
            ViewThatFits(in: .horizontal) {
                statusRow(taskLabel: isToday ? "今日のタスク" : "タスク", taskValue: taskValue, free: free)
                    .padding(.horizontal)
                statusRow(taskLabel: isToday ? "今日" : "タスク", taskValue: taskValue, free: free)
                    .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    statusRow(taskLabel: isToday ? "今日" : "タスク", taskValue: taskValue, free: free)
                        .padding(.horizontal)
                }
            }
            laneHeader(mainFraction: mainFraction, events: dayEvents.count, tasks: dayTasks.count, focus: focus)
            DayTimeline(day: day, now: now, events: occ, tasks: model.tasks, mainFraction: mainFraction)
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

    private func laneHeader(mainFraction: CGFloat, events: Int, tasks: Int, focus: String) -> some View {
        GeometryReader { geo in
            let w = geo.size.width - DayTimeline.gutter
            HStack(spacing: 0) {
                Color.clear.frame(width: DayTimeline.gutter)
                laneButton("予定", symbol: "calendar", count: events, on: focus == "main", width: w * mainFraction) { toggleFocus("main") }
                laneButton("タスク", symbol: "checklist", count: tasks, on: focus == "detail", width: w * (1 - mainFraction)) { toggleFocus("detail") }
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

    /// 状況チップの1行（未割当・タスク・余白・要約をたたむ）
    private func statusRow(taskLabel: String, taskValue: String, free: Double) -> some View {
        HStack(spacing: 6) {
            StatusChip(symbol: "tray", label: "未割当", value: "\(model.inbox.count)", tint: model.inbox.isEmpty ? .secondary : .indigo) { router.open(.inbox) }
            StatusChip(symbol: "checklist", label: taskLabel, value: taskValue) { router.open(.dayTasks(day)) }
            StatusChip(symbol: "sun.max", label: "余白", value: "\(Int((free * 100).rounded()))%") { router.tab = .review }
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

    private func toggleFocus(_ f: String) {
        let next = model.settings.laneFocus == f ? "both" : f
        withAnimation(reduceMotion ? nil : Motion.sheet) { model.updateSettings { $0.laneFocus = next } }
    }
}

/// 今やること（実行中なら経過と停止・完了、そうでなければ次の1件と主な操作1つ）
struct NowCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    var next: NextAction
    var now: EpochMs
    @State private var feedback = 0

    var body: some View {
        let task = next.taskId.flatMap { id in model.tasks.first { $0.id == id } }
        HStack(spacing: 10) {
            Button {
                if let id = next.taskId { router.open(.task(id)) } else if let id = next.eventId { router.open(.event(id)) } else { router.open(.editor(EditorSeed(kind: .task))) }
            } label: {
                HStack(spacing: 10) {
                    if let task {
                        ProgressRing(value: actualProgress(task, subtasks: model.subtasks(of: task.id)).value, ideal: idealProgress(task, now: now), symbol: IconMap.symbol(task.icon), size: 42, running: task.status == .running)
                    } else {
                        Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 42, height: 42).background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text(next.title).font(.headline).lineLimit(1)
                        Text(detail(task)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label)：\(next.title)、\(detail(task))")
            .accessibilityHint("詳細を開きます")

            if let task {
                if task.status == .running {
                    circle("pause.fill", "停止", .secondary) { act(task.id, .pause, "停止しました") }
                    circle("checkmark", "完了", .green) { act(task.id, .finish, "完了しました", undo: .undoFinish) }
                } else if next.kind == .start {
                    circle("play.fill", "開始", .accentColor) { act(task.id, .start, "開始しました", undo: .undoStart) }
                }
            } else if next.kind == .free {
                circle("plus", "追加", .accentColor) { router.open(.editor(EditorSeed(kind: .task))) }
            } else if next.kind == .plan {
                circle("tray", "未割当を開く", .indigo) { router.open(.inbox) }
            }
        }
        .padding(10)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if next.kind == .continue { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.green.opacity(0.45), lineWidth: 1) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: feedback)
    }

    private var label: String {
        switch next.kind {
        case .continue: return "実行中"
        case .start: return "次にやること"
        case .leave: return "出発"
        case .event: return "予定の最中"
        case .plan: return "時間を決める"
        case .free: return "この後"
        }
    }
    private var icon: String { next.kind == .leave ? "tram.fill" : next.kind == .event ? "calendar" : next.kind == .free ? "sun.max.fill" : "clock" }
    private var tint: Color { next.kind == .leave ? .orange : next.kind == .event ? .indigo : next.kind == .free ? .green : .blue }

    private func detail(_ task: MTTask?) -> String {
        if let task, task.status == .running {
            let p = actualProgress(task, subtasks: model.subtasks(of: task.id)).value
            return formatDuration(workedMs(task, at: now)) + (p.map { "・実績\(Int(($0 * 100).rounded()))%" } ?? "")
        }
        return next.detail
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

    private func act(_ id: String, _ a: TaskAction, _ msg: String, undo: TaskAction? = nil) {
        feedback += 1
        model.perform(msg, undo: undo.map { u in { try model.repo.taskAction(id, u) } }) { try model.repo.taskAction(id, a) }
    }
}
