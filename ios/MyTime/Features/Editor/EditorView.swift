import SwiftUI
import MyTimeCore

/// 予定・タスクの追加と編集。保存できない入力は理由を表示し、入力はそのまま残す
struct EditorView: View {
    var seed: EditorSeed
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var kind: EditorSeed.Kind = .task
    @State private var loaded = false
    @State private var isNew = true
    @State private var task = MTTask.make(title: "", now: 0)
    @State private var event = MTEvent.make(title: "", calendarId: "cal-general", start: 0, end: 0, now: 0)
    @State private var title = ""
    @State private var notes = ""
    @State private var spec: SpecTypeId?
    /// 種類ごとの専用の項目（extra.spec.details。締切 dueAt は別に扱う）
    @State private var details: [String: JSONValue] = [:]
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var hasTime = true
    @State private var allDay = false
    @State private var isCheck = false
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(86400)
    @State private var estimate = 30
    @State private var hasEstimate = false
    @State private var calendarId = "cal-general"
    @State private var repeatFreq: String = "none"
    @State private var place = ""
    @State private var flagged = false
    @State private var icon = "book"
    @State private var saved = 0
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    Picker("種類", selection: $kind) {
                        Text("タスク").tag(EditorSeed.Kind.task)
                        Text("予定").tag(EditorSeed.Kind.event)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField(kind == .event ? "予定の名前" : "やること", text: $title)
                        .font(.title3)
                        .focused($titleFocused)
                        .submitLabel(.done)
                    specMenu
                }
                if kind == .event { eventFields } else { taskFields }
                if let spec { SpecFieldsSection(spec: spec, details: $details) }
                Section("メモ") {
                    TextField("メモ", text: $notes, axis: .vertical).lineLimit(3...8)
                }
            }
            .navigationTitle(isNew ? (kind == .event ? "新しい予定" : "新しいタスク") : "編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "追加" : "保存", action: save).fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
            .onChange(of: start) { old, new in
                // 開始を動かしたら、長さを保って終了も動かす
                let len = end.timeIntervalSince(old)
                if len > 0 { end = new.addingTimeInterval(len) }
            }
            .sensoryFeedback(.success, trigger: saved)
        }
        .interactiveDismissDisabled(!title.isEmpty && isNew)
    }

    // MARK: 種類（S01〜S25）

    private var specMenu: some View {
        Menu {
            Button("指定しない") { spec = nil }
            ForEach(SpecGroup.allCases, id: \.self) { g in
                Section(g.label) {
                    ForEach(SPEC_DEFS.filter { $0.group == g }) { d in
                        Button { apply(d) } label: { Label(d.name, systemImage: d.symbol) }
                    }
                }
            }
        } label: {
            HStack {
                Text("種類").foregroundStyle(.primary)
                Spacer()
                if let d = spec.flatMap({ SPEC_BY_ID[$0] }) {
                    Label(d.name, systemImage: d.symbol).foregroundStyle(d.tint)
                } else {
                    Text("指定しない").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(.tertiary)
            }
        }
    }

    /// 種類を選ぶと、予定かタスクか・確認かどうかの既定を合わせる（新規のときだけ）
    private func apply(_ d: SpecDef) {
        spec = d.id
        guard isNew else { return }
        kind = d.isEvent ? .event : .task
        isCheck = d.isCheck
        if d.id == .assignment || d.id == .exam || d.id == .payment { hasDeadline = true }
        if d.isEvent, d.id == .shift || d.id == .class {
            calendarId = model.calendars.first { $0.kind == (d.id == .shift ? .job : .class) }?.id ?? calendarId
        }
    }

    // MARK: 予定

    @ViewBuilder
    private var eventFields: some View {
        Section {
            Toggle("終日", isOn: $allDay)
            DatePicker("開始", selection: $start, displayedComponents: allDay ? .date : [.date, .hourAndMinute])
            DatePicker("終了", selection: $end, in: start..., displayedComponents: allDay ? .date : [.date, .hourAndMinute])
            Picker("繰り返し", selection: $repeatFreq) {
                Text("しない").tag("none")
                Text("毎日").tag("daily")
                Text("毎週").tag("weekly")
                Text("毎月").tag("monthly")
            }
        }
        Section {
            Picker("カレンダー", selection: $calendarId) {
                ForEach(model.calendars, id: \.id) { c in
                    Label(c.name, systemImage: "circle.fill").foregroundStyle(Color(hex: c.color)).tag(c.id)
                }
            }
            TextField("場所", text: $place)
        }
    }

    // MARK: タスク

    @ViewBuilder
    private var taskFields: some View {
        Section {
            Picker("タスクの種類", selection: $isCheck) {
                Label("実行する", systemImage: "play.circle").tag(false)
                Label("確認する", systemImage: "checkmark.circle").tag(true)
            }
            if isCheck {
                DatePicker("確認する時刻", selection: $start)
            } else {
                Toggle("時間を決める", isOn: $hasTime.animation())
                if hasTime {
                    DatePicker("開始", selection: $start)
                    DatePicker("終了", selection: $end, in: start...)
                }
            }
        } footer: {
            if !isCheck && !hasTime { Text("時間を決めないタスクは「未割当」に入ります。") }
        }
        Section {
            Toggle("締切", isOn: $hasDeadline.animation()).disabled(spec == nil)
            if hasDeadline && spec != nil { DatePicker("締切", selection: $deadline) }
            if !isCheck {
                Toggle("見積もり", isOn: $hasEstimate.animation())
                if hasEstimate { Stepper("\(estimate)分", value: $estimate, in: 5...600, step: 5) }
            }
            Toggle("フラグ", isOn: $flagged)
        } footer: {
            if spec == nil { Text("締切は「種類」を選ぶと設定できます（Web 版と同じ保存形式）。") }
        }
        Section("アイコン") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
                ForEach(Array(IconMap.symbols.keys.sorted()), id: \.self) { key in
                    Button { icon = key } label: {
                        Image(systemName: IconMap.symbols[key]!)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(icon == key ? Color.accentColor.opacity(0.2) : Color.clear))
                            .foregroundStyle(icon == key ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key)
                    .accessibilityAddTraits(icon == key ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 読み込みと保存

    private func load() {
        guard !loaded else { return }
        loaded = true
        kind = seed.kind
        let now = model.now
        let base = seed.start ?? (((now / (15 * MINUTE)) + 1) * 15 * MINUTE)
        start = model.time.date(base)
        end = model.time.date(seed.end ?? base + HOUR)
        spec = seed.spec
        if let id = seed.taskId, let t = model.tasks.first(where: { $0.id == id }) {
            isNew = false; kind = .task; task = t
            title = t.title; notes = t.notes; spec = t.specType; isCheck = t.kind == .check
            flagged = t.flagged; icon = IconMap.symbols[t.icon] != nil ? t.icon : "book"
            if let c = t.checkAt { start = model.time.date(c) }
            if let s = t.plannedStart, let e = t.plannedEnd { start = model.time.date(s); end = model.time.date(e); hasTime = true } else { hasTime = false }
            if let d = t.deadline { hasDeadline = true; deadline = model.time.date(d) }
            if let m = t.estimateMinutes { hasEstimate = true; estimate = m }
            details = t.extra?["spec"]?["details"]?.objectValue ?? [:]
        } else if let id = seed.eventId, let e = model.events.first(where: { $0.id == id }) {
            isNew = false; kind = .event; event = e
            title = e.title; notes = e.notes; spec = e.specType; calendarId = e.calendarId
            details = e.extra?["spec"]?["details"]?.objectValue ?? [:]
            start = model.time.date(e.start); end = model.time.date(e.end); allDay = e.allDay
            repeatFreq = e.recurrence?.freq.rawValue ?? "none"; place = e.placeName ?? ""
        } else {
            titleFocused = true
            calendarId = model.calendars.first?.id ?? "cal-general"
        }
    }

    private func save() {
        let now = model.now
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok: Bool
        if kind == .event {
            var e = isNew ? MTEvent.make(title: name, calendarId: calendarId, start: 0, end: 0, now: now, id: model.repo.newId()) : event
            e.title = name
            e.notes = notes
            e.calendarId = calendarId
            if allDay {
                e.start = model.time.startOfDay(model.time.ms(start))
                e.end = model.time.addDays(model.time.startOfDay(model.time.ms(end)), 1)
            } else {
                e.start = model.time.ms(start)
                e.end = model.time.ms(end)
            }
            if repeatFreq == "none" {
                e.recurrence = nil
            } else if let f = RecurrenceFreq(rawValue: repeatFreq), e.recurrence?.freq != f {
                e.recurrence = RecurrenceRule(freq: f, byWeekday: f == .weekly ? [model.time.weekday(e.start)] : nil)
            }
            var extra = e.extra?.objectValue ?? [:]
            extra["allDay"] = allDay ? .bool(true) : nil
            if place.isEmpty { extra["place"] = nil } else { extra["place"] = (extra["place"] ?? .object([:])).merging(.object(["name": .string(place)])) }
            extra["spec"] = specJSON(extra["spec"], dueAt: nil)
            e.extra = extra.isEmpty ? (e.extra == nil ? nil : .object([:])) : .object(extra)
            ok = model.perform(isNew ? "予定を追加しました" : "保存しました") { try model.repo.saveEvent(e, isNew: isNew) }
        } else {
            var t = isNew ? MTTask.make(title: name, kind: isCheck ? .check : .do, now: now, id: model.repo.newId()) : task
            t.title = name
            t.notes = notes
            t.kind = isCheck ? .check : .do
            t.flagged = flagged
            t.icon = icon
            if isCheck {
                t.checkAt = model.time.ms(start); t.plannedStart = nil; t.plannedEnd = nil
            } else if hasTime {
                t.plannedStart = model.time.ms(start); t.plannedEnd = model.time.ms(end); t.checkAt = nil
            } else {
                t.plannedStart = nil; t.plannedEnd = nil; t.checkAt = nil
            }
            t.estimateMinutes = hasEstimate && !isCheck ? estimate : nil
            var extra = t.extra?.objectValue ?? [:]
            extra["spec"] = specJSON(extra["spec"], dueAt: hasDeadline && spec != nil ? model.time.ms(deadline) : nil)
            t.extra = extra.isEmpty ? (t.extra == nil ? nil : .object([:])) : .object(extra)
            if !hasDeadline, t.assignment != nil, var a = t.assignment?.objectValue { a["deadline"] = .null; t.assignment = .object(a) }
            ok = model.perform(isNew ? "タスクを追加しました" : "保存しました") { try model.repo.saveTask(t, isNew: isNew) }
        }
        if ok { saved += 1; dismiss() }
    }

    /// `extra.spec`（Web 版と同じ形：`{ type, details: { dueAt, … } }`）。知らない項目は残す
    private func specJSON(_ old: JSONValue?, dueAt: EpochMs?) -> JSONValue? {
        // Web 版の検証では type と details が両方必要。種類なしなら spec 自体を持たない
        guard let spec else { return nil }
        var o = old?.objectValue ?? [:]
        var details = o["type"]?.stringValue == spec.rawValue ? (o["details"]?.objectValue ?? [:]) : [:]
        // 画面で編集した項目を重ねる（空にした項目は消す。知らない項目は残す）
        let known = Set(SPEC_BY_ID[spec]!.fields.map(\.key))
        for k in known where k != "dueAt" { details[k] = self.details[k] }
        details["dueAt"] = dueAt.map { .number(Double($0)) }
        o["type"] = .string(spec.rawValue)
        o["details"] = .object(details)
        return .object(o)
    }
}
