import Foundation

/// 保存先の抽象。iOS アプリでは SwiftData、テストではメモリ上の実装を使う。
/// 1件ずつの JSON をそのまま保存する（Web 版の IndexedDB と同じ形。iOS がまだ知らない項目も失わない）。
public protocol RecordStore: AnyObject {
    func all(_ entity: EntityName) -> [JSONValue]
    func get(_ entity: EntityName, id: String) -> JSONValue?
    func put(_ entity: EntityName, id: String, json: JSONValue)
    func delete(_ entity: EntityName, id: String)
    /// 操作ログ（Web 版 operationLog と同じ形）
    func appendLog(_ entry: JSONValue)
    func logs() -> [JSONValue]
    /// 未同期キュー（Web 版 outbox と同じ形。同期を実装したときにそのまま送れる）
    func appendOutbox(_ entry: JSONValue)
    func outbox() -> [JSONValue]
    func settings() -> JSONValue?
    func putSettings(_ value: JSONValue)
    /// まとめて保存（失敗したら途中の変更を残さない）
    func transaction(_ body: () throws -> Void) throws
}

/// メモリ上の保存先（テスト・プレビュー用）
public final class InMemoryStore: RecordStore {
    private var tables: [EntityName: [String: JSONValue]] = [:]
    private var log: [JSONValue] = []
    private var queue: [JSONValue] = []
    private var app: JSONValue?
    public init() {}
    public func all(_ e: EntityName) -> [JSONValue] { Array((tables[e] ?? [:]).values) }
    public func get(_ e: EntityName, id: String) -> JSONValue? { tables[e]?[id] }
    public func put(_ e: EntityName, id: String, json: JSONValue) { tables[e, default: [:]][id] = json }
    public func delete(_ e: EntityName, id: String) { tables[e]?[id] = nil }
    public func appendLog(_ entry: JSONValue) { log.append(entry) }
    public func logs() -> [JSONValue] { log }
    public func appendOutbox(_ entry: JSONValue) { queue.append(entry) }
    public func outbox() -> [JSONValue] { queue }
    public func settings() -> JSONValue? { app }
    public func putSettings(_ value: JSONValue) { app = value }
    public func transaction(_ body: () throws -> Void) throws {
        let snapshot = (tables, log, queue, app)
        do { try body() } catch { (tables, log, queue, app) = snapshot; throw error }
    }
}

public struct RepositoryError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// 書き込みの唯一の入口（Web 版 repo.ts と同じ考え方）。
/// 1回の操作＝1トランザクション（本体＋操作ログ＋未同期キュー）。
public final class Repository {
    public let store: RecordStore
    public var clock: () -> EpochMs
    public var newId: () -> String
    public init(store: RecordStore, clock: @escaping () -> EpochMs = { EpochMs(Date().timeIntervalSince1970 * 1000) }, newId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.store = store; self.clock = clock; self.newId = newId
    }

    // MARK: 読み取り

    public func calendars() -> [MTCalendar] { store.all(.calendar).map(MTCalendar.init).sorted { $0.order < $1.order } }
    public func events() -> [MTEvent] { store.all(.event).map(MTEvent.init) }
    public func tasks() -> [MTTask] { store.all(.task).map(MTTask.init) }
    public func subtasks() -> [MTSubtask] { store.all(.subtask).map(MTSubtask.init).sorted { $0.order < $1.order } }
    public func employers() -> [MTEmployer] { store.all(.employer).map(MTEmployer.init).sorted { $0.name < $1.name } }
    public func task(_ id: String) -> MTTask? { store.get(.task, id: id).map(MTTask.init) }
    public func event(_ id: String) -> MTEvent? { store.get(.event, id: id).map(MTEvent.init) }

    // MARK: 記録

    func record(_ entity: EntityName, _ id: String, op: String, action: String, detail: [String: JSONValue]? = nil) {
        let at = clock()
        var log: [String: JSONValue] = ["id": newId().json, "at": at.json, "entity": entity.rawValue.json, "entityId": id.json, "action": action.json]
        if let detail { log["detail"] = .object(detail) }
        store.appendLog(.object(log))
        store.appendOutbox(.object(["opId": newId().json, "at": at.json, "entity": entity.rawValue.json, "entityId": id.json, "op": op.json, "synced": .number(0)]))
    }

