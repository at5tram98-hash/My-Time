import SwiftUI
import MyTimeCore

/// 文章で追加（Web 版 quickadd と同じ規則。端末内で解釈し、外部には送らない）。
/// 読み取った候補を一画面で確認し、選んだものだけを保存する。検索・ずらす・移す・再計画も同じ入力欄から。
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: ParseResult?
    @State private var selected: Set<String> = []
    @State private var proposal: Proposal?
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    private let examples = ["明日は課題2つと買い物", "土曜日はGU 18:30〜22:00、時給1,300円", "金曜までにレポート 2時間ぐらい", "夕方に買い物", "来週のバイト", "今日の課題を移して"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("例：明日18時から勤務、金曜までに課題 2時間", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(read)
                    Button(action: read) { Label("読み取る", systemImage: "text.viewfinder") }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("文章は端末の中だけで読み取ります。保存する前に、ここで内容を確認できます。")
                }
                if let result { resultSections(result) } else { exampleSection }
            }
            .navigationTitle("文章で追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                if case .create(let cs, _)? = result, !cs.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("\(selected.count)件を追加", action: saveCandidates).fontWeight(.semibold).disabled(selected.isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
    }

    private var exampleSection: some View {
        Section("書き方の例") {
            ForEach(examples, id: \.self) { ex in
                Button { text = ex; read() } label: { Label(ex, systemImage: "text.quote") }
            }
        }
    }

    // MARK: 結果

    @ViewBuilder
    private func resultSections(_ r: ParseResult) -> some View {
        switch r {
        case .create(let cs, let notes):
            if cs.isEmpty {
                Section { ForEach(notes, id: \.self) { Text($0).foregroundStyle(.secondary) } }
            } else {
                Section {
                    ForEach(cs) { c in CandidateRow(candidate: c, selected: selected.contains(c.id)) { toggle(c.id) } }
                } header: { Text("読み取った内容（\(cs.count)件）") } footer: { Text("時刻に「候補」と付いたものは推定です。保存した後でも変更できます。") }
            }
        case .search(let q):
            Section("「\(q.label)」の検索結果") {
                if hits.isEmpty { Text("見つかりませんでした").foregroundStyle(.secondary) }
                ForEach(hits) { h in
                    Button { open(h) } label: {
                        HStack {
                            Image(systemName: h.entity == .event ? "calendar" : "checklist").foregroundStyle(.secondary)
                            Text(h.title).foregroundStyle(.primary)
                            Spacer()
                            if let at = h.at { Text(model.time.dayLabel(at) + " " + model.hm(at)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }
                }
            }
        case .shift, .move, .replan:
            if let proposal { ProposalSection(proposal: proposal) { apply($0) } }
            else { Section { Text("対象が見つかりませんでした。日付や名前を足してもう一度お試しください。").foregroundStyle(.secondary) } }
        }
    }

    // MARK: 操作

    private func context() -> ParseContext {
        let now = model.now
        return ParseContext(now: now, events: model.visibleEvents(from: model.time.addDays(now, -1), to: model.time.addDays(now, 30)), tasks: model.tasks, subtasks: model.subtasks,
                            employers: model.employers, opts: model.planOptions, time: model.time)
    }

    private func read() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        focused = false
        let ctx = context()
        let r = parseInput(t, ctx: ctx)
        proposal = nil; hits = []
        switch r {
        case .create(let cs, _):
            selected = Set(cs.map(\.id))
        case .search(let q):
            hits = searchItems(q, events: model.visibleEvents(from: q.from ?? model.time.addDays(ctx.now, -30), to: q.to ?? model.time.addDays(ctx.now, 60)), tasks: model.tasks)
        case .shift(let q, let delta):
            let evs = model.visibleEvents(from: q.from ?? model.time.startOfDay(ctx.now), to: q.to ?? model.time.addDays(ctx.now, 14))
            if let h = searchItems(q, events: evs, tasks: model.tasks).first(where: { $0.at != nil }) {
                let busy = busyItems(events: evs, tasks: model.tasks, subtasks: model.subtasks)
                if h.entity == .task, let t = model.tasks.first(where: { $0.id == h.id }), let s = t.plannedStart, let e = t.plannedEnd {
                    proposal = shiftProposal(entity: .task, id: t.id, title: t.title, start: s, end: e, deltaMin: delta, tasks: model.tasks, busy: busy)
                } else if h.entity == .event, let o = evs.first(where: { $0.id == h.id }), o.originalStart == nil {
                    proposal = shiftProposal(entity: .event, id: o.id, title: o.title, start: o.start, end: o.end, deltaMin: delta, tasks: model.tasks, busy: busy)
                }
            }
        case .move(let q, let toDay):
            let evs = model.visibleEvents(from: q.from ?? model.time.startOfDay(ctx.now), to: q.to ?? model.time.addDays(ctx.now, 14))
            let targets = searchItems(q, events: [], tasks: model.tasks).compactMap { h in model.tasks.first { $0.id == h.id && !$0.isDone && $0.kind == .do } }
            if !targets.isEmpty {
                var busy = busyItems(events: model.visibleEvents(from: toDay, to: model.time.addDays(toDay, 1)), tasks: model.tasks.filter { t in !targets.contains { $0.id == t.id } }).slots
                var changes: [PlanChange] = []
                for t in targets {
                    let minutes = t.plannedStart.flatMap { s in t.plannedEnd.map { Int(($0 - s) / MINUTE) } } ?? t.estimateMinutes ?? 30
                    if let slot = findSlots(minutes: minutes, busy: busy, from: max(ctx.now, toDay), until: model.time.addDays(toDay, 1), opts: model.planOptions, time: model.time).first {
                        busy.append(slot)
                        changes.append(PlanChange(entity: .task, id: t.id, title: t.title, before: (t.plannedStart, t.plannedEnd), after: (slot.start, slot.end)))
                    }
                }
                _ = evs
                if !changes.isEmpty { proposal = Proposal(id: "move:\(toDay)", title: "\(model.time.dayLabel(toDay))の空き時間へ移す", reason: "予定を避けて、その日の空いている時間に置きます", changes: changes) }
            }
        case .replan(let day, let spec):
            let evs = model.visibleEvents(from: model.time.addDays(day, -1), to: model.time.addDays(day, 2))
            let p = replanDay(day, events: evs, tasks: model.tasks, subtasks: model.subtasks, now: ctx.now, filter: spec.map { s in { $0.specType == s } }, opts: model.planOptions, time: model.time)
            proposal = p
        }
        withAnimation { result = r }
    }

    private func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }

    private func saveCandidates() {
        guard case .create(let cs, _)? = result else { return }
        let chosen = cs.filter { selected.contains($0.id) }
        var made = 0
        if model.perform(nil, { made = try model.repo.createFromCandidates(chosen) }) {
            dismiss()
        }
    }

    private func apply(_ p: Proposal) {
        if model.perform("変更しました", { try model.repo.applyProposal(p) }) { dismiss() }
    }

    private func open(_ h: SearchHit) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            router.open(h.entity == .event ? .event(h.id) : .task(h.id))
        }
    }
}

