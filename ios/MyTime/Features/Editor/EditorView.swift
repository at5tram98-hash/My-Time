import SwiftUI
import MyTimeCore

/// 予定・タスクの追加と編集。保存できない入力は理由を表示し、入力はそのまま残す
struct EditorView: View {
    var seed: EditorSeed
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
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
    /// 予定の前の移動時間（分。0 は移動なし。Web 版と同じ extra.travelMinutes）
    @State private var travel = 0
    @State private var showIcons = false
    @State private var showDetails = false
    @State private var flagged = false
    @State private var icon = "book"
    @State private var saved = 0
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    Picker("種類", selection: $kind.animation(.snappy)) {
                        Text("タスク").tag(EditorSeed.Kind.task)
                        Text("予定").tag(EditorSeed.Kind.event)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    HStack {
                    TextField(kind == .event ? "予定の名前" : "やること", text: $title)
                        .font(.title3.weight(.medium))
                        .focused($titleFocused)
                        .submitLabel(canSave ? .done : .return)
                        // 改行で、そのまま追加（純正リマインダーと同じ速さで入れられる）
                        .onSubmit { if canSave { save() } else { titleFocused = false } }
                        if isNew && title.isEmpty {
                            // 「明日10時から1時間 歯医者」のように文章でまとめて入れる
                            Button { router.open(.quickAdd) } label: {
                                Image(systemName: "text.bubble").font(.title3).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("文章で追加")
                        }
                    }
                    // 候補は入力を始めてから出す（最初の画面を静かに）
                    if isNew && !title.isEmpty && !suggestions.isEmpty { suggestionRow }
                }
                if kind == .event { eventFields } else { taskFields }
                detailsSection
            }
            // 下へなぞるとキーボードを閉じる
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? (kind == .event ? "新しい予定" : "新しいタスク") : "編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "追加" : "保存", action: save).fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
            .sensoryFeedback(.success, trigger: saved)
        }
        .interactiveDismissDisabled(!title.isEmpty && isNew)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 開始を変えたら長さを保って終了も動かす（時間のバーは開始・終了を別々に動かすので、これを使わない）
    private var startKeepingLength: Binding<Date> {
        Binding(get: { start }, set: { new in
            let len = end.timeIntervalSince(start)
            start = new
            if len > 0 { end = new.addingTimeInterval(len) }
        })
    }

    private func shiftDay(_ n: Int) {
        let cal = Calendar.current
        start = cal.date(byAdding: .day, value: n, to: start) ?? start
        end = cal.date(byAdding: .day, value: n, to: end) ?? end
    }

    /// 日付（スワイプで変更）＋時間のバー（なぞって変更）＋まとめの1行
    @ViewBuilder
    private var timeRows: some View {
        DaySwipeRow(date: startKeepingLength, onShift: shiftDay)
        TimeRangeBar(start: $start, end: $end, tint: kind == .event ? calendarTint : .accentColor)
            .padding(.vertical, 4)
        HStack {
            Text("\(hm(start))〜\(hm(end))").font(.title3.weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
            Text(lengthText).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText())
        }
        .animation(.snappy, value: start)
        .animation(.snappy, value: end)
    }

    private var calendarTint: Color { Color(hex: model.calendar(calendarId)?.color ?? "#0A84FF") }

    private func hm(_ d: Date) -> String { model.hm(model.time.ms(d)) }

    private var lengthText: String {
        let len = max(0, Int(end.timeIntervalSince(start) / 60))
        return len < 60 ? "\(len)分" : len % 60 == 0 ? "\(len / 60)時間" : "\(len / 60)時間\(len % 60)分"
    }

    /// あまり使わない項目はここにまとめる（入っている値があれば最初から開く）
    private var detailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showDetails.animation(.snappy)) {
                specMenu
                if kind == .event {
                    calendarChips
                    HStack {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary).frame(width: 22)
                        TextField("場所", text: $place)
                    }
                    Stepper(value: $travel, in: 0...240, step: 5) {
                        HStack {
                            Image(systemName: "tram.fill").foregroundStyle(.secondary).frame(width: 22)
                            Text("移動")
                            Spacer()
                            Text(travel == 0 ? "なし" : "\(travel)分・\(model.hm(model.time.ms(start) - EpochMs(travel) * MINUTE))発")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Picker(selection: $repeatFreq) {
                        Text("しない").tag("none")
                        Text("毎日").tag("daily")
                        Text("毎週（\(DomainTime.weekdayJa[model.time.weekday(model.time.ms(start))])曜日）").tag("weekly")
                        Text("毎月（\(Calendar.current.component(.day, from: start))日）").tag("monthly")
                    } label: { Label("繰り返し", systemImage: "repeat").foregroundStyle(.primary) }
                    if !allDay {
                        DatePicker("開始", selection: startKeepingLength)
                        DatePicker("終了", selection: $end, in: start...)
                    }
                } else {
                    Toggle(isOn: $hasDeadline.animation()) { Label("締切", systemImage: "flag.checkered") }.disabled(spec == nil)
                    if hasDeadline && spec != nil { DatePicker("締切", selection: $deadline) }
                    if !isCheck {
                        Toggle(isOn: $hasEstimate.animation()) { Label("見積もり", systemImage: "hourglass") }
                        if hasEstimate {
                            Stepper("\(estimate)分", value: $estimate, in: 5...600, step: 5)
                        }
                    }
                    Toggle(isOn: $flagged) { Label("フラグ", systemImage: "flag") }
                    if hasTime && !isCheck {
                        DatePicker("開始", selection: startKeepingLength)
                        DatePicker("終了", selection: $end, in: start...)
                    }
                    iconPicker
                }
                if let spec { SpecFieldsSection(spec: spec, details: $details) }
                TextField("メモ", text: $notes, axis: .vertical).lineLimit(2...8)
            } label: {
                HStack {
                    Text("詳細")
                    Spacer()
                    Text(detailsSummary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } footer: {
            if kind == .task && spec == nil && showDetails { Text("締切は「種類」を選ぶと設定できます（Web 版と同じ保存形式）。") }
        }
    }

    /// 詳細をたたんでいるときに、入っている値を短く見せる
    private var detailsSummary: String {
        var parts: [String] = []
        if let d = spec.flatMap({ SPEC_BY_ID[$0] }) { parts.append(d.name) }
        if kind == .event {
            parts.append(model.calendar(calendarId)?.name ?? "")
            if !place.isEmpty { parts.append(place) }
            if repeatFreq != "none" { parts.append("繰り返し") }
        } else {
            if hasDeadline { parts.append("締切") }
            if flagged { parts.append("フラグ") }
            if hasEstimate { parts.append("\(estimate)分") }
        }
        if !notes.isEmpty { parts.append("メモ") }
        return parts.filter { !$0.isEmpty }.joined(separator: "・")
    }

    // MARK: 予定

    @ViewBuilder
    private var eventFields: some View {
        Section {
            Toggle("終日", isOn: $allDay.animation())
            if allDay {
                DatePicker("開始", selection: startKeepingLength, displayedComponents: .date)
                DatePicker("終了", selection: $end, in: start..., displayedComponents: .date)
            } else {
                timeRows
            }
        } footer: {
            if let c = conflict { Label("「\(c.title)」（\(model.hm(c.start))〜\(model.hm(c.end))）と重なっています", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            else if !allDay { Text("バーをなぞると時間を、日付を左右になぞると日を変えられます。") }
        }
    }

    // MARK: タスク

    @ViewBuilder
    private var taskFields: some View {
        Section {
            Picker("タスクの種類", selection: $isCheck.animation()) {
                Text("実行する").tag(false)
                Text("確認する").tag(true)
            }
            .pickerStyle(.segmented)
            if isCheck {
                DatePicker("確認する時刻", selection: $start)
            } else {
                Toggle("時間を決める", isOn: $hasTime.animation())
                if hasTime { timeRows }
            }
        } footer: {
            if !isCheck && !hasTime { Text("時間を決めないタスクは「未割当」に入ります。") }
        }
    }

    private var iconPicker: some View {
        DisclosureGroup(isExpanded: $showIcons) {
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
        } label: {
            HStack {
                Label("アイコン", systemImage: "face.smiling")
                Spacer()
                Image(systemName: IconMap.symbol(icon)).foregroundStyle(Color.accentColor)
            }
        }
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

    // MARK: 入力を助ける部品

    /// 横に並ぶ小さなボタン（選んでいるものは色つき）
    private func chipRow(_ items: [(String, Bool, () -> Void)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    Button(action: it.2) {
                        Text(it.0).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(it.1 ? Color.accentColor : Color(.tertiarySystemFill)))
                            .foregroundStyle(it.1 ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(it.1 ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
    }

    /// カレンダーを色の丸で選ぶ（純正カレンダーの色分けと同じ考え方）
    private var calendarChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.calendars, id: \.id) { c in
                    let on = c.id == calendarId
                    Button { calendarId = c.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: c.color)).frame(width: 12, height: 12)
                            Text(c.name).font(.subheadline.weight(on ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(on ? Color(hex: c.color).opacity(0.18) : Color(.tertiarySystemFill)))
                        .overlay(Capsule().strokeBorder(on ? Color(hex: c.color) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
    }

    /// 前に使った名前（入力中の文字で絞り込む）。選ぶと長さ・カレンダー・場所も前回と同じにする
    private struct Suggestion: Identifiable { var id: String { title }; var title: String; var minutes: Int?; var calendarId: String?; var place: String?; var travel: Int? }

    private var suggestions: [Suggestion] {
        let q = title.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>(), out: [Suggestion] = []
        if kind == .event {
            for e in model.events.sorted(by: { $0.updatedAt > $1.updatedAt }) where !e.title.isEmpty && !seen.contains(e.title) {
                if !q.isEmpty && (!e.title.localizedCaseInsensitiveContains(q) || e.title == q) { continue }
                seen.insert(e.title)
                out.append(Suggestion(title: e.title, minutes: e.allDay ? nil : Int((e.end - e.start) / MINUTE), calendarId: e.calendarId, place: e.placeName, travel: e.travelMinutes))
                if out.count >= 6 { break }
            }
        } else {
            for t in model.tasks.sorted(by: { $0.updatedAt > $1.updatedAt }) where !t.title.isEmpty && !seen.contains(t.title) {
                if !q.isEmpty && (!t.title.localizedCaseInsensitiveContains(q) || t.title == q) { continue }
                seen.insert(t.title)
                out.append(Suggestion(title: t.title, minutes: t.plannedStart.flatMap { s in t.plannedEnd.map { Int(($0 - s) / MINUTE) } }, calendarId: nil, place: nil, travel: nil))
                if out.count >= 6 { break }
            }
        }
        return out
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions) { sg in
                    Button {
                        title = sg.title
                        if let m = sg.minutes, m > 0 { end = start.addingTimeInterval(TimeInterval(m * 60)) }
                        if let c = sg.calendarId { calendarId = c }
                        if let p = sg.place { place = p }
                        if let t = sg.travel { travel = t }
                    } label: {
                        Label(sg.title, systemImage: "clock.arrow.circlepath")
                            .font(.subheadline).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("前回と同じ長さ・カレンダー・場所で入力します")
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
    }

    /// 同じ時間にある別の予定（終日は除く）
    private var conflict: EventOccurrence? {
        guard kind == .event, !allDay else { return nil }
        let s = model.time.ms(start), e = model.time.ms(end)
        guard e > s else { return nil }
        return model.visibleEvents(from: s - HOUR, to: e + HOUR).first { o in
            !o.event.allDay && o.start < e && s < o.end && (isNew || o.masterId != event.id)
        }
    }

    // MARK: 読み込みと保存

    private func load() {
        guard !loaded else { return }
        loaded = true
        defer {
            // 入っている値があれば詳細を最初から開く
            showDetails = !isNew && (spec != nil || !notes.isEmpty || !place.isEmpty || repeatFreq != "none" || hasDeadline || flagged || hasEstimate)
        }
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
            travel = e.travelMinutes ?? 0
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
            extra["travelMinutes"] = travel > 0 ? .number(Double(travel)) : nil
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
