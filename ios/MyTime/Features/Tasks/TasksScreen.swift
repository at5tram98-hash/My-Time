import SwiftUI
import MyTimeCore

/// タスク一覧。スマートリスト（今日・予定あり・未割当・確認・フラグ・完了）と検索
struct TasksScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var filter: Filter = .open
    @State private var query = ""

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

                if list.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "タスクはありません" : "見つかりません", systemImage: query.isEmpty ? "checklist" : "magnifyingglass")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(list, id: \.id) { t in
                        TaskRow(task: t)
                            .swipeActions(edge: .trailing) {
                                Button("削除", systemImage: "trash", role: .destructive) {
                                    let snap = t
                                    model.perform("削除しました", undo: { try model.repo.saveTask(snap, isNew: true) }) { try model.repo.deleteTask(t.id) }
                                }
                                Button(t.flagged ? "フラグを外す" : "フラグ", systemImage: t.flagged ? "flag.slash" : "flag") {
                                    var c = t; c.flagged.toggle()
                                    model.perform { try model.repo.saveTask(c, isNew: false) }
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading) {
                                if t.kind == .do && t.status != .done {
                                    Button("完了", systemImage: "checkmark") {
                                        model.perform("完了しました", undo: { try model.repo.taskAction(t.id, .undoFinish) }) {
                                            if t.status == .notStarted { try model.repo.taskAction(t.id, .start) }
                                            try model.repo.taskAction(t.id, .finish)
                                        }
                                    }
                                    .tint(.green)
                                }
                            }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "タスクを検索")
            .navigationTitle("タスク")
            .toolbar { MainToolbar() }
            .animation(Motion.pop, value: filter)
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
