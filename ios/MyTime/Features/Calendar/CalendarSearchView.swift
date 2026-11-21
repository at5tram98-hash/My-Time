import SwiftUI
import MyTimeCore

/// カレンダーの検索（純正と同じく右上の虫めがねから）。前1年・先1年の予定とタスクを、名前・場所・メモで探す。
/// 結果は日付ごとにまとめ、近い日から。押すとその予定・タスクを開く
struct CalendarSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// 打っている間は少し待ってから探す（その間は行の形の仮の表示）
    @State private var settled = ""
    /// 最近探した言葉（5つまで。この端末だけ）
    @AppStorage("calendar.recentSearches") private var recentRaw = ""
    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

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
                if query != settled && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section { ForEach(0..<4, id: \.self) { _ in SkeletonRow() } }
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty && !recent.isEmpty {
                    Section("最近の検索") {
                        ForEach(recent, id: \.self) { w in
                            Button { query = w } label: { Label(w, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary) }
                                .swipeActions { Button("消す", systemImage: "xmark", role: .destructive) { recentRaw = recent.filter { $0 != w }.joined(separator: "\n") } }
                        }
                    }
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
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
                                Button {
                                    // 開いた検索の言葉を「最近の検索」に残す
                                    let w = query.trimmingCharacters(in: .whitespaces)
                                    recentRaw = ([w] + recent.filter { $0 != w }).prefix(5).joined(separator: "\n")
                                    dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { router.open(h.route) }
                                } label: {
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
                                .appearIn(rise: 6)
                                // 左右になぞって、その場で片づける（予定は取り消し、タスクは完了）
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    if h.task, let t = model.tasks.first(where: { "t" + $0.id == h.id }), !t.isDone {
                                        Button { model.perform("完了しました", undo: { try model.repo.taskAction(t.id, .undoFinish) }) { try model.repo.taskAction(t.id, t.kind == .check ? .finish : .finish) } } label: {
                                            Label("完了", systemImage: "checkmark")
                                        }.tint(.green)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    if !h.task, case .event(let oid) = h.route, let p = parseOccurrenceId(oid) {
                                        Button {
                                            model.perform("予定を取り消しました") { try model.repo.setStruck(eventId: p.masterId, originalStart: p.originalStart, struck: true) }
                                        } label: { Label("取り消す", systemImage: "strikethrough") }.tint(.gray)
                                    } else if !h.task, case .event(let oid) = h.route {
                                        Button {
                                            model.perform("予定を取り消しました") { try model.repo.setStruck(eventId: oid, originalStart: nil, struck: true) }
                                        } label: { Label("取り消す", systemImage: "strikethrough") }.tint(.gray)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "予定・タスク")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { settled = query }
            }
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }

    private func results() -> [Hit] {
        let words = TasksScreen.normalize(settled).split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
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
