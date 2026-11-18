import SwiftUI
import MyTimeCore

/// 種類（S01〜S25）ごとの専用の入力項目（Web 版 SpecForm と同じキーで `extra.spec.details` に保存する）。
/// 勤務枠・分担・工程のような複雑な項目は、iOS 版では件数の表示だけにして中身は元のまま残す。
struct SpecFieldsSection: View {
    let spec: SpecTypeId
    @Binding var details: [String: JSONValue]
    /// 出さない項目（勤務先の条件と重なるものなど）
    var hidden: Set<String> = []
    @Environment(AppModel.self) private var model

    var body: some View {
        let def = SPEC_BY_ID[spec]!
        let fields = def.fields.filter { $0.key != "dueAt" && !hidden.contains($0.key) } // 締切は上の「締切」で入力する
        if !fields.isEmpty {
            Section {
                ForEach(fields, id: \.key) { f in row(f) }
            } header: {
                Label(def.name, systemImage: def.symbol)
            } footer: {
                if let insight = insight { Text(insight) } else { Text(def.blurb) }
            }
        }
    }

    @ViewBuilder
    private func row(_ f: SpecField) -> some View {
        switch f.kind {
        case .text, .url:
            LabeledContent(f.label) {
                TextField(f.placeholder ?? "", text: string(f.key))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(f.kind == .url ? .URL : .default)
                    .textInputAutocapitalization(f.kind == .url ? .never : .sentences)
            }
        case .multiline:
            TextField(f.label, text: string(f.key), axis: .vertical).lineLimit(2...6)
        case .number, .money, .minutes:
            LabeledContent(f.label) {
                HStack(spacing: 4) {
                    TextField("未入力", text: number(f.key)).keyboardType(.numberPad).multilineTextAlignment(.trailing).monospacedDigit()
                    if let u = f.unit { Text(u).foregroundStyle(.secondary) }
                }
            }
        case .date, .datetime:
            optionalDate(f)
        case .select:
            Picker(f.label, selection: string(f.key)) {
                Text("未選択").tag("")
                ForEach(f.options, id: \.self) { Text($0).tag($0) }
            }
        case .toggle:
            Toggle(f.label, isOn: Binding(get: { details[f.key]?.boolValue ?? false }, set: { details[f.key] = .bool($0) }))
        case .list:
            LabeledContent(f.label) {
                TextField(f.placeholder ?? "読点「、」で区切る", text: list(f.key)).multilineTextAlignment(.trailing)
            }
        case .checklist:
            ChecklistField(label: f.label, items: Binding(get: { details[f.key]?.arrayValue ?? [] }, set: { details[f.key] = .array($0) }))
        case .slots:
            SlotsField(label: f.label, items: Binding(get: { details[f.key]?.arrayValue ?? [] }, set: { details[f.key] = $0.isEmpty ? nil : .array($0) }))
        case .members:
            MembersField(label: f.label, items: Binding(get: { details[f.key]?.arrayValue ?? [] }, set: { details[f.key] = $0.isEmpty ? nil : .array($0) }))
        case .steps:
            LabeledContent(f.label, value: "\(details[f.key]?.arrayValue?.count ?? 0)件")
        }
    }

    // MARK: 値の読み書き（空にしたら項目を消す）

