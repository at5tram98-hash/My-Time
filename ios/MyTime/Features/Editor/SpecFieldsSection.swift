import SwiftUI
import MyTimeCore

/// 種類（S01〜S25）ごとの専用の入力項目（Web 版 SpecForm と同じキーで `extra.spec.details` に保存する）。
/// 勤務枠・分担・工程のような複雑な項目は、iOS 版では件数の表示だけにして中身は元のまま残す。
struct SpecFieldsSection: View {
    let spec: SpecTypeId
    @Binding var details: [String: JSONValue]
    @Environment(AppModel.self) private var model

    var body: some View {
        let def = SPEC_BY_ID[spec]!
        let fields = def.fields.filter { $0.key != "dueAt" } // 締切は上の「締切」で入力する
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
        case .slots, .members, .steps:
            LabeledContent(f.label, value: "\(details[f.key]?.arrayValue?.count ?? 0)件（Web 版で編集）")
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
