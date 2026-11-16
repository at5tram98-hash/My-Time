import SwiftUI
import MyTimeCore

/// タスクの詳細。開始・停止・完了、実績の記録、サブタスク、編集・削除
struct TaskDetailView: View {
    var taskId: String
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var newSubtask = ""
    @State private var scrub: Double?
    @State private var confirmDelete = false
    @State private var feedback = 0

    var body: some View {
        NavigationStack {
            if let task = model.tasks.first(where: { $0.id == taskId }) {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    form(task, now: model.time.ms(ctx.date))
                }
                .navigationTitle(task.kind == .check ? "確認" : "タスク")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("編集") { router.open(.editor(EditorSeed(kind: .task, taskId: task.id))) }
                    }
                }
                .sensoryFeedback(.success, trigger: feedback)
                // 削除の確認は画面の中央に（吹き出しがずれたり重なったりしない）
                .alert(task.kind == .check ? "この確認を削除しますか？" : "このタスクを削除しますか？", isPresented: $confirmDelete) {
                    Button("削除", role: .destructive) {
                        let snapshot = task
                        let subs = model.subtasks(of: task.id)
                        if model.perform("削除しました", undo: {
                            try model.repo.saveTask(snapshot, isNew: true)
                            for s in subs { try model.repo.addSubtask(taskId: snapshot.id, title: s.title) }
                        }, { try model.repo.deleteTask(task.id) }) { dismiss() }
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("「\(task.title)」" + (model.subtasks(of: task.id).isEmpty ? "" : "とサブタスク\(model.subtasks(of: task.id).count)件") + "\n間違えたときは iPhone を振ると元に戻せます。")
                }
            } else {
                ContentUnavailableView("タスクが見つかりません", systemImage: "questionmark.circle", description: Text("削除されたか、別の端末で変更された可能性があります。"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    @ViewBuilder
    private func form(_ task: MTTask, now: EpochMs) -> some View {
        let subs = model.subtasks(of: task.id)
        let progress = actualProgress(task, subtasks: subs)
        let ideal = idealProgress(task, now: now)
        List {
            Section {
                HStack(spacing: 14) {
                    ProgressRing(value: progress.value, ideal: ideal, symbol: IconMap.symbol(task.icon), tint: task.kind == .check ? .checkTask : .doTask, size: 56, running: task.status == .running, done: task.isDone)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.title3.weight(.semibold))
                        if let spec = task.specType, let def = SPEC_BY_ID[spec] {
                            Label(def.name, systemImage: def.symbol).font(.caption).foregroundStyle(def.tint)
                        }
                        Text(when(task)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            if task.kind == .check {
                Section {
                    Button {
                        feedback += 1
                        model.perform(task.checked ? "未確認に戻しました" : "確認しました", undo: { try model.repo.toggleCheck(task.id) }) { try model.repo.toggleCheck(task.id) }
                    } label: {
                        Label(task.checked ? "未確認に戻す" : "確認した", systemImage: task.checked ? "arrow.uturn.backward" : "checkmark.circle.fill")
                    }
                }
            } else {
                Section("実行") {
                    actions(task)
                    if task.status != .notStarted {
                        LabeledContent("作業した時間", value: formatDuration(workedMs(task, at: now)))
                    }
                    if let ideal { LabeledContent("理想の進み", value: "\(Int((ideal * 100).rounded()))%") }
                    let d = delayInfo(task, now: now)
                    if d.delayed {
                        Label("予定より\(d.overMinutes)分超過", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if task.status == .running {
                        switch estimateEnd(task, subtasks: subs, now: now) {
                        case .estimate(let at): LabeledContent("終わる見込み", value: model.hm(at))
                        case .unavailable(let why): LabeledContent("終わる見込み", value: why)
                        }
                    }
                }
                if canScrubProgress(task, subtasks: subs) {
                    Section {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("実績")
                                Spacer()
                                Text("\(Int(((scrub ?? progress.value ?? 0) * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(get: { scrub ?? progress.value ?? 0 }, set: { scrub = $0 }), in: 0...1, step: 0.05) { editing in
                                if !editing, let v = scrub {
                                    model.perform("実績を\(Int((v * 100).rounded()))%にしました") { try model.repo.recordProgress(task.id, value: v) }
                                    scrub = nil
                                }
                            }
                            .accessibilityLabel("実績")
                        }
                        if (progress.value ?? 0) >= 1 && task.status != .done {
                            Button("完了にする", systemImage: "checkmark.seal.fill") { model.perform("完了しました") { try model.repo.completeFromProgress(task.id) } }
                        }
                    } footer: { Text("サブタスクがないときは、どこまで進んだかを手で記録します。") }
                }
                if canAddSubtask(task) {
                    Section("サブタスク") {
                        ForEach(subs, id: \.id) { s in
                            Button {
                                model.perform { try model.repo.toggleSubtask(s.id) }
                            } label: {
                                HStack {
                                    Image(systemName: s.done ? "checkmark.circle.fill" : "circle").foregroundStyle(s.done ? Color.green : .secondary)
                                    Text(s.title).strikethrough(s.done).foregroundStyle(s.done ? .secondary : .primary)
                                }
                            }
                            .swipeActions { Button("削除", role: .destructive) { model.perform { try model.repo.deleteSubtask(s.id) } } }
                        }
                        HStack {
                            TextField("サブタスクを追加", text: $newSubtask).submitLabel(.done).onSubmit(addSubtask)
                            if !newSubtask.isEmpty { Button("追加", action: addSubtask) }
                        }
                    }
                }
            }

            if !task.notes.isEmpty {
                Section("メモ") { Text(task.notes) }
            }
            if let loc = task.location, !loc.isEmpty {
                Section("場所") { Label(loc, systemImage: "mappin.and.ellipse") }
            }
            // 純正リマインダー・カレンダーと同じく、一番下に赤い削除（中央ぞろえ）
            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text(task.kind == .check ? "確認を削除" : "タスクを削除").font(.body.weight(.medium)).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func addSubtask() {
        let t = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let ok = model.perform { try model.repo.addSubtask(taskId: taskId, title: t) }
        if ok { newSubtask = "" }
    }

    @ViewBuilder
    private func actions(_ task: MTTask) -> some View {
        let avail = availableActions(task)
        HStack(spacing: 10) {
            ForEach(avail.filter { $0 != .undoStart && $0 != .undoFinish }, id: \.self) { a in
                Button {
                    feedback += a == .finish ? 1 : 0
                    let undo: TaskAction? = a == .start ? .undoStart : a == .finish ? .undoFinish : nil
                    model.perform(label(a) + "しました", undo: undo.map { u in { try model.repo.taskAction(task.id, u) } }) { try model.repo.taskAction(task.id, a) }
                } label: {
                    Label(label(a), systemImage: symbol(a)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(a == .finish ? .green : a == .pause ? .gray : .accentColor)
                .controlSize(.large)
            }
            if avail.contains(.undoFinish) {
                Button("完了を取り消す", systemImage: "arrow.uturn.backward") { model.perform("取り消しました") { try model.repo.taskAction(task.id, .undoFinish) } }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private func label(_ a: TaskAction) -> String {
        switch a {
        case .start: return "開始"
        case .pause: return "停止"
        case .resume: return "再開"
        case .finish: return "完了"
        case .undoFinish: return "完了を取り消"
        case .undoStart: return "開始を取り消"
        }
    }
    private func symbol(_ a: TaskAction) -> String {
        switch a {
        case .start, .resume: return "play.fill"
        case .pause: return "pause.fill"
        case .finish: return "checkmark"
        default: return "arrow.uturn.backward"
        }
    }
    private func when(_ t: MTTask) -> String {
        if t.kind == .check, let c = t.checkAt { return "\(model.time.dayLabel(c)) \(model.hm(c))" }
        var parts: [String] = []
        if let s = t.plannedStart, let e = t.plannedEnd { parts.append("\(model.time.dayLabel(s)) \(model.hm(s))〜\(model.hm(e))") } else if t.kind == .do { parts.append("時間は未定") }
        if let d = t.deadline { parts.append("締切 \(model.time.dayLabel(d)) \(model.hm(d))") }
        if let m = t.estimateMinutes { parts.append("見積 \(m)分") }
        return parts.joined(separator: "・")
    }
}

/// 一覧の1行（タップで詳細、確認タスクは丸を押して確認）
struct TaskRow: View {
    var task: MTTask
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var feedback = 0
    /// 長押し→横にずらして実績を記録している途中の値（Web 版と同じ。理想の進みから始める）
    @State private var scrub: Double?
    @State private var scrubBase: Double = 0
    @State private var rowWidth: CGFloat = 300
    @State private var step = 0
    @State private var picked = 0
    @State private var confirmComplete = false

    private var canScrub: Bool { canScrubProgress(task, subtasks: model.subtasks(of: task.id)) }

    var body: some View {
        let actual = actualProgress(task, subtasks: model.subtasks(of: task.id)).value
        HStack(spacing: 12) {
            if task.kind == .check {
                Button {
                    feedback += 1
                    model.perform(task.checked ? "未確認に戻しました" : "確認しました", undo: { try model.repo.toggleCheck(task.id) }) { try model.repo.toggleCheck(task.id) }
                } label: {
                    Image(systemName: task.checked ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(task.checked ? Color.checkTask : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.checked ? "未確認に戻す" : "確認した")
            } else {
                ProgressRing(value: scrub ?? actual, ideal: nil, symbol: IconMap.symbol(task.icon), size: 32, running: task.status == .running, done: task.isDone)
            }
            Button { router.open(.task(task.id)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if task.flagged { Image(systemName: "flag.fill").foregroundStyle(.orange).imageScale(.small) }
                        Text(task.title).strikethrough(task.isDone).foregroundStyle(task.isDone ? .secondary : .primary).lineLimit(2)
                    }
                    if let v = scrub {
                        Text("実績 \(Int((v * 100).rounded()))%（離すと記録）").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).monospacedDigit()
                    } else if let sub = subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let spec = task.specType { SpecBadge(type: spec, isEvent: false, size: 22) }
        }
        .background(alignment: .leading) {
            GeometryReader { g in
                Capsule().fill(Color.accentColor.opacity(0.14))
                    .frame(width: max(0, g.size.width * CGFloat(scrub ?? 0)))
                    .opacity(scrub == nil ? 0 : 1)
                    .onAppear { rowWidth = max(120, g.size.width) }
                    .onChange(of: g.size.width) { _, w in rowWidth = max(120, w) }
            }
        }
        .highPriorityGesture(scrubGesture, including: canScrub ? .all : .subviews)
        .sensoryFeedback(.success, trigger: feedback)
        .sensoryFeedback(.selection, trigger: step)
        .sensoryFeedback(.impact(weight: .medium), trigger: picked)
        .alert("完了にしますか？", isPresented: $confirmComplete) {
            Button("完了にする") {
                feedback += 1
                model.perform("完了しました", undo: { try model.repo.taskAction(task.id, .undoFinish) }) {
                    try model.repo.recordProgress(task.id, value: 1)
                    try model.repo.completeFromProgress(task.id)
                }
                scrub = nil
            }
            Button("キャンセル", role: .cancel) { scrub = nil }
        } message: {
            Text("実績を100%にしました。")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "実績を10%進める") { if canScrub { record(min(1, (actual ?? 0) + 0.1)) } }
        .accessibilityAction(named: "実績を10%戻す") { if canScrub { record(max(0, (actual ?? 0) - 0.1)) } }
    }

    /// 長押し（0.35秒）→ 横にずらす。右で増え、左で減る。100%で離すと完了の確認
    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let d) = value else { return }
                if scrub == nil {
                    scrubBase = actualProgress(task, subtasks: model.subtasks(of: task.id)).value ?? idealProgress(task, now: model.now) ?? 0
                    scrub = scrubBase
                    picked += 1
                }
                let v = min(1, max(0, scrubBase + Double((d?.translation.width ?? 0) / rowWidth)))
                let snapped = (v * 20).rounded() / 20
                if Int(snapped * 20) != step { step = Int(snapped * 20) }
                scrub = snapped
            }
            .onEnded { _ in
                guard let v = scrub else { return }
                if v >= 1 { confirmComplete = true; return }
                if abs(v - scrubBase) < 0.001 { scrub = nil; return }
                record(v)
                scrub = nil
            }
    }

    private func record(_ v: Double) {
        model.perform("実績を\(Int((v * 100).rounded()))%にしました") { try model.repo.recordProgress(task.id, value: v) }
    }

    private var subtitle: String? {
        var p: [String] = []
        if task.kind == .check, let c = task.checkAt { p.append("\(model.time.dayLabel(c)) \(model.hm(c))") }
        if let s = task.plannedStart, let e = task.plannedEnd { p.append("\(model.time.dayLabel(s)) \(model.hm(s))〜\(model.hm(e))") }
        if let d = task.deadline { p.append("締切 \(model.time.dayLabel(d))") }
        if task.status == .running { p.append("実行中") }
        return p.isEmpty ? nil : p.joined(separator: "・")
    }
}

/// 未割当（時間を決めていない実行タスク）
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if model.inbox.isEmpty {
                    ContentUnavailableView("未割当はありません", systemImage: "tray", description: Text("時間を決めていないタスクがここに並びます。"))
                } else {
                    List(model.inbox, id: \.id) { t in
                        TaskRow(task: t)
                            .swipeActions(edge: .leading) {
                                Button("今日の空き時間に", systemImage: "calendar.badge.plus") { placeToday(t) }.tint(.indigo)
                            }
                    }
                }
            }
            .navigationTitle("未割当")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    /// 今から先で、最初に空いている時間へ置く（15分刻み）
    private func placeToday(_ t: MTTask) {
        let now = model.now
        let minutes = t.estimateMinutes ?? 30
        let busy = busyItems(events: model.visibleEvents(from: now, to: now + DAY), tasks: model.tasks)
        var start = ((now / (15 * MINUTE)) + 1) * 15 * MINUTE
        let limit = model.time.at(day: model.time.startOfDay(now), hour: model.settings.suggestToHour)
        while start + EpochMs(minutes) * MINUTE <= limit {
            let end = start + EpochMs(minutes) * MINUTE
            if !busy.contains(where: { $0.start < end && start < $0.end }) {
                var copy = t
                copy.plannedStart = start
                copy.plannedEnd = end
                model.perform("\(model.hm(start))に入れました", undo: { var back = copy; back.plannedStart = nil; back.plannedEnd = nil; try model.repo.saveTask(back, isNew: false) }) { try model.repo.saveTask(copy, isNew: false) }
                return
            }
            start += 15 * MINUTE
        }
        model.errorMessage = "今日はもう\(minutes)分の空き時間がありません"
    }
}

/// その日のタスク
struct DayTasksView: View {
    var day: EpochMs
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            let list = orderHomeTasks(tasksForDay(model.tasks, day: day, time: model.time), now: model.now)
            Group {
                if list.isEmpty {
                    ContentUnavailableView("タスクはありません", systemImage: "checklist")
                } else {
                    List(list, id: \.id) { TaskRow(task: $0) }
                }
            }
            .navigationTitle(model.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
