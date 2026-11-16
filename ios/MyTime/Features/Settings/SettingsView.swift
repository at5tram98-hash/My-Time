import SwiftUI
import UniformTypeIdentifiers
import MyTimeCore

/// 設定。表示・データの移行（Web 版と同じ「端末間移行ファイル」）・この端末の状態
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var pending: DeviceTransfer.File?
    @State private var exportDoc: TransferDocument?
    @State private var exporting = false
    @State private var icsDoc: ICSDocument?
    @State private var exportingICS = false

    private func setNotify(_ on: Bool) {
        guard on else { model.setNotifications(enabled: false); return }
        Task { @MainActor in
            if await NotificationScheduler.requestAuthorization() {
                model.setNotifications(enabled: true)
            } else {
                model.errorMessage = "通知が許可されていません。iPhone の「設定 › 通知 › My Time」で許可してください。"
            }
        }
    }

    /// その他タブの中に入れるとき（ナビゲーションと「完了」は外側に任せる）
    var embedded = false

    var body: some View {
        OptionalNavigationStack(embedded: embedded) {
            Form {
                Section("表示") {
                    Picker("外観", selection: Binding(get: { model.settings.theme }, set: { v in model.updateSettings { $0.theme = v } })) {
                        Text("システムに合わせる").tag("system")
                        Text("ライト").tag("light")
                        Text("ダーク").tag("dark")
                    }
                }
                Section {
                    Button("移行ファイルを書き出す", systemImage: "square.and.arrow.up") {
                        exportDoc = TransferDocument(text: DeviceTransfer.export(store: model.repo.store, now: model.now))
                        exporting = true
                    }
                    Button("移行ファイルを読み込む", systemImage: "square.and.arrow.down") { importing = true }
                } header: {
                    Text("データの移行")
                } footer: {
                    Text("Web 版の「設定 › 端末間の移行」と同じ形式です。読み込みは追加だけで、この端末のデータを消したり上書きしたりしません。同じファイルを2回読み込んでも重複しません。")
                }
                Section {
                    Toggle("通知", isOn: Binding(get: { model.notificationsEnabled }, set: setNotify))
                    if model.notificationsEnabled {
                        Picker("予定の通知", selection: Binding(get: { model.notifyMinutesBefore }, set: { model.setNotifications(minutes: $0) })) {
                            ForEach([0, 5, 10, 15, 30, 60], id: \.self) { Text($0 == 0 ? "開始時刻" : "\($0)分前").tag($0) }
                        }
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("予定（移動時間があるときは出発の時刻）、タスクを始める時刻、確認の時刻、締切の3時間前に、この iPhone から知らせます。7日先まで予約します。")
                }
                Section {
                    Stepper("活動の始まり \(model.settings.suggestFromHour)時", value: Binding(get: { model.settings.suggestFromHour }, set: { v in model.updateSettings { $0.suggestFromHour = v } }), in: 0...12)
                    Stepper("活動の終わり \(model.settings.suggestToHour)時", value: Binding(get: { model.settings.suggestToHour }, set: { v in model.updateSettings { $0.suggestToHour = v } }), in: 13...24)
                } header: {
                    Text("計画の支援")
                } footer: {
                    Text("空き時間を探す・余白を数えるときの時間帯です（Web 版と共通の設定）。")
                }
                Section {
                    NavigationLink { HistoryView() } label: { Label("操作履歴", systemImage: "clock.arrow.circlepath") }
                    Button("カレンダー（.ics）に書き出す", systemImage: "calendar.badge.plus") {
                        icsDoc = ICSDocument(text: exportICS(events: model.events, tasks: model.tasks, now: model.now))
                        exportingICS = true
                    }
                    .fileExporter(isPresented: $exportingICS, document: icsDoc, contentType: .calendarEvent, defaultFilename: "my-time") { result in
                        if case .failure(let e) = result { model.errorMessage = e.localizedDescription } else { model.toast = AppModel.Toast(text: "書き出しました") }
                    }
                } footer: {
                    Text(".ics はカレンダー App や Google カレンダーに読み込めます。My Time からほかのカレンダーへ自動で書き込むことはしません。")
                }
                Section("この端末") {
                    LabeledContent("タスク", value: "\(model.tasks.count)件")
                    LabeledContent("予定", value: "\(model.events.count)件")
                    LabeledContent("同期待ちの変更", value: "\(model.outboxPending)件")
                }
                Section {
                    Label("クラウド同期・Google ログイン・Drive バックアップ", systemImage: "icloud.slash")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("iOS 版ではまだ使えません。変更はこの端末に保存され、同期用の記録（Web 版と同じ形）にためています。今は移行ファイルで Web 版とやり取りできます。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): read(url)
                case .failure(let e): model.errorMessage = e.localizedDescription
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json, defaultFilename: "my-time-transfer-\(model.time.dayLabel(model.now).replacingOccurrences(of: "/", with: "-"))") { result in
                if case .failure(let e) = result { model.errorMessage = e.localizedDescription } else { model.toast = AppModel.Toast(text: "書き出しました") }
            }
            .sheet(item: Binding(get: { pending.map(PendingImport.init) }, set: { if $0 == nil { pending = nil } })) { p in
                ImportConfirmView(file: p.file) { pending = nil }
                    .environment(model)
            }
        }
    }

    private func read(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= DeviceTransfer.maxBytes else { throw DeviceTransfer.TransferError("ファイルが大きすぎます（50MBまで）") }
            guard let text = String(data: data, encoding: .utf8) else { throw DeviceTransfer.TransferError("文字コードが UTF-8 ではありません") }
            pending = try DeviceTransfer.read(text)
        } catch {
            model.errorMessage = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
    }
}

private struct PendingImport: Identifiable {
    var file: DeviceTransfer.File
    var id: String { file.sha256 }
}

/// 取り込む前に中身の件数を見せ、確認してから追加する
struct ImportConfirmView: View {
    var file: DeviceTransfer.File
    var onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var done = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("作成元", value: file.origin)
                    LabeledContent("作成日時", value: "\(model.time.dayLabel(file.createdAt)) \(model.hm(file.createdAt))")
                    LabeledContent("確認", value: "改ざんなし（SHA-256 一致）")
                }
                Section("含まれるデータ") {
                    ForEach(file.summary, id: \.0) { name, n in LabeledContent(name, value: "\(n)件") }
                }
                Section {
                    Button("追加する", systemImage: "plus.circle.fill") {
                        let f = file
                        var added = 0
                        let ok = model.perform { added = try DeviceTransfer.importAddOnly(f, into: model.repo.store, now: model.now, newId: model.repo.newId) }
                        if ok {
                            done += 1
                            model.toast = AppModel.Toast(text: added == 0 ? "すでに読み込み済みです（変更なし）" : "\(added)件を追加しました")
                            onClose()
                        }
                    }
                } footer: {
                    Text("この端末のデータは消えません。同じIDで内容の違うデータがあるときは、何も変えずに中止します。")
                }
            }
            .navigationTitle("読み込みの確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル", action: onClose) } }
            .sensoryFeedback(.success, trigger: done)
        }
    }
}

/// 書き出し用の ICS 文書
struct ICSDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.calendarEvent] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 書き出し用の JSON 文書
struct TransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
