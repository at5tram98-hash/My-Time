import SwiftUI
import MyTimeCore

/// タスク一覧。スマートリスト（今日・予定あり・未割当・確認・フラグ・完了）と検索
struct TasksScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    /// 選んだ絞り込みは次に開いたときも同じ
    @AppStorage("tasks.filter") private var filter: Filter = .open
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
                // 上：次にやること（1行）と、生活（朝・清掃・持ち物）。検索中は出さない
                if query.isEmpty {
                    Section { nextRow }
                    Section { LifeTaskRows() } header: { Text("生活") }
                }
                Section {
                } header: {
                    filterBar
                        .textCase(nil)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, -16)
                }

                if list.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? emptyTitle : "見つかりません", systemImage: query.isEmpty ? filter.symbol : "magnifyingglass")
                    } description: {
                        if query.isEmpty { Text(emptyHint) } else { Text("「\(query)」を含むタスクはありません") }
                    } actions: {
                        if !query.isEmpty { Button("検索をやめる") { query = "" } }
                        else if filter == .open || filter == .today || filter == .inbox {
                            Button("タスクを追加") { quickFocused = true }.buttonStyle(.borderedProminent)
                        }
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
                case .belongings: BelongingsView()
                }
            }
        }
    }

    // MARK: 上の部品

    /// 次にやること（1行）：今日の進み・次のタスク・開始／完了のボタン。押すとそのタスクを開く
    private var nextRow: some View {
        let d0 = model.time.startOfDay(model.now)
        let today = tasksForDay(model.tasks, day: d0, time: model.time)
        let done = today.filter(\.isDone).count
        let running = model.tasks.first { $0.status == .running }
        // 次にやること：今日の画面と同じく、今日これから（今日の中で時刻の早い順）。前の日の遅れは「期限切れ」で見る
        let cands = today.filter { !$0.isDone && $0.kind == .do && ($0.plannedStart ?? d0) >= d0 }
        let upcoming = cands.filter { ($0.plannedEnd ?? .max) > model.now }
        let next = running ?? (upcoming.isEmpty ? cands : upcoming).min { (taskAnchor($0) ?? .max) < (taskAnchor($1) ?? .max) }
        let ratio = today.isEmpty ? 0 : Double(done) / Double(today.count)
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 4)
                Circle().trim(from: 0, to: ratio).stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(done)/\(today.count)").font(.system(size: 11, weight: .bold)).monospacedDigit()
            }
            .frame(width: 40, height: 40)
            .animation(Motion.value, value: ratio)
            .accessibilityLabel("今日のタスク \(today.count)件中 \(done)件完了")
            VStack(alignment: .leading, spacing: 2) {
                if let t = next {
                    Text(t.status == .running ? "実行中" : "次にやること").font(.caption.weight(.semibold)).foregroundStyle(t.status == .running ? .green : .secondary)
                    Text(t.title).font(.body.weight(.semibold)).lineLimit(1)
                    if let s = t.plannedStart {
                        Text((model.time.isSameDay(s, model.now) ? "" : model.time.dayLabel(s) + " ") + "\(model.hm(s))〜\(t.plannedEnd.map(model.hm) ?? "")")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text("今日").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(today.isEmpty ? "今日のタスクはありません" : "今日のタスクはすべて完了").font(.body.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
            if let t = next, t.kind == .do, !t.isDone {
                Button {
                    if t.status == .running {
                        model.perform("完了しました", undo: { try model.repo.taskAction(t.id, .undoFinish) }) { try model.repo.taskAction(t.id, .finish) }
                    } else {
                        model.startTask(t, router: router)
                    }
                } label: {
                    Image(systemName: t.status == .running ? "checkmark" : "play.fill").font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(t.status == .running ? Color.green : Color.accentColor))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(t.status == .running ? "完了" : "開始")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let t = next { router.open(.task(t.id)) } }
    }

    /// カテゴリーごと（なしは最後）
    private func categoryGroups(_ list: [MTTask]) -> [(String, [MTTask], Color)] {
        let dict = Dictionary(grouping: list) { $0.category?.isEmpty == false ? $0.category! : "" }
        return dict.keys.sorted { a, b in a.isEmpty ? false : b.isEmpty ? true : a < b }.map { k in (k.isEmpty ? "カテゴリーなし" : k, dict[k]!, Color.secondary) }
    }

    /// 絞り込み：平らなチップ。選んだものだけ塗る（印はなめらかに移動する）
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
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
                                Capsule().fill(Color.accentColor.opacity(0.14))
                                    .matchedGeometryEffect(id: "filter", in: filterNS)
                            } else {
                                Capsule().fill(Color(.tertiarySystemFill))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
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
                // 時刻や種類も決めたいとき：書いた名前のまま入力画面へ
                Button {
                    let t = quickTitle.trimmingCharacters(in: .whitespaces)
                    quickTitle = ""; quickFocused = false
                    router.open(.editor(EditorSeed(kind: .task, title: t)))
                } label: { Image(systemName: "square.and.pencil").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("詳しく入力")
                    .transition(.scale.combined(with: .opacity))
                Button { addQuick() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
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
                    // まだ始めていなければ、右へなぞって開始
                    if t.status == .notStarted {
                        Button("開始", systemImage: "play.fill") { model.startTask(t, router: router) }
                        .tint(.blue)
                    }
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
        model.perform("削除しました", undo: { try model.repo.saveTask(snap, isNew: true) }) { model.skipAutoMorning(t); try model.repo.deleteTask(t.id) }
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
            // 日付だけのタスクは、その日の終わりまでは期限切れにしない
            if let d = t.onDay, model.time.addDays(d, 1) <= now, t.deadline == nil { late.append(t); continue }
            guard let a = taskAnchor(t) ?? t.onDay ?? t.deadline else { none.append(t); continue }
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
        case .today: return tasksForDay([t], day: model.time.startOfDay(model.now), time: model.time).isEmpty == false || (!t.isDone && t.onDay.map { model.time.isSameDay($0, model.now) } == true)
        case .inbox: return t.kind == .do && !t.isDone && t.plannedStart == nil && t.onDay == nil
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
                    let x = taskAnchor(a) ?? a.onDay ?? a.deadline ?? .max, y = taskAnchor(b) ?? b.onDay ?? b.deadline ?? .max
                    return x != y ? x < y : (a.createdAt, a.id) < (b.createdAt, b.id)
                }
            }
    }
}
