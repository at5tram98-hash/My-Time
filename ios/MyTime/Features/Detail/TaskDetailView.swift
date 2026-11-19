import SwiftUI
import MyTimeCore

/// タスクの詳細（純正リマインダー・時計にならい、上に状態、真ん中に大きな操作、下に詳しい情報）。
/// 1つの行に複数のボタンを並べない（行全体が反応してしまうため）。ボタンはそれぞれ独立した形にする。
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
                // 秒を出すのは作業中だけ（それ以外は画面全体を毎秒書き換えない。ボタンや日付の選択が途切れないように）
                // 朝・清掃は種類ごとの詳細（進み具合や作業時間は出さない）
                Group {
                    switch task.specType {
                    case .morning: MorningTaskDetail(task: task) { confirmDelete = true }
                    case .cleaning: CleaningTaskDetail(task: task) { confirmDelete = true }
                    default:
                        TimelineView(.periodic(from: .now, by: task.status == .running ? 1 : 30)) { ctx in
                            form(task, now: model.time.ms(ctx.date))
                        }
                    }
                }
                .navigationTitle(task.specType == .morning ? "朝" : task.specType == .cleaning ? "清掃" : task.kind == .check ? "確認" : "タスク")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("閉じる")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("編集") { router.open(.editor(EditorSeed(kind: .task, taskId: task.id))) }
                    }
                }
                .sensoryFeedback(.success, trigger: feedback)
                .alert(task.kind == .check ? "この確認を削除しますか？" : "このタスクを削除しますか？", isPresented: $confirmDelete) {
                    Button("削除", role: .destructive) {
                        let snapshot = task
                        let subs = model.subtasks(of: task.id)
                        if model.perform("削除しました", undo: {
                            try model.repo.saveTask(snapshot, isNew: true)
                            for s in subs { try model.repo.addSubtask(taskId: snapshot.id, title: s.title) }
                        }, { model.skipAutoMorning(task); try model.repo.deleteTask(task.id) }) {
                            // 朝のタスクを消して、ほかに朝のタスクが無ければ起床アラームも解除する（設定は残し、オフにする）
                            if task.specType == .morning && !model.tasks.contains(where: { $0.specType == .morning }) {
                                var m = model.morning
                                for i in m.alarms.indices { m.alarms[i].enabled = false }
                                model.saveMorning(m)
                            }
                            dismiss()
                        }
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

    static let noProgress: Set<SpecTypeId> = [.shopping, .chores, .belongings, .payment, .paperwork, .cooking, .morning, .cleaning]

    @ViewBuilder
    private func form(_ task: MTTask, now: EpochMs) -> some View {
        let subs = model.subtasks(of: task.id)
        let progress = actualProgress(task, subtasks: subs)
        let ideal = idealProgress(task, now: now)
        let delay = delayInfo(task, now: now)
        let tint = taskTint(task)
        // Create Studio の種類で進み具合を計るとき（読んだページ÷目標 など）
        let st = model.studioType(task.extra?["studio"]?["typeId"]?.stringValue)
        let sv = task.extra?["studio"]?["values"]?.objectValue ?? [:]
        let sp = st.flatMap { $0.progress.mode == .none ? nil : studioProgress($0, values: sv, workedMinutes: Double(workedMs(task, at: now) / MINUTE)) }
        let ringValue = task.isDone ? 1 : (sp?.value ?? progress.value)
        List {
            // 見出し：進み具合の輪・名前・状態
            Section {
                VStack(spacing: 12) {
                    ProgressRing(value: ringValue, ideal: ideal, symbol: IconMap.symbol(task.icon), tint: tint, size: 76, running: task.status == .running, done: task.isDone)
                    VStack(spacing: 4) {
                        Text(task.title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            StatusPill(text: statusText(task, delay: delay), color: statusColor(task, delay: delay))
                            if let spec = task.specType, let def = SPEC_BY_ID[spec] { StatusPill(text: def.name, color: def.tint, symbol: def.symbol) }
                            if task.flagged { StatusPill(text: "フラグ", color: .orange, symbol: "flag.fill") }
                        }
                        Text(when(task)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.center)
                    }
                    if task.status == .running || task.status == .paused {
                        // 経過時間を大きく（秒まで）
                        Text(clock(workedMs(task, at: now)))
                            .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(task.status == .running ? Color.green : .secondary)
                            .contentTransition(.numericText())
                            .accessibilityLabel("作業した時間 \(formatDuration(workedMs(task, at: now)))")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            // 大きな操作（1つずつ独立したボタン）
            Section {
                if task.kind == .check {
                    BigActionButton(title: task.checked ? "未確認に戻す" : "確認した", symbol: task.checked ? "arrow.uturn.backward" : "checkmark", tint: task.checked ? .gray : .checkTask, prominent: !task.checked) {
                        feedback += 1
                        model.perform(task.checked ? "未確認に戻しました" : "確認しました", undo: { try model.repo.toggleCheck(task.id) }) { try model.repo.toggleCheck(task.id) }
                    }
                } else {
                    actionButtons(task)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))

            // 遅れているときだけ「ずらす」
            if delay.delayed && !task.isDone {
                Section {
                    Label("予定より\(lateText(delay.overMinutes))遅れています", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.subheadline.weight(.semibold))
                    Menu {
                        Button("今から始める", systemImage: "play") { shift(task, toStart: ((now / (5 * MINUTE)) + 1) * 5 * MINUTE) }
                        Button("30分後へ", systemImage: "goforward.30") { shift(task, by: 30 * MINUTE, now: now) }
                        Button("1時間後へ", systemImage: "clock.arrow.circlepath") { shift(task, by: HOUR, now: now) }
                        Button("明日の同じ時刻へ", systemImage: "sunrise") { if let s = task.plannedStart { shift(task, toStart: model.time.addDays(s, 1)) } }
                        Button("時間を外して未割当へ", systemImage: "tray") { unplan(task) }
                    } label: {
                        HStack(spacing: 12) {
                            RowIcon(symbol: "arrow.right.circle.fill", tint: .orange)
                            Text("ずらす").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                } footer: { Text("残りの長さはそのままに、開始と終了をずらします。") }
            }

            if let st {
                Section {
                    if let sp {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("進み具合").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(sp.label + (sp.over ? "・目標超え" : "")).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Color(hex: st.color))
                            }
                            ProgressView(value: sp.value ?? 0).tint(Color(hex: st.color))
                        }
                    }
                    ForEach(Array(studioInfoRows(st, values: sv, time: model.time, hm: model.hm).enumerated()), id: \.offset) { _, r in
                        LabeledContent(r.0, value: r.1)
                    }
                    Button { router.open(.editor(EditorSeed(kind: .task, taskId: task.id))) } label: { Label("値を入力する", systemImage: "square.and.pencil") }
                } header: {
                    Label(st.name, systemImage: IconMap.symbol(st.icon)).foregroundStyle(Color(hex: st.color))
                }
            }

            // 買い物・家事・持ち物・支払い・書類・料理は「％」の進み具合を出さない（済んだかどうかだけ）
            if task.kind == .do && sp == nil && canScrubProgress(task, subtasks: subs) && !Self.noProgress.contains(task.specType ?? .project) {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("実績").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int(((scrub ?? progress.value ?? 0) * 100).rounded()))%").monospacedDigit().font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                        }
                        Slider(value: Binding(get: { scrub ?? progress.value ?? 0 }, set: { scrub = $0 }), in: 0...1, step: 0.05) { editing in
                            if !editing, let v = scrub {
                                model.perform("実績を\(Int((v * 100).rounded()))%にしました") { try model.repo.recordProgress(task.id, value: v) }
                                scrub = nil
                            }
                        }
                        .tint(tint)
                        .accessibilityLabel("実績")
                        if let ideal {
                            Text("理想の進み \(Int((ideal * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if (progress.value ?? 0) >= 1 && task.status != .done {
                        Button { model.perform("完了しました") { try model.repo.completeFromProgress(task.id) } } label: {
                            Label("完了にする", systemImage: "checkmark.seal.fill")
                        }
                    }
                } header: { Text("進み具合") } footer: { Text("サブタスクがないときは、どこまで進んだかを手で記録します。") }
            }

            if let spec = task.specType, SPEC_BY_ID[spec] != nil {
                SpecPanel(spec: spec, details: task.extra?["spec"]?["details"]?.objectValue ?? [:], start: nil, end: nil, employerName: nil, task: task) { d in
                    var t = task
                    var d = d
                    // 試験の日を変えたら締切もそろえる
                    if spec.isExamLike, let at = d["examAt"] ?? d["mockDate"] ?? d["examDate"] { d["dueAt"] = at }
                    t.extra = withSpecDetails(t.extra, d)
                    _ = model.perform(nil, undo: { try model.repo.saveTask(task, isNew: false) }) { try model.repo.saveTask(t, isNew: false) }
                }
            }

            // 場所：Apple マップのプレビュー（予定と同じ。押すとマップで開く）
            if let p = PlaceValue(task.extra?["place"]) ?? task.location.flatMap({ $0.isEmpty ? nil : PlaceValue(name: $0) }) {
                Section {
                    PlaceMapPreview(place: p, height: 130, subline: task.travelMinutes.flatMap { m in task.plannedStart.map { "\(model.hm($0 - EpochMs(m) * MINUTE))に出発・移動\(durationLabel(m))" } })
                        .listRowInsets(EdgeInsets())
                } header: { Text("場所") }
            }
            Section("詳しい情報") {
                info("予定", "calendar", .red, when(task))
                if task.status != .notStarted && task.kind == .do {
                    info("作業した時間", "timer", .green, formatDuration(workedMs(task, at: now)))
                }
                if task.status == .running {
                    switch estimateEnd(task, subtasks: subs, now: now) {
                    case .estimate(let at): info("終わる見込み", "flag.checkered", .blue, model.hm(at))
                    case .unavailable(let why): info("終わる見込み", "flag.checkered", .blue, why)
                    }
                }
                if let m = task.estimateMinutes { info("見積時間", "hourglass", .teal, formatDuration(EpochMs(m) * MINUTE)) }
                if let d = task.deadline { info("締切", "flag.fill", .orange, "\(model.time.dayLabel(d)) \(model.hm(d))") }
                if let c = task.category, !c.isEmpty { info("カテゴリー", "tray.fill", .brown, c) }
                if task.extra?["alarm"]?.boolValue == true { info("アラーム", "alarm.fill", .orange, "開始の時刻に鳴らす") }
                if let n = task.extra?["notifies"]?.arrayValue, !n.isEmpty {
                    info("通知", "bell.fill", .pink, n.compactMap { $0.intValue.map { NotifyPicker.label(Int($0)) } }.joined(separator: "・"))
                }
            }

            if task.kind == .do && canAddSubtask(task) {
                Section {
                    ForEach(subs, id: \.id) { s in
                        Button {
                            model.perform { try model.repo.toggleSubtask(s.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: s.done ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(s.done ? Color.green : .secondary)
                                Text(s.title).strikethrough(s.done).foregroundStyle(s.done ? .secondary : .primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions { Button("削除", role: .destructive) { model.perform { try model.repo.deleteSubtask(s.id) } } }
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(tint)
                        TextField("サブタスクを追加", text: $newSubtask).submitLabel(.done).onSubmit(addSubtask)
                    }
                } header: {
                    HStack { Text("サブタスク"); Spacer(); if !subs.isEmpty { Text("\(subs.filter(\.done).count)/\(subs.count)").monospacedDigit() } }
                }
            }

            if !task.notes.isEmpty {
                Section("メモ") { Text(task.notes).textSelection(.enabled) }
            }
            if let urls = task.extra?["urls"]?.arrayValue, !urls.isEmpty {
                Section("リンク") {
                    ForEach(Array(urls.enumerated()), id: \.offset) { _, l in
                        if let s = l["url"]?.stringValue, let u = URL(string: s) {
                            Link(destination: u) { Label(l["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? (u.host() ?? s), systemImage: "link") }
                        }
                    }
                }
            }
            // 純正リマインダー・カレンダーと同じく、一番下に赤い削除（中央ぞろえ）
            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text(task.kind == .check ? "確認を削除" : "タスクを削除").font(.body.weight(.medium)).frame(maxWidth: .infinity)
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    /// 実行の操作：主な操作を1つ大きく、ほかは控えめに（それぞれ独立したボタン）
    @ViewBuilder
    private func actionButtons(_ task: MTTask) -> some View {
        let avail = availableActions(task)
        VStack(spacing: 10) {
            if avail.contains(.finish) && task.status == .running {
                HStack(spacing: 10) {
                    BigActionButton(title: "停止", symbol: "pause.fill", tint: .gray, prominent: false) { run(task, .pause) }
                    BigActionButton(title: "完了", symbol: "checkmark", tint: .green, prominent: true) { run(task, .finish) }
                }
            } else if avail.contains(.resume) {
                HStack(spacing: 10) {
                    BigActionButton(title: "再開", symbol: "play.fill", tint: .accentColor, prominent: true) { run(task, .resume) }
                    if avail.contains(.finish) { BigActionButton(title: "完了", symbol: "checkmark", tint: .green, prominent: false) { run(task, .finish) } }
                }
            } else if avail.contains(.start) {
                BigActionButton(title: task.specType == .morning ? "朝の準備を始める" : task.specType == .cleaning ? "清掃を始める" : "開始", symbol: "play.fill", tint: .accentColor, prominent: true) { model.startTask(task, router: router) }
            } else if avail.contains(.undoFinish) {
                BigActionButton(title: "完了を取り消す", symbol: "arrow.uturn.backward", tint: .gray, prominent: false) { run(task, .undoFinish) }
            }
            if avail.contains(.undoStart) && task.status == .running && workedMs(task, at: model.now) < 2 * MINUTE {
                Button("開始を取り消す") { run(task, .undoStart) }.font(.footnote).buttonStyle(.borderless)
            }
        }
    }

    private func run(_ task: MTTask, _ a: TaskAction) {
        if a == .finish { feedback += 1 }
        let undo: TaskAction? = a == .start ? .undoStart : a == .finish ? .undoFinish : nil
        let ok = model.perform(label(a) + "しました", undo: undo.map { u in { try model.repo.taskAction(task.id, u) } }) { try model.repo.taskAction(task.id, a) }
        if ok && (a == .start || a == .resume) { router.taskStarted(task.id, model: model) }
    }

    private func shift(_ task: MTTask, by delta: EpochMs, now: EpochMs) {
        guard let s = task.plannedStart else { return }
        shift(task, toStart: max(s + delta, now - (now % (5 * MINUTE)) + 5 * MINUTE))
    }

    private func shift(_ task: MTTask, toStart ns: EpochMs) {
        guard let s = task.plannedStart, let e = task.plannedEnd else { return }
        var c = task
        c.plannedStart = ns
        c.plannedEnd = ns + (e - s)
        let snap = task
        model.perform("\(model.hm(ns))に移しました", undo: { try model.repo.saveTask(snap, isNew: false) }) { try model.repo.saveTask(c, isNew: false) }
    }

    private func unplan(_ task: MTTask) {
        var c = task
        c.plannedStart = nil; c.plannedEnd = nil
        let snap = task
        model.perform("未割当へ移しました", undo: { try model.repo.saveTask(snap, isNew: false) }) { try model.repo.saveTask(c, isNew: false) }
    }

    private func info(_ title: String, _ symbol: String, _ tint: Color, _ value: String) -> some View {
        HStack(spacing: 12) {
            RowIcon(symbol: symbol, tint: tint)
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func taskTint(_ t: MTTask) -> Color {
        if let c = t.extra?["color"]?.stringValue { return Color(hex: c) }
        return t.kind == .check ? .checkTask : .doTask
    }

    private func statusText(_ t: MTTask, delay: DelayInfo) -> String {
        if t.kind == .check { return t.checked ? "確認済み" : "未確認" }
        switch t.status {
        case .done: return "完了"
        case .running: return "実行中"
        case .paused: return "一時停止"
        default: return delay.delayed ? "遅れ" : "未着手"
        }
    }

    private func statusColor(_ t: MTTask, delay: DelayInfo) -> Color {
        if t.kind == .check { return t.checked ? .green : .secondary }
        switch t.status {
        case .done: return .green
        case .running: return .green
        case .paused: return .orange
        default: return delay.delayed ? .red : .secondary
        }
    }

    /// 0:12:05 のような経過表示
    private func clock(_ ms: EpochMs) -> String {
        let s = Int(ms / 1000)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private func addSubtask() {
        let t = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let ok = model.perform { try model.repo.addSubtask(taskId: taskId, title: t) }
        if ok { newSubtask = "" }
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

    private func when(_ t: MTTask) -> String {
        if t.kind == .check, let c = t.checkAt { return "\(model.time.dayLabel(c)) \(model.hm(c))" }
        if let s = t.plannedStart, let e = t.plannedEnd { return "\(model.time.dayLabel(s)) \(model.hm(s))〜\(model.hm(e))" }
        return "時間は未定"
    }
}

/// 状態の小さな札（未着手・実行中・遅れなど）
struct StatusPill: View {
    var text: String
    var color: Color
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill((color == .secondary ? Color.gray : color).opacity(0.14)))
    }
}

/// 大きな操作ボタン（行の中で他のボタンと混ざらないよう、独自の形にする）
struct BigActionButton: View {
    var title: String
    var symbol: String
    var tint: Color
    var prominent: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                // 2つ並んでも文字が折り返して崩れないよう、1行に収めて縮める
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(prominent ? Color.white : tint == .gray ? Color.primary : tint)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(prominent ? .clear : Color(.separator).opacity(0.5), lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
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
                // 輪を押すだけで完了（もう一度押すと戻す）。純正リマインダーの丸と同じ
                Button {
                    feedback += 1
                    if task.isDone {
                        model.perform("未完了に戻しました", undo: { try model.repo.taskAction(task.id, .finish) }) { try model.repo.taskAction(task.id, .undoFinish) }
                    } else {
                        model.perform("完了しました", undo: { try model.repo.taskAction(task.id, .undoFinish) }) { try model.repo.taskAction(task.id, .finish) }
                    }
                } label: {
                    ProgressRing(value: scrub ?? actual, ideal: nil, symbol: IconMap.symbol(task.icon), size: 32, running: task.status == .running, done: task.isDone)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.isDone ? "未完了に戻す" : "完了にする")
            }
            Group {
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
                    if scrub == nil && !chips.isEmpty {
                        // 締切までの残り・見積・サブタスク・カテゴリーなど
                        HStack(spacing: 4) {
                            ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                                HStack(spacing: 2) {
                                    Image(systemName: c.symbol).imageScale(.small)
                                    Text(c.text).lineLimit(1)
                                }
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(c.tint)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(c.tint.opacity(0.12)))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            // タップで開く・長押し→横になぞって実績（UIKit のジェスチャー：一回目のタップが確実に届き、上下のスクロールも妨げない）
            .overlay {
                PressDragRecognizer(
                    minimumDuration: 0.35,
                    onTap: { router.open(.task(task.id)) },
                    onBegan: canScrub ? { _ in beginScrub() } : nil,
                    onChanged: canScrub ? { _, t in moveScrub(t.width) } : nil,
                    onEnded: canScrub ? { _, _ in endScrub() } : nil,
                    onCancelled: { scrub = nil }
                )
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { router.open(.task(task.id)) }
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
    private func beginScrub() {
        scrubBase = actualProgress(task, subtasks: model.subtasks(of: task.id)).value ?? idealProgress(task, now: model.now) ?? 0
        scrub = scrubBase
        picked += 1
    }

    private func moveScrub(_ dx: CGFloat) {
        let v = min(1, max(0, scrubBase + Double(dx / rowWidth)))
        let snapped = (v * 20).rounded() / 20
        if Int(snapped * 20) != step { step = Int(snapped * 20) }
        scrub = snapped
    }

    private func endScrub() {
        guard let v = scrub else { return }
        if v >= 1 { confirmComplete = true; return }
        if abs(v - scrubBase) < 0.001 { scrub = nil; return }
        record(v)
        scrub = nil
    }

    private func record(_ v: Double) {
        model.perform("実績を\(Int((v * 100).rounded()))%にしました") { try model.repo.recordProgress(task.id, value: v) }
    }

    private struct Chip { var text: String; var symbol: String; var tint: Color }

    private var chips: [Chip] {
        var out: [Chip] = []
        if task.status == .running { out.append(Chip(text: formatDuration(workedMs(task, at: model.now)), symbol: "timer", tint: .green)) }
        if let d = task.deadline, !task.isDone {
            let m = Int((d - model.now) / MINUTE)
            let text = m < 0 ? "締切を過ぎました" : m < 60 ? "締切まであと\(m)分" : m < 24 * 60 ? "締切まであと\(m / 60)時間" : "締切まであと\(m / 60 / 24)日"
            out.append(Chip(text: text, symbol: "flag.fill", tint: m < 24 * 60 ? .red : .orange))
        }
        let subs = model.subtasks(of: task.id)
        if !subs.isEmpty { out.append(Chip(text: "\(subs.filter(\.done).count)/\(subs.count)", symbol: "checklist", tint: .secondary)) }
        if let m = task.estimateMinutes, !task.isDone { out.append(Chip(text: m < 60 ? "\(m)分" : "\(m / 60)時間\(m % 60 == 0 ? "" : "\(m % 60)分")", symbol: "hourglass", tint: .teal)) }
        if let c = task.category, !c.isEmpty { out.append(Chip(text: c, symbol: "tray.fill", tint: .brown)) }
        return Array(out.prefix(3))
    }

    private var subtitle: String? {
        var p: [String] = []
        if task.kind == .check, let c = task.checkAt { p.append("\(model.time.dayLabel(c)) \(model.hm(c))") }
        if let s = task.plannedStart, let e = task.plannedEnd { p.append("\(model.time.dayLabel(s)) \(model.hm(s))〜\(model.hm(e))") }

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

/// 遅れの長さ（分・時間・日）
func lateText(_ m: Int) -> String {
    if m < 60 { return "\(m)分" }
    if m < 24 * 60 { return m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分" }
    return "\(m / (24 * 60))日"
}
