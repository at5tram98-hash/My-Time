import SwiftUI
import MyTimeCore

/// 種類ごとの表示（予定・タスクの詳細の上に出す）。
/// 種類によって「いちばん大事な数字」を大きく出し、その下に必要な項目だけを並べる。
/// チェックリストはその場で押して記録できる。試験系は学習計画のカードを出す。
struct SpecPanel: View {
    var spec: SpecTypeId
    var details: [String: JSONValue]
    /// 予定のとき（時間と勤務先）
    var start: EpochMs?
    var end: EpochMs?
    var employerName: String?
    /// 試験系のとき：元のタスク（学習計画を作る）
    var task: MTTask?
    var onUpdate: ([String: JSONValue]) -> Void

    @Environment(AppModel.self) private var model

    private var def: SpecDef { SPEC_BY_ID[spec]! }
    private var tint: Color { def.tint }

    var body: some View {
        Section {
            hero
            ForEach(def.fields.filter { !heroKeys.contains($0.key) }, id: \.key) { f in fieldRow(f) }
        } header: {
            Label(def.name, systemImage: def.symbol).foregroundStyle(tint).textCase(nil)
        }
        if spec.isExamLike, let task {
            StudyPlanSection(task: task, examAt: examDate, topics: topics, dailyMinutes: dailyMinutes, tint: tint)
        }
    }

    // MARK: 大きく出す部分（種類ごと）

    /// 大きく出した項目は、下の一覧に重ねて出さない
    private var heroKeys: Set<String> {
        switch spec {
        case .class: return ["room", "quizAt", "quizScope"]
        case .shift: return ["hourlyWage", "breakMinutes"]
        case .exam: return ["examAt", "goal"]
        case .language: return ["mockDate", "targetScore"]
        case .certification: return ["examDate"]
        case .assignment, .report: return ["dueAt"]
        case .payday: return ["actualAmount", "received"]
        default: return []
        }
    }

    @ViewBuilder
    private var hero: some View {
        switch spec {
        case .class:
            HStack(alignment: .firstTextBaseline) {
                metric("教室", str("room").map(compactRoom) ?? "未設定", symbol: "door.left.hand.open")
                Spacer()
                if let p = str("period") { metric("時限", p, symbol: "number") }
            }
            if let q = date("quizAt") {
                quizBanner(q, scope: str("quizScope"))
            }
        case .shift:
            let wage = details["hourlyWage"]?.doubleValue
            let brk = Int(details["breakMinutes"]?.intValue ?? 0)
            if let s = start, let e = end, let pay = shiftPay(start: s, end: e, hourlyWage: wage, breakMinutes: brk) {
                HStack(alignment: .firstTextBaseline) {
                    metric("見込みの給与", yen(pay.pay), symbol: "yensign.circle.fill", big: true)
                    Spacer()
                    metric("実働", "\(pay.workMinutes / 60)時間\(pay.workMinutes % 60 == 0 ? "" : "\(pay.workMinutes % 60)分")", symbol: "clock")
                }
            } else {
                hint("時給を入れると、給与の見込みを出します", symbol: "yensign.circle")
            }
            if let name = employerName ?? str("workplace") { LabeledContent("勤務先", value: name) }
            if brk > 0 { LabeledContent("休憩", value: "\(brk)分") }
        case .exam, .language, .certification:
            if let at = examDate {
                countdown(to: at, label: spec == .language ? "本番まで" : "試験まで")
            } else {
                hint("試験の日を入れると、残りの日数と学習計画を出します", symbol: "calendar.badge.exclamationmark")
            }
            // 試験の日はここでも変えられる（編集画面を開かなくてよい）
            DatePicker(selection: Binding(
                get: { model.time.date(examDate ?? model.time.addDays(model.time.startOfDay(model.now), 14) + 9 * HOUR) },
                set: { set(examKey, .number(Double(model.time.ms($0)))) }
            ), in: Date()..., displayedComponents: [.date, .hourAndMinute]) {
                Label(spec == .language ? "本番の日" : "試験の日", systemImage: "calendar")
            }
            if let g = str("goal") ?? details["targetScore"]?.doubleValue.map({ "\(Int($0))点" }) {
                LabeledContent("目標", value: g)
            }
        case .assignment, .report:
            if let d = date("dueAt") ?? task?.deadline {
                countdown(to: d, label: "提出まで")
            }
            if let u = str("submitUrl"), let url = URL(string: u) {
                Link(destination: url) { Label("提出先を開く", systemImage: "arrow.up.forward.app").font(.body.weight(.semibold)) }
            }
        case .cleaning:
            let book = model.cleaning
            NavigationLink { CleaningHomeView() } label: {
                Label(book.active != nil ? "清掃を続ける" : "清掃の場所を選んで始める", systemImage: "bubbles.and.sparkles.fill").font(.body.weight(.semibold))
            }
            if let n = book.neglected(now: model.now, time: model.time).first {
                hint("いちばん長く清掃していない：\(n.area.name)・\(n.item.name)", symbol: "exclamationmark.circle")
            }
        case .morning:
            NavigationLink { MorningHomeView() } label: {
                Label(model.morning.active != nil ? "朝の準備を続ける" : "朝の準備・アラーム", systemImage: "sunrise.fill").font(.body.weight(.semibold))
            }
            hint("工程 \(model.morning.enabledSteps.count)・見込み \(model.morning.estimate().minutes)分", symbol: "list.number")
        case .payday:
            HStack {
                metric("入金額", details["actualAmount"]?.doubleValue.map { yen(Int($0)) } ?? "未記録", symbol: "yensign.circle.fill", big: true)
                Spacer()
            }
            Toggle("入金を確認した", isOn: Binding(get: { details["received"]?.boolValue ?? false }, set: { set("received", .bool($0)) }))
                .tint(.green)
        default:
            EmptyView()
        }
    }

