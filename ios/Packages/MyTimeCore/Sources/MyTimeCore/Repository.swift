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

    /// 人（カレンダー）ごとの表示・非表示。予定は消さず、隠すだけ（Web 版の visible と同じ項目）
    public func setCalendarVisible(_ id: String, _ visible: Bool) throws {
        guard var c = calendars().first(where: { $0.id == id }) else { throw RepositoryError("カレンダーが見つかりません") }
        guard c.visible != visible else { return }
        c.visible = visible; c.updatedAt = clock()
        try store.transaction { store.put(.calendar, id: id, json: c.json); record(.calendar, id, op: "put", action: visible ? "show" : "hide") }
    }

    /// カレンダーを「自分」「みお」の2つにまとめる（何度呼んでも同じ結果）。
    /// 授業・アルバイトのカレンダーの予定は「自分」へ移し、見分けられるよう種類（大学の授業・勤務シフト）を付ける。
    /// 名前が「みお」のカレンダー（取り込みなど）の予定は「みお」へ移す。ほかのカレンダーは消す（予定は消さない）
    @discardableResult
    public func consolidateCalendars() throws -> (moved: Int, removed: Int) {
        let now = clock()
        let cals = calendars()
        let keep: Set<String> = [MTCalendar.selfId, MTCalendar.mioId]
        if Set(cals.map(\.id)) == keep, cals.first(where: { $0.id == MTCalendar.selfId })?.name == "自分" { return (0, 0) }
        var moved = 0, removed = 0
        let byId = Dictionary(cals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func target(_ id: String?) -> String? {
            guard let id, !keep.contains(id) else { return nil }
            return byId[id]?.name.trimmingCharacters(in: .whitespaces) == "みお" ? MTCalendar.mioId : MTCalendar.selfId
        }
        try store.transaction {
            for d in MTCalendar.defaults(now: now) {
                if var c = byId[d.id] {
                    c.name = d.name
                    c.kind = .general; c.order = d.order; c.visible = true; c.updatedAt = now
                    store.put(.calendar, id: c.id, json: c.json)
                } else {
                    store.put(.calendar, id: d.id, json: d.json)
                }
            }
            for var e in events() {
                guard let to = target(e.calendarId) else { continue }
                let kind = byId[e.calendarId]?.kind
                if e.specType == nil, kind == .class || kind == .job {
                    var o = e.extra?.objectValue ?? [:]
                    var sp = o["spec"]?.objectValue ?? [:]
                    sp["type"] = .string(kind == .class ? SpecTypeId.class.rawValue : SpecTypeId.shift.rawValue)
                    if sp["details"] == nil { sp["details"] = .object([:]) }
                    o["spec"] = .object(sp)
                    e.extra = .object(o)
                }
                e.calendarId = to
                e.updatedAt = now
                store.put(.event, id: e.id, json: e.json)
                record(.event, e.id, op: "put", action: "moveCalendar")
                moved += 1
            }
            for var t in tasks() {
                guard let to = target(t.calendarId) else { continue }
                t.calendarId = to
                t.updatedAt = now
                store.put(.task, id: t.id, json: t.json)
                moved += 1
            }
            for c in cals where !keep.contains(c.id) {
                store.delete(.calendar, id: c.id)
                record(.calendar, c.id, op: "delete", action: "consolidate")
                removed += 1
            }
        }
        return (moved, removed)
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

    /// `byUser`：人が消したとき true。自動で置いた朝を人が消したら、その日はもう自動で置かない
    public func deleteTask(_ id: String, byUser: Bool = true) throws {
        if byUser, let t = task(id), t.isAutoMorning, let d = MorningAuto.dayKey(t) {
            updateSettings { s in
                var xs = (s.raw["autoMorningSkip"]?.arrayValue ?? []).compactMap(\.intValue).filter { $0 >= d - 30 * DAY }
                if !xs.contains(d) { xs.append(d) }
                s.raw = s.raw.merging(.object(["autoMorningSkip": .array(xs.map { .number(Double($0)) })]))
            }
        }
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

    func saveSubtask(_ subtask: MTSubtask) throws {
        guard let parent = task(subtask.taskId), canAddSubtask(parent) else {
            throw RepositoryError("このタスクにはサブタスクを追加できません")
        }
        let previous = store.get(.subtask, id: subtask.id).map(MTSubtask.init)
        guard previous == nil || previous?.taskId == subtask.taskId else {
            throw RepositoryError("別のタスクに同じサブタスクIDがあります")
        }
        var child = subtask
        child.updatedAt = clock()
        try store.transaction {
            store.put(.subtask, id: child.id, json: child.json)
            record(.subtask, child.id, op: "put", action: previous == nil ? "create" : "update", detail: ["taskId": child.taskId.json])
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
    public func editOccurrence(masterId: String, originalStart: EpochMs, start: EpochMs, end: EpochMs, title: String? = nil, notes: String? = nil, overrides: [String: JSONValue] = [:]) throws {
        guard var m = event(masterId), m.recurrence != nil else { throw RepositoryError("予定が見つかりません") }
        guard end > start else { throw RepositoryError("終了は開始より後にしてください") }
        let prevOverride = m.exceptions.first { $0.originalStart == originalStart && $0.kind == .override }
        var x = prevOverride ?? RecurrenceException(originalStart: originalStart, kind: .override)
        x.kind = .override; x.start = start; x.end = end
        if let title { x.title = title }
        if let notes { x.notes = notes }
        if !overrides.isEmpty {
            let previous = x.raw["mcpOverrides"] ?? .object([:])
            x.raw = x.raw.merging(.object(["mcpOverrides": previous.merging(.object(overrides))]))
        }
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

    /// 自動削除：片づけ（画面から外して archivedAt を付ける）と完全削除を1つのトランザクションで。
    /// 1件でも失敗したら全部やめる（途中まで消えた状態にしない）
    public func applyCleanup(archiveEvents: [String], archiveTasks: [String], purgeEvents: [String], purgeTasks: [String], at: EpochMs) throws {
        func mark(_ x: JSONValue?) -> JSONValue { (x ?? .object([:])).merging(.object(["archivedAt": .number(Double(at))])) }
        try store.transaction {
            for id in archiveEvents {
                guard var e = event(id) else { throw RepositoryError("予定が見つかりません") }
                e.extra = mark(e.extra); e.updatedAt = clock()
                store.put(.event, id: id, json: e.json)
                record(.event, id, op: "put", action: "archive")
            }
            for id in archiveTasks {
                guard let raw = store.get(.task, id: id) else { throw RepositoryError("タスクが見つかりません") }
                var t = MTTask(json: raw)
                t.extra = mark(t.extra); t.updatedAt = clock()
                store.put(.task, id: id, json: t.json)
                record(.task, id, op: "put", action: "archive")
            }
            for id in purgeEvents {
                let prev = store.get(.event, id: id)
                store.delete(.event, id: id)
                record(.event, id, op: "delete", action: "purge", detail: prev.map { ["snapshot": $0] })
            }
            for id in purgeTasks {
                let subs = store.all(.subtask).filter { $0["taskId"]?.stringValue == id }
                for sub in subs { if let sid = sub["id"]?.stringValue { store.delete(.subtask, id: sid) } }
                store.delete(.task, id: id)
                record(.task, id, op: "delete", action: "purge")
            }
        }
    }

    /// 片づけた予定・タスクを元に戻す（1つのトランザクション）
    public func restoreArchived(events: [String], tasks: [String]) throws {
        func unmark(_ x: JSONValue?) -> JSONValue? {
            guard var o = x?.objectValue else { return x }
            o["archivedAt"] = nil
            return .object(o)
        }
        try store.transaction {
            for id in events { if var e = event(id) { e.extra = unmark(e.extra); store.put(.event, id: id, json: e.json); record(.event, id, op: "put", action: "restore") } }
            for id in tasks { if let raw = store.get(.task, id: id) { var t = MTTask(json: raw); t.extra = unmark(t.extra); store.put(.task, id: id, json: t.json); record(.task, id, op: "put", action: "restore") } }
        }
    }

    /// 取り消し・取り消しの解除。originalStart を渡すと繰り返しのその回だけ（例外に印を付ける）
    public func setStruck(eventId: String, originalStart: EpochMs?, struck: Bool) throws {
        guard var m = event(eventId) else { throw RepositoryError("予定が見つかりません") }
        let prev = store.get(.event, id: eventId)
        if let s = originalStart, m.recurrence != nil {
            if let i = m.exceptions.firstIndex(where: { $0.originalStart == s }) {
                guard m.exceptions[i].kind == .override else { throw RepositoryError("この回は削除されています") }
                m.exceptions[i].raw = m.exceptions[i].raw.merging(.object(["struck": .bool(struck)]))
            } else if struck {
                var x = RecurrenceException(originalStart: s, kind: .override)
                x.raw = .object(["struck": .bool(true)])
                m.exceptions.append(x)
            }
        } else {
            var o = m.extra?.objectValue ?? [:]
            o["struck"] = struck ? .bool(true) : nil
            m.extra = .object(o)
        }
        m.updatedAt = clock()
        try store.transaction {
            store.put(.event, id: eventId, json: m.json)
            record(.event, eventId, op: "put", action: struck ? "strike" : "unstrike", detail: prev.map { ["snapshot": $0] })
        }
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
