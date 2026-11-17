import SwiftUI
import MyTimeCore

// MARK: 一覧

/// Create Studio：自分専用の種類（項目・進捗の計り方）を作る。Web 版と同じ studioTypes に保存する
struct StudioListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: StudioType?

    var body: some View {
        let active = model.studioTypes.filter { $0.status != "hidden" }
        let hidden = model.studioTypes.filter { $0.status == "hidden" }
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("自分専用の種類", systemImage: "sparkles").font(.headline).foregroundStyle(.purple)
                    Text("「読書記録」「筋トレ」「バイトのシフト」など、決まった項目を持つ予定・タスクの型を作れます。作った種類は、新しく追加するときの「種類」から選べます。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(active) { t in typeRow(t) }
                Button { startNew() } label: { Label("新しい種類を作る", systemImage: "plus.circle.fill") }
            } header: { Text("使っている種類") }
            Section {
                ForEach(templates, id: \.name) { tpl in
                    Button { startTemplate(tpl) } label: {
                        HStack(spacing: 12) {
                            RowIcon(symbol: IconMap.symbol(tpl.icon), tint: Color(hex: tpl.color))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tpl.name).foregroundStyle(.primary)
                                Text(tpl.desc).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("ひな形から作る") }
            if !hidden.isEmpty {
                Section {
                    ForEach(hidden) { t in
                        typeRow(t)
                            .swipeActions { Button("戻す") { model.perform { try model.repo.hideStudioType(t.id, hidden: false) } }.tint(.green) }
                    }
                } header: { Text("隠した種類") } footer: { Text("隠しても、その種類で入れた値は残ります。") }
            }
        }
        .navigationTitle("Create Studio")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { t in
            // 新しいかどうかは、保存済みかで決める（状態の受け渡しの遅れで「編集」と出ないように）
            StudioTypeEditor(type: t, isNew: model.studioType(t.id) == nil).environment(model)
        }
    }

    private func typeRow(_ t: StudioType) -> some View {
        Button { editing = t } label: {
            HStack(spacing: 12) {
                RowIcon(symbol: IconMap.symbol(t.icon), tint: Color(hex: t.color))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).foregroundStyle(.primary)
                    Text("\(t.target == "calendar" ? "予定" : "タスク")・項目\(t.visibleFields.count)個" + (t.progress.mode == .none ? "" : "・進捗あり")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("v\(t.version)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            if t.status != "hidden" {
                Button("隠す", role: .destructive) { model.perform("「\(t.name)」を隠しました", undo: { try model.repo.hideStudioType(t.id, hidden: false) }) { try model.repo.hideStudioType(t.id) } }
            }
        }
    }

    private func startNew() {
        editing = StudioType.make(name: "", target: "task", now: model.now, id: model.repo.newId())
    }

    private struct Template { var name: String; var desc: String; var icon: String; var color: String; var target: String; var fields: [(StudioFieldType, String, String?)]; var progress: StudioProgressMode; var progressField: Int?; var goal: Double? }

    private var templates: [Template] {
        [
            Template(name: "筋トレ", desc: "種目のチェックと回数", icon: "run", color: "#FF3B30", target: "task",
                     fields: [(.check, "腕立て", nil), (.check, "腹筋", nil), (.check, "スクワット", nil), (.number, "回数", "times")], progress: .checklist, progressField: nil, goal: nil),
            Template(name: "レッスン", desc: "先生・持ち物・内容（予定）", icon: "music", color: "#5E5CE6", target: "calendar",
                     fields: [(.text, "先生", nil), (.text, "持ち物", nil), (.multiline, "やった内容", nil)], progress: .none, progressField: nil, goal: nil),
        ]
    }

    private func startTemplate(_ tpl: Template) {
        var t = StudioType.make(name: tpl.name, target: tpl.target, now: model.now, id: model.repo.newId())
        t.icon = tpl.icon; t.color = tpl.color
        t.fields = tpl.fields.map { StudioField(id: model.repo.newId(), type: $0.0, label: $0.1, sectionId: "main", unit: $0.2) }
        t.progress = StudioProgress(mode: tpl.progress, fieldId: tpl.progressField.map { t.fields[$0].id }, target: tpl.goal)
        editing = t
    }
}

// MARK: 種類の編集

struct StudioTypeEditor: View {
    @State var type: StudioType
    var isNew: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingPart = false
    @State private var editingField: StudioField?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
                Section {
                    HStack(spacing: 12) {
                        RowIcon(symbol: IconMap.symbol(type.icon), tint: Color(hex: type.color))
                        TextField("種類の名前（例：読書記録）", text: $type.name).font(.title3.weight(.medium))
                    }
                    Picker("使う場所", selection: $type.target) {
                        Text("タスク").tag("task")
                        Text("予定").tag("calendar")
                    }
                    .pickerStyle(.segmented)
                    .disabled(!isNew)
                } footer: { if !isNew { Text("使う場所（予定・タスク）は、作ったあとは変えられません。") } }

                Section("色") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(EditorView.colors, id: \.self) { c in
                                Button { type.color = c } label: {
                                    Circle().fill(Color(hex: c)).frame(width: 30, height: 30)
                                        .overlay(Circle().strokeBorder(type.color == c ? Color.primary : .clear, lineWidth: 2).padding(-4))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                    }
                }
                Section("アイコン") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
                        ForEach(Array(IconMap.symbols.keys.sorted()), id: \.self) { key in
                            Button { type.icon = key } label: {
                                Image(systemName: IconMap.symbols[key]!)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(type.icon == key ? Color(hex: type.color).opacity(0.2) : .clear))
                                    .foregroundStyle(type.icon == key ? Color(hex: type.color) : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if type.visibleFields.isEmpty {
                        Text("まだ項目がありません").foregroundStyle(.secondary)
                    }
                    ForEach(type.visibleFields) { f in
                        Button { editingField = f } label: {
                            HStack(spacing: 12) {
                                Image(systemName: Self.symbol(f.type)).foregroundStyle(Color(hex: type.color)).frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.type == .note ? (f.body.isEmpty ? "説明" : f.body) : (f.label.isEmpty ? "名前なし" : f.label))
                                        .foregroundStyle(f.label.isEmpty && f.type != .note ? .red : .primary).lineLimit(1)
                                    Text(Self.partLabel(f.type) + (f.unit.map { "・\(studioUnitLabel($0))" } ?? "") + (f.required ? "・必須" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove(perform: moveFields)
                    .onDelete(perform: deleteFields)
                    Button { addingPart = true } label: { Label("項目を追加", systemImage: "plus.circle.fill") }
                } header: {
                    HStack { Text("項目"); Spacer(); EditButton().font(.caption) }
                } footer: { Text("削除した項目は隠すだけで、すでに入れた値は残ります。") }

                Section {
                    Picker("進み具合の計り方", selection: $type.progress.mode) {
                        Text("使わない").tag(StudioProgressMode.none)
                        Text("数値÷目標").tag(StudioProgressMode.number)
                        Text("チェック項目").tag(StudioProgressMode.checklist)
                        Text("実行時間÷目標").tag(StudioProgressMode.time)
                        Text("手動の％").tag(StudioProgressMode.manual)
                    }
                    if type.progress.mode == .number || type.progress.mode == .manual {
                        let candidates = type.visibleFields.filter { type.progress.mode == .number ? $0.type == .number : $0.type == .progress }
                        Picker("使う項目", selection: $type.progress.fieldId) {
                            Text("選んでください").tag(String?.none)
                            ForEach(candidates) { f in Text(f.label).tag(Optional(f.id)) }
                        }
                    }
                    if type.progress.mode == .number || type.progress.mode == .time {
                        HStack {
                            Text(type.progress.mode == .time ? "目標（分）" : "目標")
                            Spacer()
                            TextField("例：100", value: $type.progress.target, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
                        }
                    }
                } header: { Text("進み具合") } footer: { Text(progressHint) }

                if !isNew {
                    Section {
                        LabeledContent("版", value: "v\(type.version)")
                        LabeledContent("変更の履歴", value: "\(type.raw["revisions"]?.arrayValue?.count ?? 0)件")
                    }
                }
            }
            .navigationTitle(isNew ? "新しい種類" : "種類を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).fontWeight(.semibold) }
            }
            .sheet(isPresented: $addingPart) {
                StudioPartsPicker { part in
                    let f = StudioField(id: model.repo.newId(), type: part.type, label: part.type == .note ? "" : part.label, sectionId: type.sections.first?.id ?? "main",
                                        unit: part.type == .duration ? "min" : nil, showInInfo: part.type != .note)
                    type.fields.append(f)
                    addingPart = false
                    editingField = f
                }
            }
            .sheet(item: $editingField) { f in
                StudioFieldEditor(field: f) { updated in
                    if let i = type.fields.firstIndex(where: { $0.id == updated.id }) { type.fields[i] = updated }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var progressHint: String {
        switch type.progress.mode {
        case .none: return "タスクの進み具合の輪には、サブタスクか手で入れた実績を使います。"
        case .number: return "数値の項目 ÷ 目標で進み具合を出します（例：読んだページ 20/100）。"
        case .checklist: return "チェック項目のうち、チェックした数で進み具合を出します。"
        case .time: return "開始〜完了で記録した時間 ÷ 目標（分）で進み具合を出します。"
        case .manual: return "「進捗（手動％）」の項目に入れた値を使います。"
        }
    }

    private func moveFields(_ from: IndexSet, _ to: Int) {
        var visible = type.visibleFields
        visible.move(fromOffsets: from, toOffset: to)
        type.fields = visible + type.fields.filter(\.hidden)
    }

    /// 削除は隠すだけ（Web 版と同じ。入れた値は残る）
    private func deleteFields(_ offsets: IndexSet) {
        let ids = offsets.map { type.visibleFields[$0].id }
        for i in type.fields.indices where ids.contains(type.fields[i].id) { type.fields[i].hidden = true }
        if let p = type.progress.fieldId, ids.contains(p) { type.progress.fieldId = nil }
    }

    private func save() {
        error = nil
        if (type.progress.mode == .number || type.progress.mode == .manual) && type.progress.fieldId == nil {
            error = "進み具合に使う項目を選んでください"; return
        }
        if model.perform(isNew ? "「\(type.name)」を作りました" : nil, { try model.repo.saveStudioType(type, isNew: isNew) }) { dismiss() }
    }

    static func symbol(_ t: StudioFieldType) -> String {
        switch t {
        case .text: return "textformat"
        case .multiline: return "text.alignleft"
        case .number: return "number"
        case .datetime: return "calendar.badge.clock"
        case .duration: return "hourglass"
        case .toggle: return "switch.2"
        case .check: return "checkmark.square"
        case .select: return "list.bullet.circle"
        case .multiselect: return "checklist"
        case .url: return "link"
        case .place: return "mappin.and.ellipse"
        case .file: return "paperclip"
        case .progress: return "percent"
        case .worktime: return "timer"
        case .note: return "text.quote"
        }
    }

    static func partLabel(_ t: StudioFieldType) -> String { STUDIO_PARTS.first { $0.type == t }?.label ?? t.rawValue }
}

// MARK: 部品を選ぶ

struct StudioPartsPicker: View {
    var onPick: (StudioPart) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(searchStudioParts(query), id: \.label) { p in
                Button { onPick(p) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: StudioTypeEditor.symbol(p.type)).font(.title3).foregroundStyle(Color.accentColor).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.label).foregroundStyle(.primary)
                            Text(p.desc).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "「ページ」「締切」などで探す")
            .navigationTitle("項目を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: 項目の編集

struct StudioFieldEditor: View {
    @State var field: StudioField
    var onDone: (StudioField) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newOption = ""
    @State private var customUnit = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if field.type == .note {
                        TextField("説明の文（入力画面に表示）", text: $field.body, axis: .vertical).lineLimit(2...6)
                    } else {
                        TextField("項目の名前", text: $field.label)
                    }
                    LabeledContent("種類", value: StudioTypeEditor.partLabel(field.type))
                }
                if field.type == .number || field.type == .duration {
                    Section("単位") {
                        Picker("単位", selection: Binding(get: { field.unit ?? "" }, set: { field.unit = $0.isEmpty ? nil : $0 })) {
                            Text("なし").tag("")
                            ForEach(STUDIO_UNITS.filter { field.type == .duration ? $0.dim == "time" : true }, id: \.id) { Text($0.label).tag($0.id) }
                            if let u = field.unit, u.hasPrefix("custom:") { Text(studioUnitLabel(u)).tag(u) }
                        }
                        if field.type == .number {
                            HStack {
                                TextField("ほかの単位（例：km）", text: $customUnit)
                                Button("使う") { if !customUnit.isEmpty { field.unit = "custom:" + customUnit; customUnit = "" } }.disabled(customUnit.isEmpty)
                            }
                            Stepper("小数点以下 \(field.precision)桁", value: $field.precision, in: 0...3)
                        }
                    }
                    Section("範囲") {
                        HStack { Text("最小"); Spacer(); TextField("なし", value: $field.min, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        HStack { Text("最大"); Spacer(); TextField("なし", value: $field.max, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    }
                }
                if field.type == .select || field.type == .multiselect {
                    Section("選択肢") {
                        ForEach(field.options, id: \.self) { Text($0) }
                            .onDelete { field.options.remove(atOffsets: $0) }
                            .onMove { field.options.move(fromOffsets: $0, toOffset: $1) }
                        HStack {
                            TextField("選択肢を追加", text: $newOption).onSubmit(addOption)
                            Button("追加", action: addOption).disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if field.type != .note && field.type != .worktime {
                    Section {
                        Toggle("必ず入力する", isOn: $field.required)
                        Toggle("詳細の画面に表示する", isOn: $field.showInInfo)
                    }
                }
            }
            .navigationTitle("項目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完了") { onDone(field); dismiss() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.large])
    }

    private func addOption() {
        let o = newOption.trimmingCharacters(in: .whitespaces)
        guard !o.isEmpty, !field.options.contains(o) else { return }
        field.options.append(o); newOption = ""
    }
}

// MARK: 入力（新規・編集の「専用」）

/// 種類の項目を入力する欄（値は extra.studio.values に、項目 ID をキーとして入れる）
struct StudioFieldsForm: View {
    var type: StudioType
    @Binding var values: [String: JSONValue]
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(type.visibleFields) { f in fieldRow(f) }
        } header: {
            Label(type.name, systemImage: IconMap.symbol(type.icon)).foregroundStyle(Color(hex: type.color))
        } footer: {
            let p = studioProgress(type, values: values)
            if type.progress.mode != .none, p.value != nil || !p.label.isEmpty {
                Text("進み具合：\(p.label)" + (p.over ? "（目標を超えました）" : ""))
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ f: StudioField) -> some View {
        let label = f.label + (f.required ? "（必須）" : "")
        switch f.type {
        case .text, .url, .place:
            HStack {
                Text(label)
                TextField(f.type == .url ? "https://" : "未入力", text: string(f)).multilineTextAlignment(.trailing)
                    .keyboardType(f.type == .url ? .URL : .default).textInputAutocapitalization(f.type == .url ? .never : .sentences)
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                TextField("未入力", text: string(f), axis: .vertical).lineLimit(2...8)
            }
        case .number, .progress:
            HStack {
                Text(label)
                Spacer()
                TextField(f.type == .progress ? "0〜100" : "0", value: number(f), format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
                Text(f.type == .progress ? "%" : studioUnitLabel(f.unit)).foregroundStyle(.secondary)
            }
        case .duration:
            Picker(label, selection: Binding(get: { Int(values[f.id]?.doubleValue ?? 0) }, set: { values[f.id] = $0 == 0 ? nil : .number(Double($0)) })) {
                Text("なし").tag(0)
                ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120, 180], id: \.self) { m in Text(m < 60 ? "\(m)分" : m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分").tag(m) }
            }
        case .datetime:
            Toggle(label, isOn: Binding(get: { values[f.id] != nil }, set: { values[f.id] = $0 ? .number(Double(model.now)) : nil }))
            if let v = values[f.id]?.intValue {
                DatePicker("日時", selection: Binding(get: { model.time.date(v) }, set: { values[f.id] = .number(Double(model.time.ms($0))) }))
            }
        case .toggle, .check:
            Toggle(isOn: Binding(get: { values[f.id]?.boolValue ?? false }, set: { values[f.id] = $0 ? .bool(true) : .bool(false) })) {
                if f.type == .check { Label(label, systemImage: "checkmark.square") } else { Text(label) }
            }
        case .select:
            Picker(label, selection: Binding(get: { values[f.id]?.stringValue ?? "" }, set: { values[f.id] = $0.isEmpty ? nil : .string($0) })) {
                Text("未選択").tag("")
                ForEach(f.options, id: \.self) { Text($0).tag($0) }
            }
        case .multiselect:
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                let selected = Set(values[f.id]?.arrayValue?.compactMap(\.stringValue) ?? [])
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(f.options, id: \.self) { o in
                            let on = selected.contains(o)
                            Button {
                                var s = selected
                                if on { s.remove(o) } else { s.insert(o) }
                                values[f.id] = s.isEmpty ? nil : .array(f.options.filter(s.contains).map { .string($0) })
                            } label: {
                                Text(o).font(.subheadline)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(on ? Color(hex: type.color) : Color(.tertiarySystemFill)))
                                    .foregroundStyle(on ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        case .worktime:
            LabeledContent(label, value: "開始〜完了で自動で記録")
        case .note:
            Text(f.body).font(.footnote).foregroundStyle(.secondary)
        case .file:
            LabeledContent(label, value: "iOS 版ではまだ添付できません")
        }
    }

    private func string(_ f: StudioField) -> Binding<String> {
        Binding(get: { values[f.id]?.stringValue ?? "" }, set: { values[f.id] = $0.isEmpty ? nil : .string($0) })
    }

    private func number(_ f: StudioField) -> Binding<Double?> {
        Binding(get: { values[f.id]?.doubleValue }, set: { v in
            guard var v else { values[f.id] = nil; return }
            if let lo = f.min { v = max(lo, v) }
            if let hi = f.max { v = min(hi, v) }
            if f.type == .progress { v = max(0, min(100, v)) }
            values[f.id] = .number(v)
        })
    }
}

/// 詳細の画面に出す値（showInInfo の項目）
func studioInfoRows(_ type: StudioType, values: [String: JSONValue], time: DomainTime, hm: (EpochMs) -> String) -> [(String, String)] {
    type.visibleFields.filter { $0.showInInfo && $0.type != .note }.compactMap { f in
        guard let v = values[f.id] else { return nil }
        switch f.type {
        case .number: return v.doubleValue.map { (f.label, studioFormat(f, $0)) }
        case .progress: return v.doubleValue.map { (f.label, "\(Int($0))%") }
        case .duration: return v.doubleValue.map { (f.label, formatDuration(EpochMs($0) * MINUTE)) }
        case .toggle, .check: return v.boolValue.map { (f.label, $0 ? "はい" : "いいえ") }
        case .datetime: return v.intValue.map { (f.label, "\(time.dayLabel($0)) \(hm($0))") }
        case .multiselect: return (f.label, (v.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "・"))
        default: return v.stringValue.flatMap { $0.isEmpty ? nil : (f.label, $0) }
        }
    }
}
