import SwiftUI
import MyTimeCore

/// タスク一覧。スマートリスト（今日・予定あり・未割当・確認・フラグ・完了）と検索
struct TasksScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var filter: Filter = .open
    /// 並び：time（時刻）・deadline（締切）・created（追加順）・title（名前）
    @AppStorage("tasks.sort") private var sort = "time"
    /// まとめ方：when（いつ）・category（カテゴリー）・none
    @AppStorage("tasks.group") private var grouping = "when"
    @State private var query = ""
    /// 一覧の上で直接入れる新しいタスク（純正リマインダーと同じ）
    @State private var quickTitle = ""
    @FocusState private var quickFocused: Bool
    @Namespace private var filterNS

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
        @Bindable var router = router
        NavigationStack(path: $router.tasksPath) {
            let list = filtered
            List {
                Section {
                } header: {
                    VStack(spacing: 10) {
                        todayCard
                        LifeTaskCards()
                        summaryTiles
                        filterBar
                    }
                    .textCase(nil)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, -4)
                    .padding(.bottom, 4)
                }

                if list.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? emptyTitle : "見つかりません", systemImage: query.isEmpty ? filter.symbol : "magnifyingglass")
                    } description: {
                        if query.isEmpty { Text(emptyHint) } else { Text("「\(query)」を含むタスクはありません") }
                    } actions: {
                        if !query.isEmpty { Button("検索をやめる") { query = "" } }
                    }
                    .listRowBackground(Color.clear)
                } else if filter == .open && query.isEmpty && grouping != "none" {
                    ForEach(grouping == "category" ? categoryGroups(list) : groups(list), id: \.0) { title, items, tint in
                        Section {
                            ForEach(items, id: \.id) { taskRow($0) }
                        } header: {
                            HStack {
                                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(tint)
                                Spacer()
                                GlassPill(text: "\(items.count)", tint: tint)
                            }
                            .textCase(nil)
                        }
                    }
                } else if !query.isEmpty {
                    // 検索の結果（件数を見出しに）
                    Section {
                        ForEach(list, id: \.id) { taskRow($0) }
                    } header: { Text("検索結果 \(list.count)件").textCase(nil) }
                } else {
                    ForEach(list, id: \.id) { taskRow($0) }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "タスクを検索")
            // 下に浮かぶガラスの入力欄（改行で続けて追加）
            .safeAreaInset(edge: .bottom) { if filter == .open || filter == .inbox { quickAddBar } }
            .navigationTitle("タスク")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("並び", selection: $sort) {
                            Label("時刻の順", systemImage: "clock").tag("time")
                            Label("締切の順", systemImage: "flag.checkered").tag("deadline")
                            Label("追加した順", systemImage: "plus.circle").tag("created")
                            Label("名前の順", systemImage: "textformat").tag("title")
                        }
                        Picker("まとめ方", selection: $grouping) {
                            Label("いつ（今日・明日…）", systemImage: "calendar").tag("when")
                            Label("カテゴリー", systemImage: "tray.full").tag("category")
                            Label("まとめない", systemImage: "list.bullet").tag("none")
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("並びとまとめ方")
                }
                MainToolbar()
            }
            .animation(Motion.pop, value: filter)
            .navigationDestination(for: TasksRoute.self) { r in
                switch r {
                case .morning: MorningHomeView()
                case .morningRun: MorningRunView()
                case .cleaning: CleaningHomeView()
                case .cleaningRun: CleaningSessionView()
                }
            }
        }
    }

    // MARK: ガラスの部品

    /// 上のまとめ（今日・期限切れ・フラグ）。押すとその絞り込みへ
    /// 今日の進み：完了の割合・作業した時間・次にやること（すぐ開始できる）
    private var todayCard: some View {
        let d0 = model.time.startOfDay(model.now)
        let today = tasksForDay(model.tasks, day: d0, time: model.time)
        let done = today.filter(\.isDone).count
        let worked = model.tasks.reduce(EpochMs(0)) { sum, t in
            sum + t.intervals.reduce(0) { $0 + max(0, min($1.end ?? model.now, model.now) - max($1.start, d0)) }
        }
        let running = model.tasks.first { $0.status == .running }
        // 次にやること：今日の画面と同じく、今日これから（今日の中で時刻の早い順）。前の日の遅れは「期限切れ」で見る
        let cands = today.filter { !$0.isDone && $0.kind == .do && ($0.plannedStart ?? d0) >= d0 }
        let upcoming = cands.filter { ($0.plannedEnd ?? .max) > model.now }
        let next = running ?? (upcoming.isEmpty ? cands : upcoming).min { (taskAnchor($0) ?? .max) < (taskAnchor($1) ?? .max) }
        let ratio = today.isEmpty ? 0 : Double(done) / Double(today.count)
        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                Circle().trim(from: 0, to: ratio).stroke(Color.green.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(done)/\(today.count)").font(.subheadline.weight(.bold)).monospacedDigit()
                    Text("今日").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 62, height: 62)
            .animation(Motion.value, value: ratio)
            VStack(alignment: .leading, spacing: 4) {
                Label("作業 \(formatDuration(worked))", systemImage: "timer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let t = next {
                    Text(t.status == .running ? "実行中" : "次にやること").font(.caption2.weight(.bold)).foregroundStyle(t.status == .running ? .green : .accentColor)
                    Text(t.title).font(.headline).lineLimit(1)
                    if let s = t.plannedStart {
                        Text((model.time.isSameDay(s, model.now) ? "" : model.time.dayLabel(s) + " ") + "\(model.hm(s))〜\(t.plannedEnd.map(model.hm) ?? "")")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text(today.isEmpty ? "今日のタスクはありません" : "今日のタスクはすべて完了").font(.headline)
                }
            }
            Spacer(minLength: 0)
            if let t = next, t.kind == .do, !t.isDone {
                Button {
                    let a: TaskAction = t.status == .running ? .finish : t.status == .paused ? .resume : .start
                    model.perform(a == .finish ? "完了しました" : "開始しました", undo: { try model.repo.taskAction(t.id, a == .finish ? .undoFinish : .undoStart) }) {
                        try model.repo.taskAction(t.id, a)
                    }
                } label: {
                    Image(systemName: t.status == .running ? "checkmark" : "play.fill").font(.title3.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(t.status == .running ? Color.green.gradient : Color.accentColor.gradient))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(t.status == .running ? "完了" : "開始")
            }
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if let t = next { router.open(.task(t.id)) } }
    }

    /// カテゴリーごと（なしは最後）
    private func categoryGroups(_ list: [MTTask]) -> [(String, [MTTask], Color)] {
        let dict = Dictionary(grouping: list) { $0.category?.isEmpty == false ? $0.category! : "" }
        return dict.keys.sorted { a, b in a.isEmpty ? false : b.isEmpty ? true : a < b }.map { k in (k.isEmpty ? "カテゴリーなし" : k, dict[k]!, Color.secondary) }
    }

    private var summaryTiles: some View {
        let late = model.tasks.filter { !$0.isDone && $0.kind == .do && ($0.plannedEnd.map { $0 < model.now } ?? false) }.count
        return Group {
            HStack(spacing: 10) {
                tile("今日", "\(count(.today))", "sun.max.fill", .orange) { filter = .today }
                tile("期限切れ", "\(late)", "exclamationmark.circle.fill", late > 0 ? .red : .secondary) { filter = .open }
                tile("フラグ", "\(count(.flagged))", "flag.fill", .orange) { filter = .flagged }
                tile("完了", "\(count(.done))", "checkmark.seal.fill", .green) { filter = .done }
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.pop) { action() } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Text(value).font(.title3.weight(.bold)).monospacedDigit().contentTransition(.numericText())
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(title) \(value)件")
    }

    /// 絞り込み：ガラスの帯の上を、選んだ印がなめらかに移動する
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Filter.allCases) { f in
                    let on = filter == f
                    Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { filter = f } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: f.symbol).imageScale(.small)
                            Text(f.rawValue).lineLimit(1).fixedSize()
                            Text("\(count(f))").monospacedDigit().foregroundStyle(on ? Color.accentColor.opacity(0.8) : .secondary)
                        }
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.accentColor : .primary)
                        .fixedSize()
                        .padding(.horizontal, 12).frame(minHeight: 34)
                        .background {
                            if on {
                                Capsule().fill(Color.accentColor.opacity(0.16))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.6))
                                    .matchedGeometryEffect(id: "filter", in: filterNS)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .glass(Capsule(), interactive: true)
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: filter)
    }

    /// 画面の下に浮かぶガラスの入力欄
    private var quickAddBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
            TextField("新しいタスク（改行で追加）", text: $quickTitle)
                .focused($quickFocused)
                .submitLabel(.next)
                .onSubmit(addQuick)
            if !quickTitle.isEmpty {
                Button { addQuick() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glass(Capsule(), interactive: true)
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .padding(.horizontal).padding(.bottom, 6)
        .animation(.snappy, value: quickTitle.isEmpty)
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

    /// 検索の文字をそろえる（全角・半角、大文字・小文字、ひらがな・カタカナを同じに）
    static func normalize(_ s: String) -> String {
        let w = s.precomposedStringWithCompatibilityMapping.lowercased()
        return w.applyingTransform(.hiraganaToKatakana, reverse: false) ?? w
    }

    private var filtered: [MTTask] {
        // 空白で区切った語をすべて含むもの
        let words = Self.normalize(query).split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
        return model.tasks
            .filter { matches($0, filter) }
            .filter { t in
                guard !words.isEmpty else { return true }
                let hay = Self.normalize(t.title + " " + t.notes + " " + (t.category ?? ""))
                return words.allSatisfy { hay.contains($0) }
            }
            .sorted { a, b in
                switch sort {
                case "deadline":
                    let x = a.deadline ?? .max, y = b.deadline ?? .max
                    return x != y ? x < y : (taskAnchor(a) ?? .max) < (taskAnchor(b) ?? .max)
                // 同じ値のときは追加順 → ID で並びを固定（揺れない）
                case "created": return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id < b.id
                case "title":
                    let c = a.title.localizedStandardCompare(b.title)
                    return c != .orderedSame ? c == .orderedAscending : (a.createdAt, a.id) < (b.createdAt, b.id)
                default:
                    let x = taskAnchor(a) ?? a.deadline ?? .max, y = taskAnchor(b) ?? b.deadline ?? .max
                    return x != y ? x < y : (a.createdAt, a.id) < (b.createdAt, b.id)
                }
            }
    }
}