    private func string(_ k: String) -> Binding<String> {
        Binding(get: { details[k]?.stringValue ?? "" }, set: { details[k] = $0.isEmpty ? nil : .string($0) })
    }
    private func number(_ k: String) -> Binding<String> {
        Binding(get: { details[k]?.doubleValue.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" },
                set: { v in details[k] = Double(v.filter { "0123456789.".contains($0) }).map { .number($0) } })
    }
    private func list(_ k: String) -> Binding<String> {
        Binding(get: { (details[k]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "、") },
                set: { v in
                    let xs = v.components(separatedBy: CharacterSet(charactersIn: "、,，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    details[k] = xs.isEmpty ? nil : .array(xs.map { .string($0) })
                })
    }

    @ViewBuilder
    private func optionalDate(_ f: SpecField) -> some View {
        let has = details[f.key]?.intValue != nil
        Toggle(f.label, isOn: Binding(get: { has }, set: { on in
            details[f.key] = on ? .number(Double(model.time.startOfDay(model.now) + (f.kind == .datetime ? 18 * HOUR : 0))) : nil
        }))
        if has {
            DatePicker(f.label, selection: Binding(get: { model.time.date(details[f.key]?.intValue ?? model.now) }, set: { details[f.key] = .number(Double(model.time.ms($0))) }),
                       displayedComponents: f.kind == .datetime ? [.date, .hourAndMinute] : .date)
                .labelsHidden()
        }
    }

    /// 入力から分かる見込み（勤務の給与など）。根拠がないときは出さない
    private var insight: String? {
        switch spec {
        case .shift:
            return nil // 給与は予定の詳細で、時刻と合わせて表示する
        case .reading:
            guard let total = details["totalPages"]?.doubleValue, let cur = details["currentPage"]?.doubleValue else { return nil }
            let rest = max(0, Int(total - cur))
            if let target = details["targetDate"]?.intValue, target > model.now {
                let days = max(1, Int(ceil(Double(target - model.now) / Double(DAY))))
                return "残り\(rest)ページ・1日あたり約\(Int(ceil(Double(rest) / Double(days))))ページ（目安）"
            }
            return "残り\(rest)ページ"
        default:
            return nil
        }
    }
}

/// チェックリスト（Web 版と同じ形：`[{ id, name, done }]`）
private struct ChecklistField: View {
    let label: String
    @Binding var items: [JSONValue]
    @State private var draft = ""

    var body: some View {
        DisclosureGroup("\(label)（\(items.filter { $0["done"]?.boolValue == true }.count)/\(items.count)）") {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button {
                    var o = item.objectValue ?? [:]
                    o["done"] = .bool(!(item["done"]?.boolValue ?? false))
                    items[i] = .object(o)
                } label: {
                    Label(item["name"]?.stringValue ?? "", systemImage: item["done"]?.boolValue == true ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item["done"]?.boolValue == true ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .swipeActions { Button("削除", role: .destructive) { items.remove(at: i) } }
            }
            HStack {
                TextField("追加", text: $draft).submitLabel(.done).onSubmit(add)
                Button("追加", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        items.append(.object(["id": .string(name), "name": .string(name), "done": .bool(false)]))
        draft = ""
    }
}

/// 希望の勤務枠（Web 版と同じ形：`[{ start, end }]`）。日付と時間をなぞって決める
private struct SlotsField: View {
    let label: String
    @Binding var items: [JSONValue]
    @Environment(AppModel.self) private var model

    var body: some View {
        DisclosureGroup("\(label)（\(items.count)件）") {
            ForEach(Array(items.enumerated()), id: \.offset) { i, v in
                let s = v["start"]?.intValue ?? model.now, e = v["end"]?.intValue ?? model.now + HOUR
                VStack(alignment: .leading, spacing: 6) {
                    DatePicker("日付", selection: Binding(get: { model.time.date(s) }, set: { d in
                        let shift = model.time.startOfDay(model.time.ms(d)) - model.time.startOfDay(s)
                        set(i, s + shift, e + shift)
                    }), displayedComponents: .date)
                    TimeRangeBar(start: Binding(get: { model.time.date(s) }, set: { set(i, model.time.ms($0), e) }),
                                 end: Binding(get: { model.time.date(e) }, set: { set(i, s, model.time.ms($0)) }), tint: .orange)
                    Text("\(model.hm(s))〜\(model.hm(e))").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                .swipeActions { Button("削除", role: .destructive) { items.remove(at: i) } }
            }
            Button("勤務枠を追加", systemImage: "plus") {
                let d = model.time.addDays(model.time.startOfDay(model.now), 7)
                items.append(.object(["start": .number(Double(d + 17 * HOUR)), "end": .number(Double(d + 22 * HOUR))]))
            }
        }
    }

    private func set(_ i: Int, _ s: EpochMs, _ e: EpochMs) {
        guard e > s, items.indices.contains(i) else { return }
        var o = items[i].objectValue ?? [:]
        o["start"] = .number(Double(s)); o["end"] = .number(Double(e))
        items[i] = .object(o)
    }
}

/// グループ課題の分担（Web 版と同じ形：`[{ name, part, mine, status }]`）
private struct MembersField: View {
    let label: String
    @Binding var items: [JSONValue]
    static let statuses: [(String, String)] = [("todo", "まだ"), ("waiting", "待ち"), ("done", "済み")]

    var body: some View {
        DisclosureGroup("\(label)（\(items.count)人）") {
            ForEach(Array(items.enumerated()), id: \.offset) { i, v in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("名前", text: bind(i, "name"))
                        Toggle("自分", isOn: Binding(get: { items[i]["mine"]?.boolValue ?? false }, set: { put(i, "mine", .bool($0)) }))
                            .toggleStyle(.button).font(.caption)
                    }
                    TextField("担当", text: bind(i, "part")).font(.subheadline)
                    Picker("状態", selection: Binding(get: { items[i]["status"]?.stringValue ?? "todo" }, set: { put(i, "status", .string($0)) })) {
                        ForEach(Self.statuses, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                }
                .swipeActions { Button("削除", role: .destructive) { items.remove(at: i) } }
            }
            Button("人を追加", systemImage: "person.badge.plus") {
                items.append(.object(["name": .string(""), "part": .string(""), "mine": .bool(false), "status": .string("todo")]))
            }
        }
    }

    private func bind(_ i: Int, _ k: String) -> Binding<String> {
        Binding(get: { items.indices.contains(i) ? items[i][k]?.stringValue ?? "" : "" }, set: { put(i, k, .string($0)) })
    }
    private func put(_ i: Int, _ k: String, _ v: JSONValue) {
        guard items.indices.contains(i) else { return }
        var o = items[i].objectValue ?? [:]
        o[k] = v
        items[i] = .object(o)
    }
}
