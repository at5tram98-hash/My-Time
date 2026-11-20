import SwiftUI
import UniformTypeIdentifiers
import MyTimeCore

struct ChatGPTTransferView: View {
    @Environment(AppModel.self) private var model
    @State private var kinds: Set<ChatGPTTransfer.Kind> = Set(ChatGPTTransfer.Kind.allCases)
    @State private var from = Calendar.current.startOfDay(for: .now)
    @State private var through = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
    @State private var importing = false
    @State private var exporting = false
    @State private var document: TransferDocument?
    @State private var preview: ChatGPTTransfer.Preview?
    @State private var confirming = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                DatePicker("開始日", selection: $from, displayedComponents: .date)
                DatePicker("終了日", selection: $through, in: from..., displayedComponents: .date)
                ForEach(ChatGPTTransfer.Kind.allCases, id: \.self) { kind in
                    Toggle(kind.label, isOn: Binding(get: { kinds.contains(kind) }, set: { selected in
                        if selected { kinds.insert(kind) } else { kinds.remove(kind) }
                    }))
                }
                Button("ChatGPTに渡すファイルを書き出す", systemImage: "square.and.arrow.up", action: export)
                    .disabled(kinds.isEmpty)
            } header: {
                Text("My Timeのデータを渡す")
            } footer: {
                Text("選んだ種類と期間のデータを書き出し、ChatGPTのチャットに添付します。日時未定のタスクも含みます。共有前に内容を確認してください。")
            }
            Section {
                Button("JSONファイルを選ぶ", systemImage: "square.and.arrow.down") { importing = true }
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { read(Data(text.utf8)) }
                }
            } header: {
                Text("変更を読み込む")
            } footer: {
                Text("ChatGPTが作った変更や、TimeTree Companionで取得した予定のコピーを読み込めます。内容を確認してから、このiPhoneに反映します。")
            }
            if let preview {
                Section("反映前の確認") {
                    ForEach(preview.changes.indices, id: \.self) { index in
                        changeRow(preview.changes[index])
                    }
                    Button("変更を反映", systemImage: "checkmark.circle") { confirming = true }
                        .disabled(model.storeFailure != nil || preview.changes.allSatisfy(\.skipped))
                    Button("読み込みを取り消す", role: .cancel) { self.preview = nil }
                }
            }
        }
        .navigationTitle("ChatGPT・TimeTree連携")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: from) { _, date in if through < date { through = date } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                read(try handle.read(upToCount: ChatGPTTransfer.maxBytes + 1) ?? Data())
            } catch {
                preview = nil
                message = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "my-time-snapshot") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .confirmationDialog("My Timeに変更を反映しますか？", isPresented: $confirming, titleVisibility: .visible) {
            let deletes = preview?.changes.contains { $0.action == .delete } == true
            Button("反映する", role: deletes ? .destructive : nil, action: apply)
            Button("キャンセル", role: .cancel) {}
        }
        .alert("ChatGPT・TimeTree連携", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func export() {
        let start = Calendar.current.startOfDay(for: from)
        let last = Calendar.current.startOfDay(for: through)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return }
        let snapshot = ChatGPTTransfer.snapshot(model.repo, kinds: kinds,
            from: EpochMs(start.timeIntervalSince1970 * 1000), to: EpochMs(end.timeIntervalSince1970 * 1000))
        document = TransferDocument(text: snapshot.canonical)
        exporting = true
    }

    private func read(_ data: Data) {
        preview = nil
        do { preview = try ChatGPTTransfer.preview(data, in: model.repo) }
        catch { message = (error as? RepositoryError)?.description ?? error.localizedDescription }
    }

    private func apply() {
        guard let preview, model.storeFailure == nil else { return }
        var count = 0
        let saved = model.perform { count = try ChatGPTTransfer.apply(preview, to: model.repo) }
        if saved {
            message = "\(count)件を反映しました"
        }
        self.preview = nil
    }

    private func changeRow(_ change: ChatGPTTransfer.Change) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(change.value("title", afterChange: true)?.stringValue ?? change.value("title", afterChange: false)?.stringValue ?? "（無題）")
                .font(.headline)
            Text("\(change.kind.label) · \(actionLabel(change))")
                .foregroundStyle(change.action == .delete ? Color.red : Color.secondary)
            if change.affectsSeries { Text("繰り返し全体が対象です").foregroundStyle(.orange) }
            if change.action == .delete, change.kind == .task, change.relatedTasks > 0 {
                Text("サブタスク \(change.relatedTasks) 件も削除します").foregroundStyle(.red)
            }
            if !change.skipped {
                ForEach(rowFields(change), id: \.self) { key in
                    let before = fieldText(change, key, after: false)
                    let after = fieldText(change, key, after: true)
                    let text = change.action == .edit ? "\(before) → \(after)" : (change.action == .delete ? before : after)
                    LabeledContent(fieldName(key)) { Text(text).multilineTextAlignment(.trailing) }
                }
            }
        }
        .font(.subheadline)
    }

    private func rowFields(_ change: ChatGPTTransfer.Change) -> [String] {
        if change.action == .edit { return change.changedFields }
        let order = ["calendarId", "allDay", "start", "end", "plannedStart", "plannedEnd", "checkAt", "at",
                     "place", "location", "notes", "kind", "alarm", "notifyBefore", "repeat", "estimateMinutes", "color", "timeZone"]
        return order.filter { key in
            guard let value = change.value(key, afterChange: change.action != .delete) else { return false }
            return !value.isNull && value.stringValue != ""
        }
    }

    private func actionLabel(_ change: ChatGPTTransfer.Change) -> String {
        switch change.action {
        case .add: return "追加"
        case .edit: return "編集"
        case .delete: return "削除"
        case .copy: return change.skipped ? "取り込み済み" : "TimeTreeからコピー"
        }
    }

    private func fieldName(_ key: String) -> String {
        [
            "title": "タイトル", "notes": "メモ", "calendarId": "カレンダー", "start": "開始", "end": "終了",
            "plannedStart": "開始", "plannedEnd": "終了", "timeZone": "タイムゾーン", "allDay": "終日",
            "place": "場所", "location": "場所", "color": "色", "kind": "タスクの種類",
            "estimateMinutes": "見積時間（分）", "checkAt": "確認時刻", "at": "時刻",
            "alarm": "アラーム", "notifyBefore": "通知（分前）", "repeat": "繰り返し",
        ][key] ?? key
    }

    private func fieldText(_ change: ChatGPTTransfer.Change, _ key: String, after: Bool) -> String {
        guard let value = change.value(key, afterChange: after), !value.isNull else { return "なし" }
        if ["start", "end", "plannedStart", "plannedEnd", "checkAt", "at"].contains(key), let at = value.intValue {
            let allDay = change.value("allDay", afterChange: after)?.boolValue == true
            if allDay {
                let day = key == "end" ? at - 1 : at
                let zone = change.value("timeZone", afterChange: after)?.stringValue.flatMap(TimeZone.init(identifier:)) ?? .current
                return DomainTime(timeZone: zone).dayLabel(day)
            }
            return "\(model.time.dayLabel(at)) \(model.hm(at))"
        }
        if let flag = value.boolValue { return flag ? "オン" : "オフ" }
        if let text = value.stringValue {
            if key == "calendarId" { return model.calendar(text)?.name ?? text }
            if key == "repeat" { return ["daily": "毎日", "weekdays": "平日", "weekly": "毎週"][text] ?? text }
            if key == "kind" { return text == "check" ? "確認" : "実行" }
            return text.isEmpty ? "なし" : text
        }
        return value.canonical
    }
}