    /// 既定のカレンダーは空のときだけ作る（既存のデータは上書きしない）
    public func ensureDefaults() throws {
        try store.transaction {
            if store.all(.calendar).isEmpty { for c in MTCalendar.defaults(now: clock()) { store.put(.calendar, id: c.id, json: c.json) } }
        }
    }

    // MARK: タスク

    public func saveTask(_ task: MTTask, isNew: Bool) throws {
        var t = task
        t.updatedAt = clock()
        try validate(t)
        try store.transaction {
            if t.eventId != nil, store.all(.subtask).contains(where: { $0["taskId"]?.stringValue == t.id }) { throw RepositoryError("予定に内包されるタスクはサブタスクを持てません") }
            let prev = isNew ? nil : store.get(.task, id: t.id)
            store.put(.task, id: t.id, json: t.json)
            record(.task, t.id, op: "put", action: isNew ? "create" : "update", detail: prev.map { ["snapshot": $0] })
        }
    }

    public func deleteTask(_ id: String) throws {
        try store.transaction {
            let prev = store.get(.task, id: id)
            let subs = store.all(.subtask).filter { $0["taskId"]?.stringValue == id }
            for s in subs { if let sid = s["id"]?.stringValue { store.delete(.subtask, id: sid) } }
            store.delete(.task, id: id)
            var d: [String: JSONValue] = ["subtasks": .number(Double(subs.count))]
            if let prev { d["snapshot"] = prev; d["subtasksSnapshot"] = .array(subs) }
            record(.task, id, op: "delete", action: "delete", detail: d)
        }
    }

    public func taskAction(_ id: String, _ action: TaskAction) throws {
        guard let t = task(id) else { throw RepositoryError("タスクが見つかりません") }
        try apply(try applyTaskAction(t, action, at: clock()))
    }

    public func toggleCheck(_ id: String) throws {
        guard let t = task(id) else { throw RepositoryError("タスクが見つかりません") }
        try apply(try MyTimeCore.toggleCheck(t, at: clock()))
    }

    public func recordProgress(_ id: String, value: Double) throws {
        guard let t = task(id) else { throw RepositoryError("タスクが見つかりません") }
        try apply(try recordManualProgress(t, subtasks: subtasks().filter { $0.taskId == id }, value: value, at: clock()))
    }

    /// 100% で確認後の完了：実績100%を記録してから終了（1トランザクション）
    public func completeFromProgress(_ id: String) throws {
        guard var t = task(id) else { throw RepositoryError("タスクが見つかりません") }
        let now = clock()
        try store.transaction {
            var trs: [TaskTransition] = []
            let p = try recordManualProgress(t, subtasks: [], value: 1, at: now); trs.append(p); t = p.task
            if t.status == .notStarted { let s = try applyTaskAction(t, .start, at: now); trs.append(s); t = s.task }
            if t.status == .paused { let s = try applyTaskAction(t, .resume, at: now); trs.append(s); t = s.task }
            let f = try applyTaskAction(t, .finish, at: now); trs.append(f)
            for tr in trs { write(tr) }
        }
    }

    private func apply(_ tr: TaskTransition) throws {
        try store.transaction { write(tr) }
    }

    private func write(_ tr: TaskTransition) {
        store.put(.task, id: tr.task.id, json: tr.task.json)
        var d = tr.detail
        d["from"] = tr.from.rawValue.json
        d["to"] = tr.to.rawValue.json
        record(.task, tr.task.id, op: "put", action: tr.action, detail: d)
    }

    // MARK: サブタスク

