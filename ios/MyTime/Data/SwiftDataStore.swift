import Foundation
import SwiftData
import MyTimeCore

/// 予定・タスクなどの1件。Web 版と同じ JSON をそのまま保存する（iOS 版が知らない項目も消さない）。
@Model
final class StoredRecord {
    /// `${entity}:${id}`
    @Attribute(.unique) var key: String
    var entity: String
    var recordId: String
    var json: Data
    var updatedAt: Date

    init(entity: String, recordId: String, json: Data) {
        key = "\(entity):\(recordId)"
        self.entity = entity
        self.recordId = recordId
        self.json = json
        updatedAt = .now
    }
}

/// 操作ログ（Web 版 operationLog と同じ JSON）。seq は端末内の順番
@Model
final class StoredLog {
    var seq: Int
    var json: Data
    init(seq: Int, json: Data) { self.seq = seq; self.json = json }
}

/// 未同期キュー（Web 版 outbox と同じ JSON）。同期を実装したときにそのまま送る
@Model
final class StoredOutbox {
    var seq: Int
    var json: Data
    init(seq: Int, json: Data) { self.seq = seq; self.json = json }
}

/// アプリの設定（Web 版 AppSettings と同じ JSON。1件だけ）
@Model
final class StoredSettings {
    @Attribute(.unique) var key: String
    var json: Data
    init(json: Data) { key = "app"; self.json = json }
}

enum MyTimeSchema {
    static let models: [any PersistentModel.Type] = [StoredRecord.self, StoredLog.self, StoredOutbox.self, StoredSettings.self]

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration("MyTime", isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: config)
    }
}

/// MyTimeCore の RecordStore を SwiftData で実装したもの。
/// 書き込みは `transaction` の中でまとめて保存し、途中で失敗したら変更を巻き戻す。
final class SwiftDataStore: RecordStore {
    let context: ModelContext
    private var inTransaction = false

    init(context: ModelContext) {
        self.context = context
        context.autosaveEnabled = false
    }

    private func decode(_ data: Data) -> JSONValue? { try? JSONValue.parse(data) }

    private func record(_ entity: EntityName, _ id: String) -> StoredRecord? {
        let key = "\(entity.rawValue):\(id)"
        var d = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    func all(_ entity: EntityName) -> [JSONValue] {
        let name = entity.rawValue
        let d = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.entity == name })
        return ((try? context.fetch(d)) ?? []).compactMap { decode($0.json) }
    }

    func get(_ entity: EntityName, id: String) -> JSONValue? { record(entity, id).flatMap { decode($0.json) } }

    func put(_ entity: EntityName, id: String, json: JSONValue) {
        if let r = record(entity, id) {
            r.json = json.data
            r.updatedAt = .now
        } else {
            context.insert(StoredRecord(entity: entity.rawValue, recordId: id, json: json.data))
        }
        saveIfNeeded()
    }

    func delete(_ entity: EntityName, id: String) {
        if let r = record(entity, id) { context.delete(r) }
        saveIfNeeded()
    }

    private func nextSeq<T: PersistentModel>(_ type: T.Type, _ key: KeyPath<T, Int>) -> Int {
        var d = FetchDescriptor<T>(sortBy: [SortDescriptor(key, order: .reverse)])
        d.fetchLimit = 1
        return ((try? context.fetch(d))?.first.map { $0[keyPath: key] } ?? 0) + 1
    }

    func appendLog(_ entry: JSONValue) {
        context.insert(StoredLog(seq: nextSeq(StoredLog.self, \.seq), json: entry.data))
        saveIfNeeded()
    }

    func logs() -> [JSONValue] {
        ((try? context.fetch(FetchDescriptor<StoredLog>(sortBy: [SortDescriptor(\.seq)]))) ?? []).compactMap { decode($0.json) }
    }

    func appendOutbox(_ entry: JSONValue) {
        context.insert(StoredOutbox(seq: nextSeq(StoredOutbox.self, \.seq), json: entry.data))
        saveIfNeeded()
    }

    func outbox() -> [JSONValue] {
        ((try? context.fetch(FetchDescriptor<StoredOutbox>(sortBy: [SortDescriptor(\.seq)]))) ?? []).compactMap { decode($0.json) }
    }

    func settings() -> JSONValue? {
        var d = FetchDescriptor<StoredSettings>()
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first.flatMap { decode($0.json) }
    }

    func putSettings(_ value: JSONValue) {
        var d = FetchDescriptor<StoredSettings>()
        d.fetchLimit = 1
        if let s = (try? context.fetch(d))?.first { s.json = value.data } else { context.insert(StoredSettings(json: value.data)) }
        saveIfNeeded()
    }

    func transaction(_ body: () throws -> Void) throws {
        if inTransaction { try body(); return }
        inTransaction = true
        defer { inTransaction = false }
        do {
            try body()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func saveIfNeeded() {
        if !inTransaction { try? context.save() }
    }
}
