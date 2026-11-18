import SwiftUI
import MyTimeCore

/// 持ち物のまとまり（予定の「持ち物」か、持ち物チェックのタスク）
struct BelongingGroup: Identifiable {
    enum Source { case event(occurrenceId: String, masterId: String, key: String), task(String) }
    var id: String
    var title: String
    var when: EpochMs?
    var source: Source
    var items: [(name: String, done: Bool)]
    var done: Int { items.filter(\.done).count }
}

@MainActor
enum BelongingsList {
    /// 予定の持ち物の名前（予定の「持ち物」と、種類の項目の持ち物・荷物）
    static func eventItems(_ e: MTEvent) -> [String] {
        let d = e.extra?["spec"]?["details"]
        let raw = (d?["bring"]?.arrayValue ?? []) + (d?["packing"]?.arrayValue ?? []) + (e.extra?["bring"]?.arrayValue ?? [])
        var seen = Set<String>()
        return raw.compactMap { $0.stringValue ?? $0["title"]?.stringValue ?? $0["text"]?.stringValue ?? $0["name"]?.stringValue }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 繰り返しの予定は回ごとに確認の印を分ける
    static func key(_ o: EventOccurrence) -> String { o.originalStart.map(String.init) ?? "one" }

    static func checked(_ e: MTEvent, key: String) -> Set<String> {
        Set((e.extra?["bringChecked"]?[key]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// 今日・明日の予定の持ち物と、終わっていない持ち物チェックのタスク
    static func items(model: AppModel) -> [BelongingGroup] {
        let t = model.time
        let now = model.now
        let to = t.addDays(t.startOfDay(now), 2)
        var out: [BelongingGroup] = []
        for o in model.visibleEvents(from: now - HOUR, to: to) where o.end > now {
            let names = eventItems(o.event)
            guard !names.isEmpty else { continue }
            let k = key(o)
            let c = checked(o.event, key: k)
            out.append(BelongingGroup(id: "e:\(o.id)", title: o.title, when: o.start, source: .event(occurrenceId: o.id, masterId: o.masterId, key: k),
                                      items: names.map { ($0, c.contains($0)) }))
        }
        for task in model.tasks where task.specType == .belongings && !task.isDone {
            let arr = task.extra?["spec"]?["details"]?["items"]?.arrayValue ?? []
            let items = arr.compactMap { v -> (String, Bool)? in
                guard let n = v["name"]?.stringValue, !n.isEmpty else { return nil }
                return (n, v["done"]?.boolValue == true)
            }
            out.append(BelongingGroup(id: "t:\(task.id)", title: task.title, when: task.plannedStart ?? task.deadline, source: .task(task.id), items: items))
        }
        return out.sorted { ($0.when ?? .max) < ($1.when ?? .max) }
    }

    /// 1つの持ち物の確認を切り替える（names が空ならすべてを on にそろえる）
    static func set(model: AppModel, group g: BelongingGroup, names: [String], on: Bool) {
        switch g.source {
        case .event(_, let masterId, let key):
            guard var e = model.events.first(where: { $0.id == masterId }) else { return }
            let before = e
            var c = checked(e, key: key)
            for n in names { if on { c.insert(n) } else { c.remove(n) } }
            var o = e.extra?.objectValue ?? [:]
            var m = o["bringChecked"]?.objectValue ?? [:]
            m[key] = .array(c.sorted().map { .string($0) })
            o["bringChecked"] = .object(m)
            e.extra = .object(o)
            model.perform(nil, undo: { try model.repo.saveEvent(before, isNew: false) }) { try model.repo.saveEvent(e, isNew: false) }
        case .task(let id):
            guard var task = model.tasks.first(where: { $0.id == id }) else { return }
            let before = task
            var d = task.extra?["spec"]?["details"]?.objectValue ?? [:]
            let arr = (d["items"]?.arrayValue ?? []).map { v -> JSONValue in
                guard let n = v["name"]?.stringValue, names.contains(n), var o = v.objectValue else { return v }
                o["done"] = .bool(on)
                return .object(o)
            }
            d["items"] = .array(arr)
            task.extra = withSpecDetails(task.extra, d, type: .belongings)
            model.perform(nil, undo: { try model.repo.saveTask(before, isNew: false) }) { try model.repo.saveTask(task, isNew: false) }
        }
    }
}

/// 持ち物の画面：今日・明日の予定とリストの持ち物を、押すだけで確認できる
struct BelongingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var tick = 0

    var body: some View {
        let groups = BelongingsList.items(model: model)
        List {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("持ち物はありません", systemImage: "bag")
                } description: {
                    Text("予定の「持ち物」に入れたものと、持ち物チェックのリストがここに出ます。")
                } actions: {
                    Button("持ち物リストを作る") { router.open(.editor(EditorSeed(kind: .task, spec: .belongings))) }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.items, id: \.name) { it in
                        Button {
                            BelongingsList.set(model: model, group: g, names: [it.name], on: !it.done)
                            tick += 1
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: it.done ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(it.done ? Color.green : Color.secondary)
                                    .contentTransition(.symbolEffect(.replace))
                                Text(it.name).strikethrough(it.done).foregroundStyle(it.done ? .secondary : .primary)
                                Spacer()
                            }
                            .frame(minHeight: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(it.name)
                        .accessibilityValue(it.done ? "確認済み" : "まだ")
                    }
                    if g.done < g.items.count {
                        Button("すべて確認した", systemImage: "checkmark.circle") {
                            BelongingsList.set(model: model, group: g, names: g.items.map(\.name), on: true); tick += 1
                        }
                    } else if !g.items.isEmpty {
                        HStack {
                            Label("すべて確認しました", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Spacer()
                            Button("やり直す") { BelongingsList.set(model: model, group: g, names: g.items.map(\.name), on: false) }
                                .font(.subheadline)
                        }
                        if case .task(let id) = g.source {
                            Button("このリストを完了にする", systemImage: "checkmark") {
                                model.perform("完了しました", undo: { try model.repo.taskAction(id, .undoFinish) }) { try model.repo.taskAction(id, .finish) }
                            }
                        }
                    }
                } header: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            if let w = g.when { Text(whenText(w)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text("\(g.done)/\(g.items.count)").font(.caption.weight(.bold)).monospacedDigit()
                            .foregroundStyle(g.done == g.items.count ? .green : .secondary)
                            .contentTransition(.numericText())
                    }
                    .textCase(nil)
                }
            }
            Section {
                Button("新しい持ち物リスト", systemImage: "plus.circle.fill") { router.open(.editor(EditorSeed(kind: .task, spec: .belongings))) }
            } footer: { Text("予定の持ち物は、予定の編集の「持ち物」に読点・カンマで区切って入れます。確認の印は回ごとに残ります。") }
        }
        .navigationTitle("持ち物")
        .sensoryFeedback(.selection, trigger: tick)
        .animation(Motion.pop, value: groups.map(\.done))
    }

    private func whenText(_ w: EpochMs) -> String {
        let t = model.time
        let d = t.isSameDay(w, model.now) ? "今日" : t.isSameDay(w, t.addDays(model.now, 1)) ? "明日" : t.dayLabel(w)
        return "\(d) \(model.hm(w))"
    }
}