    public func addSubtask(taskId: String, title: String) throws {
        guard let t = task(taskId) else { throw RepositoryError("タスクが見つかりません") }
        guard canAddSubtask(t) else { throw RepositoryError("このタスクにはサブタスクを追加できません") }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RepositoryError("名前を入力してください") }
        try store.transaction {
            let order = Int64(store.all(.subtask).filter { $0["taskId"]?.stringValue == taskId }.count)
            let s = MTSubtask.make(taskId: taskId, title: title, order: order, now: clock(), id: newId())
            store.put(.subtask, id: s.id, json: s.json)
            record(.subtask, s.id, op: "put", action: "create", detail: ["taskId": taskId.json])
        }
    }

    public func toggleSubtask(_ id: String) throws {
        guard var s = store.get(.subtask, id: id).map(MTSubtask.init) else { throw RepositoryError("サブタスクが見つかりません") }
        let now = clock()
        s.done.toggle(); s.completedAt = s.done ? now : nil; s.updatedAt = now
        try store.transaction {
            store.put(.subtask, id: id, json: s.json)
            record(.subtask, id, op: "put", action: s.done ? "complete" : "uncomplete", detail: ["taskId": s.taskId.json])
        }
    }

    public func deleteSubtask(_ id: String) throws {
        try store.transaction { store.delete(.subtask, id: id); record(.subtask, id, op: "delete", action: "delete") }
    }

    // MARK: 予定

    public func saveEvent(_ event: MTEvent, isNew: Bool) throws {
        var e = event
        e.updatedAt = clock()
        guard !e.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw RepositoryError("タイトルを入力してください") }
        guard e.end > e.start else { throw RepositoryError("終了は開始より後にしてください") }
        try store.transaction {
            let prev = isNew ? nil : store.get(.event, id: e.id)
            store.put(.event, id: e.id, json: e.json)
            record(.event, e.id, op: "put", action: isNew ? "create" : "update", detail: prev.map { ["snapshot": $0] })
        }
    }

    /// 時間軸の移動（呼び出し側で15分刻みにそろえる）。長さは保つ
    public func moveEvent(_ id: String, newStart: EpochMs) throws {
        guard var e = event(id) else { throw RepositoryError("予定が見つかりません") }
        let prev = e.json
        let len = e.end - e.start
        e.start = newStart; e.end = newStart + len; e.updatedAt = clock()
        try store.transaction { store.put(.event, id: id, json: e.json); record(.event, id, op: "put", action: "move", detail: ["from": prev["start"] ?? .null, "to": newStart.json, "snapshot": prev]) }
    }

    public func moveTask(_ id: String, newStart: EpochMs) throws {
        guard var t = task(id), let s = t.plannedStart, let e = t.plannedEnd else { throw RepositoryError("予定時刻がありません") }
        let prev = t.json
        t.plannedStart = newStart; t.plannedEnd = newStart + (e - s); t.updatedAt = clock()
        try store.transaction { store.put(.task, id: id, json: t.json); record(.task, id, op: "put", action: "move", detail: ["from": s.json, "to": newStart.json, "snapshot": prev]) }
    }

    /// 上端・下端をつかんだ伸縮（呼び出し側で15分刻みにそろえる）
    public func resizeEvent(_ id: String, start: EpochMs, end: EpochMs) throws {
        guard var e = event(id) else { throw RepositoryError("予定が見つかりません") }
        guard end > start else { throw RepositoryError("終了は開始より後にしてください") }
        let prev = e.json
        e.start = start; e.end = end; e.updatedAt = clock()
        try store.transaction { store.put(.event, id: id, json: e.json); record(.event, id, op: "put", action: "resize", detail: ["from": .object(["start": prev["start"] ?? .null, "end": prev["end"] ?? .null]), "to": .object(["start": start.json, "end": end.json]), "snapshot": prev]) }
    }

    public func resizeTask(_ id: String, start: EpochMs, end: EpochMs) throws {
        guard var t = task(id), t.plannedStart != nil else { throw RepositoryError("予定時刻がありません") }
        guard end > start else { throw RepositoryError("終了は開始より後にしてください") }
        let prev = t.json
        t.plannedStart = start; t.plannedEnd = end; t.updatedAt = clock()
        try store.transaction { store.put(.task, id: id, json: t.json); record(.task, id, op: "put", action: "resize", detail: ["from": .object(["start": prev["plannedStart"] ?? .null, "end": prev["plannedEnd"] ?? .null]), "to": .object(["start": start.json, "end": end.json]), "snapshot": prev]) }
    }

    /// 繰り返しの「この回のみ」の時刻変更（Web 版 editThisOccurrence と同じ：override の例外。ほかの回・元の予定は変えない）
    public func editOccurrence(masterId: String, originalStart: EpochMs, start: EpochMs, end: EpochMs) throws {
        guard var m = event(masterId), m.recurrence != nil else { throw RepositoryError("予定が見つかりません") }
        guard end > start else { throw RepositoryError("終了は開始より後にしてください") }
        let prevOverride = m.exceptions.first { $0.originalStart == originalStart && $0.kind == .override }
        var x = prevOverride ?? RecurrenceException(originalStart: originalStart, kind: .override)
        x.kind = .override; x.start = start; x.end = end
        m.exceptions.removeAll { $0.originalStart == originalStart }
        m.exceptions.append(x)
        m.updatedAt = clock()
        try store.transaction { store.put(.event, id: masterId, json: m.json); record(.event, masterId, op: "put", action: "occurrence-edit", detail: ["originalStart": originalStart.json]) }
    }

    public func deleteEvent(_ id: String) throws {
        try store.transaction {
            let prev = store.get(.event, id: id)
            store.delete(.event, id: id)
            record(.event, id, op: "delete", action: "delete", detail: prev.map { ["snapshot": $0] })
        }
    }

    /// 繰り返しの「この回のみ」削除（その回を取り消しの例外にする。ほかの回は残す）
    public func cancelOccurrence(masterId: String, originalStart: EpochMs) throws {
        guard var m = event(masterId), m.recurrence != nil else { throw RepositoryError("予定が見つかりません") }
        m.exceptions.removeAll { $0.originalStart == originalStart }
        m.exceptions.append(RecurrenceException(originalStart: originalStart, kind: .cancelled))
        m.updatedAt = clock()
        try store.transaction { store.put(.event, id: masterId, json: m.json); record(.event, masterId, op: "put", action: "occurrence-cancel", detail: ["originalStart": originalStart.json]) }
    }

    // MARK: 設定

    public func settings() -> AppSettings { AppSettings(json: store.settings()) }
    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = settings()
        change(&s)
        store.putSettings(s.json)
    }

    private func validate(_ t: MTTask) throws {
        guard !t.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw RepositoryError("タイトルを入力してください") }
        guard t.title.count <= 200 else { throw RepositoryError("タイトルは200文字までです") }
        if let s = t.plannedStart, let e = t.plannedEnd, e <= s { throw RepositoryError("終了は開始より後にしてください") }
        if let m = t.estimateMinutes, !(1...10_000).contains(m) { throw RepositoryError("見積は1〜10000分で入力してください") }
    }
}