    // MARK: 項目

    @ViewBuilder
    private func fieldRow(_ f: SpecField) -> some View {
        let v = details[f.key]
        switch f.kind {
        case .checklist:
            let items = v?.arrayValue ?? []
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(f.label).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(items.filter { $0["done"]?.boolValue == true }.count)/\(items.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                        let done = it["done"]?.boolValue == true
                        Button {
                            var arr = items
                            var o = it.objectValue ?? [:]
                            o["done"] = .bool(!done)
                            arr[i] = .object(o)
                            set(f.key, .array(arr))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(done ? tint : .secondary)
                                Text(it["name"]?.stringValue ?? "").strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        case .list:
            let xs = (v?.arrayValue ?? []).compactMap(\.stringValue)
            if !xs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(f.label).font(.subheadline.weight(.semibold))
                    FlowChips(items: xs, tint: tint)
                }
                .padding(.vertical, 2)
            }
        case .toggle:
            Toggle(f.label, isOn: Binding(get: { v?.boolValue ?? false }, set: { set(f.key, .bool($0)) })).tint(tint)
        case .url:
            if let s = v?.stringValue, let u = URL(string: s) { Link(destination: u) { LabeledContent(f.label) { Text(u.host() ?? s).lineLimit(1) } } }
        case .money:
            if let n = v?.doubleValue { LabeledContent(f.label, value: yen(Int(n))) }
        case .minutes, .number:
            if let n = v?.doubleValue { LabeledContent(f.label, value: "\(Int(n))\(f.unit ?? "")") }
        case .date, .datetime:
            if let t = v?.intValue { LabeledContent(f.label, value: model.time.dayLabel(t) + (f.kind == .datetime ? " \(model.hm(t))" : "")) }
        case .text, .select, .multiline:
            if let s = v?.stringValue, !s.isEmpty {
                if f.kind == .multiline {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.label).font(.subheadline.weight(.semibold))
                        Text(s).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    LabeledContent(f.label, value: s)
                }
            }
        case .slots, .members, .steps:
            if let n = v?.arrayValue?.count, n > 0 { LabeledContent(f.label, value: "\(n)件") }
        }
    }

    // MARK: 部品

    private func metric(_ title: String, _ value: String, symbol: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(big ? .title.weight(.bold) : .title2.weight(.bold)).monospacedDigit().foregroundStyle(big ? tint : .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }

    private func countdown(to at: EpochMs, label: String) -> some View {
        let d0 = model.time.startOfDay(model.now)
        let days = Int((model.time.startOfDay(at) - d0) / DAY)
        let text = days > 1 ? "あと\(days)日" : days == 1 ? "明日" : days == 0 ? "今日" : "\(-days)日前に終了"
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.largeTitle.weight(.bold)).monospacedDigit().foregroundStyle(days <= 3 && days >= 0 ? .red : tint)
                    .contentTransition(.numericText())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.time.dayLabel(at)).font(.subheadline.weight(.semibold))
                Text(model.hm(at)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func quizBanner(_ at: EpochMs, scope: String?) -> some View {
        let days = Int((model.time.startOfDay(at) - model.time.startOfDay(model.now)) / DAY)
        return HStack(spacing: 10) {
            Image(systemName: "pencil.and.list.clipboard").font(.title3).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("小テスト・\(days > 0 ? "あと\(days)日" : days == 0 ? "今日" : "終了")").font(.subheadline.weight(.bold))
                Text("\(model.time.dayLabel(at))" + (scope.map { "・\($0)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func hint(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
    }

    private func str(_ k: String) -> String? { details[k]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    private func date(_ k: String) -> EpochMs? { details[k]?.intValue }

    private func set(_ k: String, _ v: JSONValue) {
        var d = details
        d[k] = v
        onUpdate(d)
    }

    // MARK: 試験系の値

    private var examDate: EpochMs? {
        date("examAt") ?? date("mockDate") ?? date("examDate") ?? task?.deadline ?? task?.plannedStart
    }

    private var examKey: String { spec == .language ? "mockDate" : spec == .certification ? "examDate" : "examAt" }

    private var dailyMinutes: Int { Int(details["dailyMinutes"]?.intValue ?? 60) }

    /// 学習する単元・分野・範囲（まだ終わっていないもの）
    private var topics: [String] {
        if spec == .certification {
            return (details["units"]?.arrayValue ?? []).filter { $0["done"]?.boolValue != true }.compactMap { $0["name"]?.stringValue }
        }
        if spec == .language {
            let xs = (details["areas"]?.arrayValue ?? []).compactMap(\.stringValue)
            return xs.isEmpty ? ["リスニング", "リーディング", "単語・文法"] : xs
        }
        let scope = str("scope") ?? ""
        return scope.split(whereSeparator: { "\n、,，・".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// 横に並ぶ小さな札（折り返す）
struct FlowChips: View {
    var items: [String]
    var tint: Color
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }
    @ViewBuilder private var chips: some View {
        ForEach(items, id: \.self) { x in
            Text(x).font(.caption.weight(.semibold)).foregroundStyle(tint)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.12)))
        }
    }
}

// MARK: 学習計画（試験系）

/// 試験の日から逆算して、毎日の学習をタスクとして置く。
/// 範囲・分野・単元を順番に回し、前日は「総復習」。空いている時間（夕方を優先）に入れる。
/// 作った学習は extra.studyFor = 元のタスク ID でつながり、作り直しでは未完了のものだけ置き換える。
struct StudyPlanSection: View {
    var task: MTTask
    var examAt: EpochMs?
    var topics: [String]
    var dailyMinutes: Int
    var tint: Color

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var minutes = 60
    @State private var confirmRedo = false
    @State private var made = 0

    private var sessions: [MTTask] {
        model.tasks.filter { $0.extra?["studyFor"]?.stringValue == task.id }.sorted { ($0.plannedStart ?? 0) < ($1.plannedStart ?? 0) }
    }

    var body: some View {
        let list = sessions
        let done = list.filter(\.isDone).count
        Section {
            if list.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("試験の日まで、毎日の学習を自動で置きます。範囲を順番に回し、前日は総復習にします。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    GlassSlider(value: $minutes, steps: Array(stride(from: 15, through: 240, by: 15)), label: { durationLabel($0) }, tint: .indigo, symbol: "timer", title: "1日の学習")
                    Button { generate() } label: {
                        Label("学習計画を作る", systemImage: "wand.and.stars").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.white)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(examAt == nil ? AnyShapeStyle(Color.gray.opacity(0.4)) : AnyShapeStyle(tint.gradient)))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(examAt == nil)
                    if examAt == nil { Text("上で試験の日を選ぶと作れます").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("進み具合").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("\(done)/\(list.count)回").font(.title2.weight(.bold)).monospacedDigit()
                    }
                    Spacer()
                    ProgressRing(value: list.isEmpty ? 0 : Double(done) / Double(list.count), ideal: nil, symbol: "book.fill", tint: tint, size: 46, done: done == list.count)
                }
                ForEach(list.filter { !$0.isDone }.prefix(5), id: \.id) { s in
                    Button { router.open(.task(s.id)) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.plannedStart.map { model.time.dayLabel($0) } ?? "").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                Text(s.plannedStart.map(model.hm) ?? "").font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                            .frame(width: 70, alignment: .leading)
                            Text(s.title.replacingOccurrences(of: "\(task.title)：", with: "")).foregroundStyle(.primary).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("作り直す", systemImage: "arrow.clockwise") { confirmRedo = true }
                    .font(.subheadline)
            }
        } header: {
            Label("学習計画", systemImage: "book.closed.fill").foregroundStyle(tint).textCase(nil)
        }
        .onAppear { minutes = dailyMinutes }
        .sensoryFeedback(.success, trigger: made)
        .alert("学習計画を作り直しますか？", isPresented: $confirmRedo) {
            Button("作り直す") { generate() }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("まだ終わっていない学習を、今日からの日程で置き直します。終わった学習は残ります。") }
    }

    private func generate() {
        guard let exam = examAt else { return }
        let tomorrow = model.time.addDays(model.time.startOfDay(model.now), 1)
        let examDay = model.time.startOfDay(exam)
        guard examDay > tomorrow - DAY else { model.errorMessage = "試験の日が過ぎています"; return }
        let old = sessions.filter { !$0.isDone }
        let len = EpochMs(minutes) * MINUTE
        let names = topics
        var plans: [(String, EpochMs)] = []
        var day = model.time.startOfDay(model.now)
        var i = 0
        var busy = model.visibleEvents(from: day, to: examDay).filter { !$0.event.allDay }.map { ($0.start, $0.end) }
        busy += model.tasks.filter { t in t.extra?["studyFor"]?.stringValue != task.id }.compactMap { t in t.plannedStart.flatMap { s in t.plannedEnd.map { (s, $0) } } }
        while day < examDay {
            let last = model.time.addDays(day, 1) == examDay
            let title = last ? "総復習" : names.isEmpty ? "学習\(i + 1)回目" : names[i % names.count]
            // 夕方（18時）から先に探し、なければ活動の始まりから
            let from = max(day + 18 * HOUR, model.now + 15 * MINUTE)
            let to = day + EpochMs(model.settings.suggestToHour) * HOUR
            var slot: EpochMs?
            for startFrom in [from, max(day + EpochMs(model.settings.suggestFromHour) * HOUR, model.now + 15 * MINUTE)] {
                var s = ((startFrom + 15 * MINUTE - 1) / (15 * MINUTE)) * 15 * MINUTE
                while s + len <= to {
                    if !busy.contains(where: { $0.0 < s + len && s < $0.1 }) { slot = s; break }
                    s += 15 * MINUTE
                }
                if slot != nil { break }
            }
            if let s = slot {
                plans.append((title, s))
                busy.append((s, s + len))
                if !last { i += 1 }
            }
            day = model.time.addDays(day, 1)
        }
        guard !plans.isEmpty else { model.errorMessage = "試験の日までに空いている時間がありません"; return }
        var created: [String] = []
        let ok = model.perform("学習計画を作りました（\(plans.count)回）", undo: {
            for id in created { try model.repo.deleteTask(id) }
            for t in old { try model.repo.saveTask(t, isNew: true) }
        }) {
            for t in old { try model.repo.deleteTask(t.id) }
            for (title, s) in plans {
                var t = MTTask.make(title: "\(task.title)：\(title)", now: model.now, id: model.repo.newId())
                t.plannedStart = s
                t.plannedEnd = s + len
                t.icon = "book"
                t.category = task.category
                t.extra = .object(["studyFor": .string(task.id), "color": task.extra?["color"] ?? .null])
                try model.repo.saveTask(t, isNew: true)
                created.append(t.id)
            }
        }
        if ok { made += 1 }
    }
}

/// extra.spec.details だけを置き換えた extra を返す（ほかの項目はそのまま）
func withSpecDetails(_ extra: JSONValue?, _ details: [String: JSONValue], type: SpecTypeId? = nil) -> JSONValue {
    var root = extra?.objectValue ?? [:]
    var spec = root["spec"]?.objectValue ?? [:]
    if spec["type"] == nil, let type { spec["type"] = .string(type.rawValue) }
    spec["details"] = .object(details)
    root["spec"] = .object(spec)
    return .object(root)
}
