import SwiftUI
import MyTimeCore

/// タスク一覧。スマートリスト（今日・予定あり・未割当・確認・フラグ・完了）と検索
struct TasksScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var filter: Filter = .open
    @State private var query = ""
    /// 一覧の上で直接入れる新しいタスク（純正リマインダーと同じ）
    @State private var quickTitle = ""
    @FocusState private var quickFocused: Bool

    enum Filter: String, CaseIterable, Identifiable {
        case open = "未完了", today = "今日", inbox = "未割当", check = "確認", flagged = "フラグ", done = "完了"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .open: return "tray.full"
            case .today: return "sun.max"
            case .inbox: return "tray"
            case .check: return "checkmark.circle"
            case .flagged: return "flag"
            case .done: return "checkmark.seal"
            }
        }
    }

    var body: some View {
        NavigationStack {
            let list = filtered
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Filter.allCases) { f in
                                Button { withAnimation(Motion.pop) { filter = f } } label: {
                                    Label("\(f.rawValue) \(count(f))", systemImage: f.symbol)
                                        .font(.subheadline.weight(filter == f ? .semibold : .regular))
                                        .padding(.horizontal, 12).frame(minHeight: 34)
                                        .background(Capsule().fill(filter == f ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill)))
                                        .foregroundStyle(filter == f ? Color.accentColor : .primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(filter == f ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

                if filter == .open || filter == .inbox {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                            TextField("新しいタスク（改行で追加）", text: $quickTitle)
                                .focused($quickFocused)
                                .submitLabel(.next)
                                .onSubmit(addQuick)
                        }
                    } footer: {
                        if quickFocused { Text("時間を決めずに「未割当」へ入ります。続けて入力できます。") }
                    }
                }

                if list.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? emptyTitle : "見つかりません", systemImage: query.isEmpty ? filter.symbol : "magnifyingglass")
                    } description: {
                        if query.isEmpty { Text(emptyHint) }
                    }
                    .listRowBackground(Color.clear)
                } else if filter == .open && query.isEmpty {
                    ForEach(groups(list), id: \.0) { title, items, tint in
                        Section {
                            ForEach(items, id: \.id) { taskRow($0) }
                        } header: {
                            HStack {
                                Text(title).foregroundStyle(tint)
                                Spacer()
                                Text("\(items.count)").monospacedDigit()
                            }
                        }
                    }
                } else {
                    ForEach(list, id: \.id) { taskRow($0) }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "タスクを検索")
            .navigationTitle("タスク")
            .toolbar { MainToolbar() }
            .animation(Motion.pop, value: filter)
        }
    }

    @ViewBuilder
    private func taskRow(_ t: MTTask) -> some View {
        TaskRow(task: t)
            .swipeActions(edge: .trailing) {
                Button("削除", systemImage: "trash", role: .destructive) { delete(t) }
                Button(t.flagged ? "フラグを外す" : "フラグ", systemImage: t.flagged ? "flag.slash" : "flag") { toggleFlag(t) }
                    .tint(.orange)
            }
            .swipeActions(edge: .leading) {
                if t.kind == .do && t.status != .done {
                    Button("完了", systemImage: "checkmark") { finish(t) }.tint(.green)
                }
            }
            // 長押しのメニュー（純正リマインダーと同じく、よく使う操作をまとめる）
            .contextMenu {
                Button("開く", systemImage: "arrow.up.forward.app") { router.open(.task(t.id)) }
                Button("編集", systemImage: "pencil") { router.open(.editor(EditorSeed(kind: .task, taskId: t.id))) }
                if t.kind == .do && t.status != .done {
                    Button("完了", systemImage: "checkmark.circle") { finish(t) }
                    if t.plannedStart == nil || !model.time.isSameDay(t.plannedStart!, model.now) {
                        Button("今日やる", systemImage: "sun.max") { doToday(t) }
                    }
                }
                Button(t.flagged ? "フラグを外す" : "フラグ", systemImage: t.flagged ? "flag.slash" : "flag") { toggleFlag(t) }
                Divider()
                Button("削除", systemImage: "trash", role: .destructive) { delete(t) }
            }
    }

    private func addQuick() {
        let name = quickTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { quickFocused = false; return }
        let t = MTTask.make(title: name, now: model.now, id: model.repo.newId())
        let id = t.id
        if model.perform("「\(name)」を追加しました", undo: { try model.repo.deleteTask(id) }, { try model.repo.saveTask(t, isNew: true) }) {
            quickTitle = ""
            quickFocused = true
        }
    }

    private func delete(_ t: MTTask) {
        let snap = t
        model.perform("削除しました", undo: { try model.repo.saveTask(snap, isNew: true) }) { try model.repo.deleteTask(t.id) }
    }

    private func toggleFlag(_ t: MTTask) {
        var c = t; c.flagged.toggle()
        model.perform(c.flagged ? "フラグを付けました" : nil) { try model.repo.saveTask(c, isNew: false) }
    }

    private func finish(_ t: MTTask) {
        model.perform("完了しました", undo: { try model.repo.taskAction(t.id, .undoFinish) }) {
            if t.status == .notStarted { try model.repo.taskAction(t.id, .start) }
            try model.repo.taskAction(t.id, .finish)
        }
    }

    /// 今日の次の15分区切りから、見積もり（なければ30分）の長さで入れる
    private func doToday(_ t: MTTask) {
        let snap = t
        var c = t
        let s = ((model.now / (15 * MINUTE)) + 1) * 15 * MINUTE
        c.plannedStart = s
        c.plannedEnd = s + EpochMs(t.estimateMinutes ?? 30) * MINUTE
        model.perform("今日の\(model.hm(s))に入れました", undo: { try model.repo.saveTask(snap, isNew: false) }) { try model.repo.saveTask(c, isNew: false) }
    }

    /// 未完了を「期限切れ・今日・明日・今後・時間未定」に分ける
    private func groups(_ list: [MTTask]) -> [(String, [MTTask], Color)] {
        let now = model.now
        let d0 = model.time.startOfDay(now), d1 = model.time.addDays(d0, 1), d2 = model.time.addDays(d0, 2)
        var late: [MTTask] = [], today: [MTTask] = [], tomorrow: [MTTask] = [], later: [MTTask] = [], none: [MTTask] = []
        for t in list {
            let end = t.kind == .check ? t.checkAt : (t.plannedEnd ?? t.deadline)
            if let e = end, e < now { late.append(t); continue }
            guard let a = taskAnchor(t) ?? t.deadline else { none.append(t); continue }
            if a < d1 { today.append(t) } else if a < d2 { tomorrow.append(t) } else { later.append(t) }
        }
        return [("期限切れ", late, Color.red), ("今日", today, Color.accentColor), ("明日", tomorrow, Color.secondary), ("今後", later, Color.secondary), ("時間未定", none, Color.secondary)]
            .filter { !$0.1.isEmpty }
    }

    private var emptyTitle: String {
        switch filter {
        case .open: return "やることはありません"
        case .today: return "今日のタスクはありません"
        case .inbox: return "未割当はありません"
        case .check: return "確認することはありません"
        case .flagged: return "フラグはありません"
        case .done: return "完了したタスクはまだありません"
        }
    }

    private var emptyHint: String {
        switch filter {
        case .open, .inbox: return "上の欄に入力して改行すると、すぐに追加できます。"
        case .today: return "一覧で長押しして「今日やる」を選ぶと、今日に入れられます。"
        case .flagged: return "一覧で左へなぞると、フラグを付けられます。"
        case .check: return "「確認する」タスクは、新しく追加するときに選べます。"
        case .done: return "一覧で右へなぞると、完了にできます。"
        }
    }

    private func matches(_ t: MTTask, _ f: Filter) -> Bool {
        switch f {
        case .open: return !t.isDone
        case .today: return tasksForDay([t], day: model.time.startOfDay(model.now), time: model.time).isEmpty == false
        case .inbox: return t.kind == .do && !t.isDone && t.plannedStart == nil
        case .check: return t.kind == .check && !t.checked
        case .flagged: return t.flagged && !t.isDone
        case .done: return t.isDone
        }
    }
    private func count(_ f: Filter) -> Int { model.tasks.filter { matches($0, f) }.count }

    private var filtered: [MTTask] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.tasks
            .filter { matches($0, filter) }
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.notes.localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                let x = taskAnchor(a) ?? a.deadline ?? .max, y = taskAnchor(b) ?? b.deadline ?? .max
                return x != y ? x < y : a.createdAt < b.createdAt
            }
    }
}
