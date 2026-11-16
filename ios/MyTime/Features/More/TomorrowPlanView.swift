import SwiftUI
import MyTimeCore

/// 翌日計画。明日の予定とタスクを時刻順に見て、ここから明日へ直接入れる。
/// （今日の画面の右端に灰色で出るものと同じ中身）
struct TomorrowPlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @AppStorage("today.showTomorrow") private var showTomorrow = true
    @State private var quick = ""
    @FocusState private var quickFocused: Bool

    private var d1: EpochMs { model.time.addDays(model.time.startOfDay(model.now), 1) }

    private struct Row: Identifiable {
        var id: String
        var at: EpochMs?
        var end: EpochMs?
        var title: String
        var symbol: String
        var isEvent: Bool
        var open: SheetRoute
    }

    private var rows: [Row] {
        let d2 = model.time.addDays(d1, 1)
        var out: [Row] = model.visibleEvents(from: d1, to: d2).filter { $0.start < d2 && $0.end > d1 }.map { o in
            Row(id: "e" + o.id, at: o.event.allDay ? nil : o.start, end: o.end, title: o.title, symbol: o.event.specType.flatMap { SPEC_BY_ID[$0]?.symbol } ?? "calendar", isEvent: true, open: .event(o.id))
        }
        for t in model.tasks where !t.isDone {
            let a = t.kind == .check ? t.checkAt : t.plannedStart
            if let a, a >= d1, a < d2 {
                out.append(Row(id: "t" + t.id, at: a, end: t.plannedEnd, title: t.title, symbol: t.kind == .check ? "checkmark.circle" : IconMap.symbol(t.icon), isEvent: false, open: .task(t.id)))
            }
        }
        return out.sorted { ($0.at ?? 0) < ($1.at ?? 0) }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.gray)
                    TextField("明日やること（改行で追加・時間は未定）", text: $quick)
                        .focused($quickFocused).submitLabel(.next).onSubmit(addQuick)
                }
                HStack(spacing: 10) {
                    addButton("明日のタスク", "checklist", .task)
                    addButton("明日の予定", "calendar", .event)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: { Text("入れたものは、今日の画面の右端に灰色で表示されます。") }

            Section {
                if rows.isEmpty {
                    Text("明日の予定・タスクはまだありません").foregroundStyle(.secondary)
                }
                ForEach(rows) { r in
                    Button { router.open(r.open) } label: {
                        HStack(spacing: 12) {
                            Text(r.at.map(model.hm) ?? "終日").font(.subheadline.weight(.semibold)).monospacedDigit()
                                .frame(width: 48, alignment: .leading).foregroundStyle(.secondary)
                            Image(systemName: r.symbol).foregroundStyle(.gray).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).foregroundStyle(.primary)
                                Text(r.isEvent ? "予定" : "タスク").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text(model.dayTitle(d1)) }

            Section {
                Toggle(isOn: $showTomorrow) { Label("今日の画面に翌日計画を出す", systemImage: "rectangle.split.3x1") }
            }
        }
        .navigationTitle("翌日の計画")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addButton(_ title: String, _ symbol: String, _ kind: EditorSeed.Kind) -> some View {
        Button {
            let s = d1 + 9 * HOUR
            router.open(.editor(EditorSeed(kind: kind, start: s, end: s + HOUR)))
        } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    /// 明日の「時間を決めないタスク」として入れる（明日の9時を仮の開始に）
    private func addQuick() {
        let name = quick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { quickFocused = false; return }
        var t = MTTask.make(title: name, now: model.now, id: model.repo.newId())
        let s = d1 + 9 * HOUR
        t.plannedStart = s
        t.plannedEnd = s + 30 * MINUTE
        let id = t.id
        if model.perform("明日に追加しました", undo: { try model.repo.deleteTask(id) }, { try model.repo.saveTask(t, isNew: true) }) {
            quick = ""
            quickFocused = true
        }
    }
}