/// 候補1件（選択・種類・日時・根拠・準備・作業枠）
private struct CandidateRow: View {
    @Environment(AppModel.self) private var model
    let candidate: Candidate
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        let c = candidate
        let def = c.spec.flatMap { SPEC_BY_ID[$0] }
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: def?.symbol ?? (c.entity == .event ? "calendar" : "checklist")).foregroundStyle(def?.tint ?? .secondary)
                        Text(c.title).font(.headline).foregroundStyle(.primary)
                        Text(c.entity == .event ? "予定" : "タスク").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(.tertiarySystemFill))).foregroundStyle(.secondary)
                    }
                    Text(whenText(c)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    ForEach(c.reasons, id: \.self) { r in
                        Label(r, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    }
                    if !c.prep.isEmpty {
                        Text("準備：" + c.prep.map { "\($0.title) \(model.hm($0.start))" }.joined(separator: "・")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !c.sessions.isEmpty {
                        Text("作業枠：" + c.sessions.map { "\($0.title) \(md($0.start))" }.joined(separator: "・")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func md(_ t: EpochMs) -> String { model.time.dayLabel(t) + " " + model.hm(t) }

    private func whenText(_ c: Candidate) -> String {
        var parts: [String] = []
        if c.allDay, let s = c.start { parts.append("\(model.time.dayLabel(s))・終日") }
        else if let s = c.start, let e = c.end { parts.append("\(model.time.dayLabel(s)) \(model.hm(s))〜\(model.hm(e))" + (c.timeCertain ? "" : "（候補）")) }
        else { parts.append("時刻を決めない（未割当）") }
        if let d = c.due { parts.append("締切 \(model.time.dayLabel(d)) \(model.hm(d))") }
        if let m = c.estimateMinutes { parts.append("見積 \(m)分") }
        if let w = c.details["hourlyWage"]?.doubleValue, let s = c.start, let e = c.end, let pay = shiftPay(start: s, end: e, hourlyWage: w, breakMinutes: Int(c.details["breakMinutes"]?.doubleValue ?? 0)) {
            parts.append("給与見込み \(yen(pay.pay))（税引前）")
        }
        return parts.joined(separator: "・")
    }
}

/// 提案（変更前→変更後）と承認ボタン。別案があれば並べる
struct ProposalSection: View {
    @Environment(AppModel.self) private var model
    let proposal: Proposal
    let apply: (Proposal) -> Void

    var body: some View {
        ForEach([proposal] + proposal.alternatives) { p in
            Section {
                ForEach(p.changes) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            Text(range(c.before.start, c.before.end)).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.tertiary)
                            Text(range(c.after.start, c.after.end)).foregroundStyle(Color.accentColor)
                        }
                        .font(.caption).monospacedDigit()
                    }
                }
                ForEach(p.sessions, id: \.start) { s in
                    Label("\(s.title) \(range(s.start, s.end))", systemImage: "plus.circle").font(.caption).monospacedDigit()
                }
                ForEach(p.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                if !p.changes.isEmpty || !p.sessions.isEmpty {
                    Button { apply(p) } label: { Label("この内容で変更する", systemImage: "checkmark") }
                }
            } header: {
                Text(p.title)
            } footer: {
                Text(p.reason)
            }
        }
    }

    private func range(_ s: EpochMs?, _ e: EpochMs?) -> String {
        guard let s, let e else { return "未割当" }
        return "\(model.time.dayLabel(s)) \(model.hm(s))〜\(model.hm(e))"
    }
}