/// アプリの設定（Web 版 AppSettings と同じキー。iOS が使わない項目も元のまま残す）
public struct AppSettings: Equatable, Sendable {
    public var raw: JSONValue
    public init(json: JSONValue?) { raw = json ?? .object(["key": "app".json]) }
    public var json: JSONValue { raw.merging(.object(["key": "app".json])) }
    private func get(_ k: String) -> JSONValue? { raw[k] }
    private mutating func set(_ k: String, _ v: JSONValue) { raw = raw.merging(.object([k: v])) }

    public var theme: String { get { get("theme")?.stringValue ?? "system" } set { set("theme", newValue.json) } }
    public var onboarded: Bool { get { get("onboarded")?.boolValue ?? false } set { set("onboarded", newValue.json) } }
    /// 今日の画面のレーン：both / main / detail
    public var laneFocus: String { get { get("laneFocus")?.stringValue ?? "both" } set { set("laneFocus", newValue.json) } }
    public var calendarView: String { get { get("calendarView")?.stringValue ?? "2day" } set { set("calendarView", newValue.json) } }
    public var suggestFromHour: Int { get { Int(get("suggestFromHour")?.intValue ?? 7) } set { set("suggestFromHour", .number(Double(newValue))) } }
    public var suggestToHour: Int { get { Int(get("suggestToHour")?.intValue ?? 23) } set { set("suggestToHour", .number(Double(newValue))) } }
    /// 使った場所の履歴（Web 版と同じ形：{ name, address, lat, lng }。新しい順・20件まで）
    public var placeHistory: [JSONValue] { get { get("placeHistory")?.arrayValue ?? [] } set { set("placeHistory", .array(Array(newValue.prefix(20)))) } }
}
