import SwiftUI
import MyTimeCore

/// カレンダーの検索（純正と同じく右上の虫めがねから）。前1年・先1年の予定とタスクを、名前・場所・メモで探す。
/// 結果は日付ごとにまとめ、近い日から。押すとその予定・タスクを開く
struct CalendarSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Hit: Identifiable {
        var id: String
        var title: String
        var at: EpochMs
        var sub: String
        var color: Color
        var route: SheetRoute
        var other: Bool
        var task: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                let hits = results()
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("予定とタスクを検索", systemImage: "magnifyingglass", description: Text("名前・場所・メモで探せます"))
                        .listRowBackground(Color.clear)
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                } else {
                    let days = Dictionary(grouping: hits) { model.time.startOfDay($0.at) }
                    ForEach(days.keys.sorted { abs($0 - model.now) < abs($1 - model.now) }, id: \.self) { d in
                        Section(model.time.dayLabel(d) + (model.time.isSameDay(d, model.now) ? "（今日）" : "")) {
                            ForEach(days[d]!.sorted { $0.at < $1.at }) { h in
                                Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { router.open(h.route) } } label: {
                                    HStack(spacing: 10) {
                                        if h.task {
                                            Image(systemName: "circle").font(.footnote.weight(.semibold)).foregroundStyle(h.color)
                                        } else {
                                            RoundedRectangle(cornerRadius: 2).fill(h.other ? Color.secondary.opacity(0.4) : h.color).frame(width: 4, height: 30)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(h.title).foregroundStyle(h.other ? .secondary : .primary).lineLimit(1)
                                            Text(h.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                                        }
                                    }
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "予定・タスク")
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }

    private func results() -> [Hit] {
        let words = TasksScreen.normalize(query).split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
        guard !words.isEmpty else { return [] }
        func match(_ s: String) -> Bool { let h = TasksScreen.normalize(s); return words.allSatisfy { h.contains($0) } }
        let t = model.time
        var out: [Hit] = []
        for o in model.visibleEvents(from: t.addDays(model.now, -365), to: t.addDays(model.now, 365), includeStruck: true)
        where match(o.title + " " + (o.event.placeName ?? "") + " " + o.event.notes) {
            let place = o.event.placeName.map { "・\($0)" } ?? ""
            out.append(Hit(id: "e" + o.id, title: o.title, at: o.start,
                           sub: (o.event.allDay ? "終日" : "\(t.hm(o.start))〜\(t.hm(o.end))") + place,
                           color: model.occurrenceColor(o), route: .event(o.id), other: model.isOtherPerson(o.event.calendarId), task: false))
            if out.count > 200 { break }
        }
        for task in model.tasks where match(task.title + " " + task.notes) {
            let at = taskAnchor(task) ?? task.onDay ?? task.deadline ?? task.createdAt
            out.append(Hit(id: "t" + task.id, title: task.title, at: at, sub: task.isDone ? "済み" : taskAnchor(task).map { t.hm($0) } ?? "タスク",
                           color: task.kind == .check ? .checkTask : .doTask, route: .task(task.id), other: false, task: true))
        }
        return out
    }
}
