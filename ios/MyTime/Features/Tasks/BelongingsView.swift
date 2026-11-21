import SwiftUI
import MyTimeCore

/// 持ち物のまとまり（いつもの持ち物・予定の「持ち物」・持ち物チェックのタスク）
struct BelongingGroup: Identifiable {
    enum Source { case everyday(day: String), event(occurrenceId: String, masterId: String, key: String), task(String) }
    var id: String
    var title: String
    var when: EpochMs?
    /// 出発の目安（予定に移動時間があるとき）
    var leaveAt: EpochMs?
    var place: String?
    var source: Source
    var items: [(name: String, done: Bool)]
    var done: Int { items.filter(\.done).count }
    var left: Int { items.count - done }
    var symbol: String {
        switch source {
        case .everyday: return "house.fill"
        case .event: return "calendar"
        case .task: return "checklist"
        }
    }
}

@MainActor
enum BelongingsList {
    /// 予定の持ち物の名前（予定の「持ち物」。以前の種類の項目の持ち物・荷物も読む）
    static func eventItems(_ e: MTEvent) -> [String] {
        let d = e.extra?["spec"]?["details"]
        let raw = (e.extra?["bring"]?.arrayValue ?? []) + (d?["bring"]?.arrayValue ?? []) + (d?["packing"]?.arrayValue ?? [])
        var seen = Set<String>()
        return raw.compactMap { $0.stringValue ?? $0["title"]?.stringValue ?? $0["text"]?.stringValue ?? $0["name"]?.stringValue }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 繰り返しの予定は回ごとに確認の印を分ける
    static func key(_ o: EventOccurrence) -> String { o.originalStart.map(String.init) ?? "one" }

    static func checked(_ e: MTEvent, key: String) -> Set<String> {
        Set((e.extra?["bringChecked"]?[key]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    static func everyday(model: AppModel) -> [String] { model.everydayBring.enabled ? model.everydayBring.items : [] }

    /// いつもの持ち物（今日）・今日と明日の予定の持ち物・終わっていない持ち物チェックのタスク
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
            out.append(BelongingGroup(id: "e:\(o.id)", title: o.title, when: o.start,
                                      leaveAt: o.event.travelMinutes.map { o.start - EpochMs($0) * MINUTE },
                                      place: o.event.placeName,
                                      source: .event(occurrenceId: o.id, masterId: o.masterId, key: k),
                                      items: names.map { ($0, c.contains($0)) }))
        }
        for task in model.tasks where task.specType == .belongings && !task.isDone {
            let arr = task.extra?["spec"]?["details"]?["items"]?.arrayValue ?? []
            let items = arr.compactMap { v -> (String, Bool)? in
                guard let n = v["name"]?.stringValue, !n.isEmpty else { return nil }
                return (n, v["done"]?.boolValue == true)
            }
            out.append(BelongingGroup(id: "t:\(task.id)", title: task.title, when: task.plannedStart ?? task.deadline, leaveAt: nil,
                                      place: task.extra?["spec"]?["details"]?["destination"]?.stringValue, source: .task(task.id), items: items))
        }
        out.sort { ($0.when ?? .max) < ($1.when ?? .max) }
        let ev = everyday(model: model)
        if !ev.isEmpty {
            let day = model.dayKey(now)
            let c = Set(model.everydayBring.checked[day] ?? [])
            out.insert(BelongingGroup(id: "d:\(day)", title: "いつもの持ち物", when: nil, leaveAt: nil, place: nil, source: .everyday(day: day),
                                      items: ev.map { ($0, c.contains($0)) }), at: 0)
        }
        return out
    }

    /// 予定とタスクの持ち物で、まだ確認していない数（いつもの持ち物は、予定がある日だけ数える）
    static func leftCount(model: AppModel) -> (left: Int, groups: Int) {
        let gs = items(model: model)
        let hasPlans = gs.contains { if case .everyday = $0.source { return false } else { return true } }
        let counted = gs.filter { if case .everyday = $0.source { return hasPlans } else { return true } }
        return (counted.reduce(0) { $0 + $1.left }, counted.count)
    }

    /// よく使う持ち物（予定の持ち物から、多い順）
    static func frequent(model: AppModel) -> [String] {
        var count: [String: Int] = [:]
        for e in model.events { for n in eventItems(e) { count[n, default: 0] += 1 } }
        return count.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(12).map(\.key)
    }

    /// 確認を切り替える（names の物を on / off にそろえる）
    static func set(model: AppModel, group g: BelongingGroup, names: [String], on: Bool) {
        switch g.source {
        case .everyday(let day):
            var b = model.everydayBring
            var c = Set(b.checked[day] ?? [])
            for n in names { if on { c.insert(n) } else { c.remove(n) } }
            b.checked[day] = c.sorted()
            model.saveEverydayBring(b)
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

    /// 予定に持ち物を1つ足す（持ち物の画面から）
    static func add(model: AppModel, group g: BelongingGroup, name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        switch g.source {
        case .everyday:
            var b = model.everydayBring
            if !b.items.contains(n) { b.items.append(n); model.saveEverydayBring(b) }
        case .event(_, let masterId, _):
            guard var e = model.events.first(where: { $0.id == masterId }) else { return }
            let before = e
            var o = e.extra?.objectValue ?? [:]
            let cur = eventItems(e)
            guard !cur.contains(n) else { return }
            o["bring"] = .array((cur + [n]).map { .string($0) })
            e.extra = .object(o)
            model.perform(nil, undo: { try model.repo.saveEvent(before, isNew: false) }) { try model.repo.saveEvent(e, isNew: false) }
        case .task(let id):
            guard var task = model.tasks.first(where: { $0.id == id }) else { return }
            let before = task
            var d = task.extra?["spec"]?["details"]?.objectValue ?? [:]
            var arr = d["items"]?.arrayValue ?? []
            guard !arr.contains(where: { $0["name"]?.stringValue == n }) else { return }
            arr.append(.object(["id": .string(n), "name": .string(n), "done": .bool(false)]))
            d["items"] = .array(arr)
            task.extra = withSpecDetails(task.extra, d, type: .belongings)
            model.perform(nil, undo: { try model.repo.saveTask(before, isNew: false) }) { try model.repo.saveTask(task, isNew: false) }
        }
    }
}

/// 持ち物の画面：いつもの持ち物と、今日・明日の予定・リストの持ち物を確かめる。
/// 押す・右へなぞる（確認）・左へなぞる（まだ）・下のバーをスライド（まとめて確認）のどれでも記録できる
struct BelongingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var tick = 0
    @State private var onlyLeft = false
    @State private var editingEveryday = false
    @State private var adding: String?
    @State private var draft = ""

    var body: some View {
        let groups = BelongingsList.items(model: model)
        List {
            ForEach(groups) { g in
                Section {
                    ForEach(g.items.filter { !onlyLeft || !$0.done }, id: \.name) { it in itemRow(g, it) }
                    if adding == g.id {
                        HStack {
                            TextField("持ち物を追加", text: $draft).submitLabel(.done).onSubmit { commitAdd(g) }
                            Button("追加") { commitAdd(g) }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if g.left > 0 && g.items.count > 1 {
                        SlideToConfirm(title: "スライドして\(g.left)個まとめて確認", symbol: "bag.fill", tint: .brown, doneText: "そろいました") {
                            BelongingsList.set(model: model, group: g, names: g.items.map(\.name), on: true); tick += 1
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    } else if g.left == 0 && !g.items.isEmpty {
                        HStack {
                            Label("すべてそろいました", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
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
                } header: { header(g) }
            }
            if groups.allSatisfy({ if case .everyday = $0.source { return true } else { return false } }) && groups.count <= 1 {
                Section {
                    Label("今日・明日の予定に持ち物はありません", systemImage: "bag").foregroundStyle(.secondary)
                } footer: { Text("予定の編集の「基本」にある「持ち物」に入れると、ここに出ます。") }
            }
            Section {
                Button("新しい持ち物リスト", systemImage: "plus.circle.fill") { router.open(.editor(EditorSeed(kind: .task, spec: .belongings))) }
                Button("いつもの持ち物を編集", systemImage: "house") { editingEveryday = true }
            } footer: {
                Text("右へなぞると確認、左へなぞると戻ります。")
            }
        }
        .navigationTitle("持ち物")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $onlyLeft.animation(Motion.pop)) { Label("まだの物だけ", systemImage: onlyLeft ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                    .toggleStyle(.button)
            }
        }
        .sheet(isPresented: $editingEveryday) { EverydayBringEditor().environment(model) }
        .sensoryFeedback(.selection, trigger: tick)
        .animation(Motion.pop, value: groups.map(\.done))
    }

    private func itemRow(_ g: BelongingGroup, _ it: (name: String, done: Bool)) -> some View {
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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !it.done {
                Button("確認", systemImage: "checkmark") { BelongingsList.set(model: model, group: g, names: [it.name], on: true); tick += 1 }.tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if it.done {
                Button("まだ", systemImage: "arrow.uturn.backward") { BelongingsList.set(model: model, group: g, names: [it.name], on: false); tick += 1 }.tint(.orange)
            }
        }
        .accessibilityLabel(it.name)
        .accessibilityValue(it.done ? "確認済み" : "まだ")
    }

    private func header(_ g: BelongingGroup) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.brown.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: g.items.isEmpty ? 0 : Double(g.done) / Double(g.items.count))
                    .stroke(g.left == 0 ? Color.green : Color.brown, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: g.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                let sub = [g.when.map(whenText), g.leaveAt.map { "\(model.hm($0))に出発" }, g.place].compactMap { $0 }.filter { !$0.isEmpty }
                if !sub.isEmpty { Text(sub.joined(separator: "・")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text("\(g.done)/\(g.items.count)").font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(g.left == 0 ? .green : .secondary)
                .contentTransition(.numericText())
            Button { draft = ""; withAnimation { adding = adding == g.id ? nil : g.id } } label: { Image(systemName: "plus.circle") }
                .accessibilityLabel("\(g.title)に持ち物を追加")
        }
        .textCase(nil)
    }

    private func commitAdd(_ g: BelongingGroup) {
        BelongingsList.add(model: model, group: g, name: draft)
        draft = ""
    }

    private func whenText(_ w: EpochMs) -> String {
        let t = model.time
        let d = t.isSameDay(w, model.now) ? "今日" : t.isSameDay(w, t.addDays(model.now, 1)) ? "明日" : t.dayLabel(w)
        return "\(d) \(model.hm(w))"
    }
}

/// いつもの持ち物の編集（並べ替え・削除・候補から追加）
struct EverydayBringEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var b = EverydayBring()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("いつもの持ち物を確かめる", isOn: $b.enabled)
                } footer: { Text("予定がある日は、持ち物の数にいつもの持ち物も含めます。") }
                Section {
                    BelongingsEditor(items: $b.items, spec: nil)
                } header: { Text("持ち物") }
                if !b.items.isEmpty {
                    Section("並び順（なぞって並べ替え）") {
                        ForEach(b.items, id: \.self) { Text($0) }
                            .onMove { b.items.move(fromOffsets: $0, toOffset: $1) }
                            .onDelete { b.items.remove(atOffsets: $0) }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("いつもの持ち物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { model.saveEverydayBring(b); dismiss() }.fontWeight(.semibold) }
            }
            .onAppear { if !loaded { b = model.everydayBring; loaded = true } }
        }
    }
}

/// 持ち物の入力：入れた物は丸い札で並べ、×で外す。種類に合わせた候補・前に使った物・いつもの物を押すだけで足せる
struct BelongingsEditor: View {
    @Binding var items: [String]
    var spec: SpecTypeId?
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var added = 0
    @FocusState private var focused: Bool

    var body: some View {
        if !items.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { n in
                    Button { withAnimation(Motion.pop) { items.removeAll { $0 == n } } } label: {
                        HStack(spacing: 4) {
                            Text(n)
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.brown.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(n)、外す")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
        }
        HStack(spacing: 12) {
            RowIcon(symbol: "bag.fill", tint: .brown)
            TextField("持ち物を入力（「、」で続けて入れられます）", text: $draft)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(addDraft)
                .onChange(of: draft) { _, v in if v.hasSuffix("、") || v.hasSuffix(",") { addDraft() } }
            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("追加", action: addDraft).font(.subheadline.weight(.semibold))
            }
        }
        // 候補は、入力中か、まだ何も入れていないときだけ（入れ終わった後は出さない）
        let cands = candidates
        if !cands.isEmpty && (focused || items.isEmpty) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cands, id: \.self) { n in
                        Button { add([n]) } label: {
                            Label(n, systemImage: "plus").font(.subheadline)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().strokeBorder(Color(.separator), lineWidth: 0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("持ち物に足します")
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
            .sensoryFeedback(.selection, trigger: added)
        }
    }

    /// 候補：入力中の文字に合う物 → 種類の定番 → よく使う物 → いつもの物（入れた物は除く）
    private var candidates: [String] {
        let q = draft.trimmingCharacters(in: .whitespaces)
        var seen = Set(items), out: [String] = []
        let pool = BelongingSuggest.forSpec(spec) + BelongingsList.frequent(model: model) + BelongingSuggest.everyday
        for n in pool where !seen.contains(n) && (q.isEmpty || n.localizedCaseInsensitiveContains(q)) {
            seen.insert(n); out.append(n)
            if out.count >= 10 { break }
        }
        return out
    }

    private func addDraft() {
        add(BelongingSuggest.split(draft))
        draft = ""
        focused = true
    }

    private func add(_ names: [String]) {
        let new = names.filter { !items.contains($0) }
        guard !new.isEmpty else { return }
        withAnimation(Motion.pop) { items += new }
        added += 1
    }
}

/// 予定の持ち物の確認（予定の詳細の「持ち物」の行から開く）
struct EventBelongingsScreen: View {
    var occurrenceId: String
    var masterId: String
    var key: String
    var start: EpochMs
    @Environment(AppModel.self) private var model
    @State private var tick = 0

    var body: some View {
        let ev = model.events.first { $0.id == masterId }
        let effective = ev?.applyingOccurrence(ev?.exceptions.first { exception in
            occurrenceId == "\(masterId)@\(exception.originalStart)"
        })
        let names = effective.map(BelongingsList.eventItems) ?? []
        let checked = ev.map { BelongingsList.checked($0, key: key) } ?? []
        let g = BelongingGroup(id: "e:\(occurrenceId)", title: effective?.title ?? "", when: start, source: .event(occurrenceId: occurrenceId, masterId: masterId, key: key),
                               items: names.map { ($0, checked.contains($0)) })
        List {
            Section {
                ForEach(names, id: \.self) { n in
                    let on = checked.contains(n)
                    Button { BelongingsList.set(model: model, group: g, names: [n], on: !on); tick += 1 } label: {
                        HStack(spacing: 12) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(on ? Color.green : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                            Text(n).strikethrough(on).foregroundStyle(on ? .secondary : .primary)
                            Spacer()
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if !on { Button("確認", systemImage: "checkmark") { BelongingsList.set(model: model, group: g, names: [n], on: true); tick += 1 }.tint(.green) }
                    }
                }
                if g.left > 0 && names.count > 1 {
                    SlideToConfirm(title: "スライドして\(g.left)個まとめて確認", symbol: "bag.fill", tint: .brown, doneText: "そろいました") {
                        BelongingsList.set(model: model, group: g, names: names, on: true); tick += 1
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            } header: {
                Text("\(g.done)/\(names.count)").monospacedDigit()
            }
        }
        .navigationTitle("持ち物")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: tick)
    }
}
