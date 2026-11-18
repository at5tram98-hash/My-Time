import Foundation

/// 絶対時刻は Web 版と同じ UTC の epoch ミリ秒
public typealias EpochMs = Int64

/// 同期・移行でやり取りするエンティティ（Web 版 `ENTITY_NAMES` と同じ順・同じ名前）
public enum EntityName: String, CaseIterable, Sendable, Codable {
    case calendar, event, task, subtask, subject, employer, category, studioType
    /// Web 版 IndexedDB の表名（移行ファイルの tables のキー）
    public var table: String {
        switch self {
        case .calendar: return "calendars"
        case .event: return "events"
        case .task: return "tasks"
        case .subtask: return "subtasks"
        case .subject: return "subjects"
        case .employer: return "employers"
        case .category: return "categories"
        case .studioType: return "studioTypes"
        }
    }
}

// MARK: - 読み書きの補助（Web 版のスキーマは null を「値なし」として必ずキーを持つ）

struct Obj {
    let o: [String: JSONValue]
    init(_ v: JSONValue) { o = v.objectValue ?? [:] }
    func str(_ k: String, _ d: String = "") -> String { o[k]?.stringValue ?? d }
    func optStr(_ k: String) -> String? { o[k]?.stringValue }
    func int(_ k: String, _ d: Int64 = 0) -> Int64 { o[k]?.intValue ?? d }
    func optInt(_ k: String) -> Int64? { o[k]?.intValue }
    func num(_ k: String, _ d: Double = 0) -> Double { o[k]?.doubleValue ?? d }
    func bool(_ k: String, _ d: Bool = false) -> Bool { o[k]?.boolValue ?? d }
    func raw(_ k: String) -> JSONValue? { guard let v = o[k], !v.isNull else { return nil }; return v }
    func strs(_ k: String) -> [String] { (o[k]?.arrayValue ?? []).compactMap { $0.stringValue } }
}

extension Optional where Wrapped == Int64 { var json: JSONValue { map { .number(Double($0)) } ?? .null } }
extension Optional where Wrapped == String { var json: JSONValue { map { .string($0) } ?? .null } }
extension Optional where Wrapped == JSONValue { var json: JSONValue { self ?? .null } }
extension Int64 { var json: JSONValue { .number(Double(self)) } }
extension String { var json: JSONValue { .string(self) } }
extension Bool { var json: JSONValue { .bool(self) } }

/// JSON と相互変換できる記録。`raw` は受け取った元の JSON（知らない項目を保存時に残すため）
public protocol Record: Identifiable, Equatable, Sendable where ID == String {
    static var entity: EntityName { get }
    var id: String { get }
    var raw: JSONValue { get }
    init(json: JSONValue)
    /// iOS 版が知っている項目だけの JSON
    var knownJSON: JSONValue { get }
}

public extension Record {
    /// 保存する JSON：元の JSON（知らない項目を含む）に、知っている項目を上書き
    var json: JSONValue { raw.merging(knownJSON) }
}

// MARK: - カレンダー

public enum CalendarKind: String, Sendable, CaseIterable { case general, `class`, job }

public struct MTCalendar: Record {
    public static let entity = EntityName.calendar
    public var id: String
    public var name: String
    public var color: String
    public var icon: String
    public var kind: CalendarKind
    public var studioTypeId: String?
    public var visible: Bool
    public var order: Int64
    public var createdAt: EpochMs
    public var updatedAt: EpochMs
    public var raw: JSONValue

    public init(json: JSONValue) {
        let r = Obj(json)
        id = r.str("id"); name = r.str("name", "カレンダー"); color = r.str("color", "#0A84FF"); icon = r.str("icon", "calendar")
        kind = CalendarKind(rawValue: r.str("kind")) ?? .general
        studioTypeId = r.optStr("studioTypeId"); visible = r.bool("visible", true); order = r.int("order")
        createdAt = r.int("createdAt"); updatedAt = r.int("updatedAt"); raw = json
    }

    public var knownJSON: JSONValue {
        var o: [String: JSONValue] = ["id": id.json, "name": name.json, "color": color.json, "icon": icon.json, "kind": kind.rawValue.json, "visible": visible.json, "order": order.json, "createdAt": createdAt.json, "updatedAt": updatedAt.json]
        if studioTypeId != nil || raw["studioTypeId"] != nil { o["studioTypeId"] = studioTypeId.json }
        return .object(o)
    }

    /// カレンダーは「自分」と「みお」の2つ（自分は Web 版の一般と同じ ID なので、往復で重複しない）
    public static let selfId = "cal-general"
    public static let mioId = "cal-mio"
    public static func defaults(now: EpochMs) -> [MTCalendar] {
        [(selfId, "自分", "#0A84FF", "person", 0), (mioId, "みお", "#FF2D55", "heart", 1)].map {
            MTCalendar(json: .object(["id": $0.0.json, "name": $0.1.json, "color": $0.2.json, "icon": $0.3.json, "kind": "general".json, "visible": .bool(true), "order": .number(Double($0.4)), "createdAt": now.json, "updatedAt": now.json]))
        }
    }
}

// MARK: - 予定

public enum RecurrenceFreq: String, Sendable { case daily, weekly, monthly }

public struct RecurrenceRule: Equatable, Sendable {
    public var freq: RecurrenceFreq
    public var interval: Int
    public var byWeekday: [Int]?
    public var until: EpochMs?
    public init(freq: RecurrenceFreq, interval: Int = 1, byWeekday: [Int]? = nil, until: EpochMs? = nil) { self.freq = freq; self.interval = interval; self.byWeekday = byWeekday; self.until = until }
    init?(_ v: JSONValue?) {
        guard let v, let f = RecurrenceFreq(rawValue: Obj(v).str("freq")) else { return nil }
        let r = Obj(v)
        freq = f; interval = Int(r.int("interval", 1)); until = r.optInt("until")
        byWeekday = r.raw("byWeekday")?.arrayValue?.compactMap { $0.intValue.map(Int.init) }
    }
    var json: JSONValue { .object(["freq": freq.rawValue.json, "interval": .number(Double(interval)), "byWeekday": byWeekday.map { .array($0.map { .number(Double($0)) }) } ?? .null, "until": until.json]) }
}

public struct RecurrenceException: Equatable, Sendable {
    public enum Kind: String, Sendable { case override, cancelled, archived }
    public var originalStart: EpochMs
    public var kind: Kind
    public var start: EpochMs?
    public var end: EpochMs?
    public var title: String?
    public var notes: String?
    public var raw: JSONValue
    init(_ v: JSONValue) {
        let r = Obj(v)
        originalStart = r.int("originalStart"); kind = Kind(rawValue: r.str("kind")) ?? .override
        start = r.optInt("start"); end = r.optInt("end"); title = r.optStr("title"); notes = r.optStr("notes"); raw = v
    }
    public init(originalStart: EpochMs, kind: Kind, start: EpochMs? = nil, end: EpochMs? = nil, title: String? = nil) {
        self.originalStart = originalStart; self.kind = kind; self.start = start; self.end = end; self.title = title; notes = nil; raw = .object([:])
    }
    var json: JSONValue {
        var o: [String: JSONValue] = ["originalStart": originalStart.json, "kind": kind.rawValue.json]
        if let start { o["start"] = start.json }
        if let end { o["end"] = end.json }
        if let title { o["title"] = title.json }
        if let notes { o["notes"] = notes.json }
        return raw.merging(.object(o))
    }
}

public struct MTEvent: Record {
    public static let entity = EntityName.event
    public var id: String
    public var title: String
    public var calendarId: String
    public var start: EpochMs
    public var end: EpochMs
    public var timeZone: String
    public var notes: String
    public var recurrence: RecurrenceRule?
    public var exceptions: [RecurrenceException]
    /// 授業の情報（科目・教室・課題・小テスト）。iOS 版では表示のみなので元の JSON のまま持つ
    public var classInfo: JSONValue?
    public var employerId: String?
    public var hideAfterEnd: Bool
    /// 取り込み元（TimeTree など）。元の JSON のまま
    public var source: JSONValue?
    public var extra: JSONValue?
    public var createdAt: EpochMs
    public var updatedAt: EpochMs
    public var raw: JSONValue

    public init(json: JSONValue) {
        let r = Obj(json)
        id = r.str("id"); title = r.str("title", "（無題）"); calendarId = r.str("calendarId", "cal-general")
        start = r.int("start"); end = r.int("end", r.int("start") + 3_600_000)
        timeZone = r.str("timeZone", TimeZone.current.identifier); notes = r.str("notes")
        recurrence = RecurrenceRule(r.raw("recurrence"))
        exceptions = (r.raw("exceptions")?.arrayValue ?? []).map(RecurrenceException.init)
        classInfo = r.raw("classInfo"); employerId = r.optStr("employerId"); hideAfterEnd = r.bool("hideAfterEnd")
        source = r.raw("source"); extra = r.raw("extra")
        createdAt = r.int("createdAt"); updatedAt = r.int("updatedAt"); raw = json
    }

    public var knownJSON: JSONValue {
        var o: [String: JSONValue] = [
            "id": id.json, "title": title.json, "calendarId": calendarId.json, "start": start.json, "end": end.json, "timeZone": timeZone.json, "notes": notes.json,
            "recurrence": recurrence?.json ?? .null, "exceptions": .array(exceptions.map(\.json)), "classInfo": classInfo.json, "employerId": employerId.json,
            "hideAfterEnd": hideAfterEnd.json, "source": source.json, "createdAt": createdAt.json, "updatedAt": updatedAt.json,
        ]
        if let extra { o["extra"] = extra }
        return .object(o)
    }

    public var allDay: Bool { extra?["allDay"]?.boolValue ?? false }
    public var travelMinutes: Int? { extra?["travelMinutes"]?.intValue.map(Int.init) }
    public var placeName: String? { extra?["place"]?["name"]?.stringValue }
    public var colorOverride: String? { extra?["color"]?.stringValue }
}

/// 繰り返しを展開した1回分（ID は Web 版と同じ `マスターID@規則上の開始`）
public struct EventOccurrence: Identifiable, Equatable, Sendable {
    public var id: String
    public var masterId: String
    public var originalStart: EpochMs?
    public var event: MTEvent
    public var start: EpochMs
    public var end: EpochMs
    public var title: String
    public var isOccurrence: Bool { originalStart != nil }
}

// MARK: - タスク

public enum TaskKind: String, Sendable, CaseIterable { case `do`, check }
public enum TaskStatus: String, Sendable, CaseIterable { case notStarted, running, paused, done }

public struct WorkInterval: Equatable, Sendable {
    public var start: EpochMs
    public var end: EpochMs?
    public init(start: EpochMs, end: EpochMs?) { self.start = start; self.end = end }
    var json: JSONValue { .object(["start": start.json, "end": end.json]) }
}

public struct ProgressSample: Equatable, Sendable {
    public var value: Double
    public var at: EpochMs
    public var workedMsAtSample: Double
    var json: JSONValue { .object(["value": .number(value), "at": at.json, "workedMsAtSample": .number(workedMsAtSample)]) }
}

public struct MTTask: Record {
    public static let entity = EntityName.task
    public var id: String
    public var title: String
    public var kind: TaskKind
    public var special: String
    public var assignment: JSONValue?
    public var testPrep: JSONValue?
    public var sourceEventId: String?
    public var sourceKey: String?
    public var estimateMinutes: Int?
    public var priority: Int
    public var tags: [String]
    public var flagged: Bool
    public var notifyMinutesBefore: Int?
    public var location: String?
    public var repeatRule: JSONValue?
    public var autoStartAt: EpochMs?
    public var autoEndAt: EpochMs?
    public var icon: String
    public var calendarId: String?
    public var category: String?
    public var eventId: String?
    public var plannedStart: EpochMs?
    public var plannedEnd: EpochMs?
    public var timeZone: String
    public var status: TaskStatus
    public var intervals: [WorkInterval]
    public var actualStart: EpochMs?
    public var actualEnd: EpochMs?
    public var manualProgress: ProgressSample?
    public var pausedEver: Bool
    public var autoReserved: Bool
    public var checkAt: EpochMs?
    public var checked: Bool
    public var checkedAt: EpochMs?
    public var notes: String
    public var extra: JSONValue?
    public var createdAt: EpochMs
    public var updatedAt: EpochMs
    public var raw: JSONValue

    public init(json: JSONValue) {
        let r = Obj(json)
        id = r.str("id"); title = r.str("title", "（無題）")
        kind = TaskKind(rawValue: r.str("kind")) ?? .do
        special = r.str("special", "normal"); assignment = r.raw("assignment"); testPrep = r.raw("testPrep")
        sourceEventId = r.optStr("sourceEventId"); sourceKey = r.optStr("sourceKey")
        estimateMinutes = r.optInt("estimateMinutes").map(Int.init); priority = Int(r.int("priority"))
        tags = r.strs("tags"); flagged = r.bool("flagged"); notifyMinutesBefore = r.optInt("notifyMinutesBefore").map(Int.init)
        location = r.optStr("location"); repeatRule = r.raw("repeat")
        autoStartAt = r.optInt("autoStartAt"); autoEndAt = r.optInt("autoEndAt")
        icon = r.str("icon", "book"); calendarId = r.optStr("calendarId"); category = r.optStr("category"); eventId = r.optStr("eventId")
        plannedStart = r.optInt("plannedStart"); plannedEnd = r.optInt("plannedEnd"); timeZone = r.str("timeZone", TimeZone.current.identifier)
        status = TaskStatus(rawValue: r.str("status")) ?? .notStarted
        intervals = (r.raw("intervals")?.arrayValue ?? []).map { WorkInterval(start: Obj($0).int("start"), end: Obj($0).optInt("end")) }
        actualStart = r.optInt("actualStart"); actualEnd = r.optInt("actualEnd")
        manualProgress = r.raw("manualProgress").map { ProgressSample(value: Obj($0).num("value"), at: Obj($0).int("at"), workedMsAtSample: Obj($0).num("workedMsAtSample")) }
        pausedEver = r.bool("pausedEver"); autoReserved = r.bool("autoReserved")
        checkAt = r.optInt("checkAt"); checked = r.bool("checked"); checkedAt = r.optInt("checkedAt"); notes = r.str("notes")
        extra = r.raw("extra"); createdAt = r.int("createdAt"); updatedAt = r.int("updatedAt"); raw = json
    }

    public var knownJSON: JSONValue {
        var o: [String: JSONValue] = [
            "id": id.json, "title": title.json, "kind": kind.rawValue.json, "special": special.json, "assignment": assignment.json, "testPrep": testPrep.json,
            "sourceEventId": sourceEventId.json, "sourceKey": sourceKey.json, "estimateMinutes": estimateMinutes.map { .number(Double($0)) } ?? .null,
            "priority": .number(Double(priority)), "tags": .array(tags.map(\.json)), "flagged": flagged.json,
            "notifyMinutesBefore": notifyMinutesBefore.map { .number(Double($0)) } ?? .null, "location": location.json, "repeat": repeatRule.json,
            "autoStartAt": autoStartAt.json, "autoEndAt": autoEndAt.json, "icon": icon.json, "calendarId": calendarId.json, "category": category.json,
            "eventId": eventId.json, "plannedStart": plannedStart.json, "plannedEnd": plannedEnd.json, "timeZone": timeZone.json, "status": status.rawValue.json,
            "intervals": .array(intervals.map(\.json)), "actualStart": actualStart.json, "actualEnd": actualEnd.json, "manualProgress": manualProgress?.json ?? .null,
            "pausedEver": pausedEver.json, "autoReserved": autoReserved.json, "checkAt": checkAt.json, "checked": checked.json, "checkedAt": checkedAt.json,
            "notes": notes.json, "createdAt": createdAt.json, "updatedAt": updatedAt.json,
        ]
        if let extra { o["extra"] = extra }
        return .object(o)
    }

    /// Web 版 `makeTask()` と同じ既定値で新しいタスクを作る
    public static func make(title: String, kind: TaskKind = .do, now: EpochMs, id: String = UUID().uuidString.lowercased(), timeZone: String = TimeZone.current.identifier) -> MTTask {
        MTTask(json: .object(["id": id.json, "title": title.json, "kind": kind.rawValue.json, "special": "normal".json, "priority": .number(0), "tags": .array([]),
                              "flagged": .bool(false), "icon": "book".json, "timeZone": timeZone.json, "status": "notStarted".json, "intervals": .array([]),
                              "pausedEver": .bool(false), "autoReserved": .bool(false), "checked": .bool(false), "notes": "".json, "createdAt": now.json, "updatedAt": now.json]))
    }

    public var specType: SpecTypeId? { SpecTypeId(rawValue: extra?["spec"]?["type"]?.stringValue ?? "") ?? (special == "assignment" ? .assignment : special == "testPrep" ? .exam : nil) }
    public var isDone: Bool { status == .done || checked }
    public var travelMinutes: Int? { extra?["travelMinutes"]?.intValue.map(Int.init) }
    public var deadline: EpochMs? {
        extra?["spec"]?["details"]?["dueAt"]?.intValue ?? assignment?["deadline"]?.intValue ?? testPrep?["examAt"]?.intValue
    }
}

public extension MTEvent {
    /// Web 版 `makeEvent()` と同じ既定値で新しい予定を作る
    static func make(title: String, calendarId: String, start: EpochMs, end: EpochMs, now: EpochMs, id: String = UUID().uuidString.lowercased(), timeZone: String = TimeZone.current.identifier) -> MTEvent {
        MTEvent(json: .object(["id": id.json, "title": title.json, "calendarId": calendarId.json, "start": start.json, "end": end.json, "timeZone": timeZone.json,
                               "notes": "".json, "recurrence": .null, "exceptions": .array([]), "classInfo": .null, "employerId": .null, "hideAfterEnd": .bool(false), "source": .null,
                               "createdAt": now.json, "updatedAt": now.json]))
    }
    var specType: SpecTypeId? { SpecTypeId(rawValue: extra?["spec"]?["type"]?.stringValue ?? "") }
}

// MARK: - サブタスク・科目・勤務先・カテゴリー・Studio の種類

public struct MTSubtask: Record {
    public static let entity = EntityName.subtask
    public var id: String
    public var taskId: String
    public var title: String
    public var done: Bool
    public var completedAt: EpochMs?
    public var order: Int64
    public var plannedStart: EpochMs?
    public var plannedEnd: EpochMs?
    public var estimateMinutes: Int?
    public var createdAt: EpochMs
    public var updatedAt: EpochMs
    public var raw: JSONValue
    public init(json: JSONValue) {
        let r = Obj(json)
        id = r.str("id"); taskId = r.str("taskId"); title = r.str("title"); done = r.bool("done"); completedAt = r.optInt("completedAt"); order = r.int("order")
        plannedStart = r.optInt("plannedStart"); plannedEnd = r.optInt("plannedEnd"); estimateMinutes = r.optInt("estimateMinutes").map(Int.init)
        createdAt = r.int("createdAt"); updatedAt = r.int("updatedAt"); raw = json
    }
    public var knownJSON: JSONValue {
        var o: [String: JSONValue] = ["id": id.json, "taskId": taskId.json, "title": title.json, "done": done.json, "completedAt": completedAt.json, "order": order.json, "createdAt": createdAt.json, "updatedAt": updatedAt.json]
        // 旧データ（項目なし）には書き足さない
        if plannedStart != nil || raw["plannedStart"] != nil { o["plannedStart"] = plannedStart.json }
        if plannedEnd != nil || raw["plannedEnd"] != nil { o["plannedEnd"] = plannedEnd.json }
        if estimateMinutes != nil || raw["estimateMinutes"] != nil { o["estimateMinutes"] = estimateMinutes.map { .number(Double($0)) } ?? .null }
        return .object(o)
    }
    public static func make(taskId: String, title: String, order: Int64, now: EpochMs, id: String = UUID().uuidString.lowercased()) -> MTSubtask {
        MTSubtask(json: .object(["id": id.json, "taskId": taskId.json, "title": title.json, "done": .bool(false), "completedAt": .null, "order": order.json, "createdAt": now.json, "updatedAt": now.json]))
    }
}

/// 名前と既定の項目だけの記録（科目・勤務先・カテゴリー・Studio の種類）。中身は元の JSON のまま扱う
public struct GenericRecord: Record {
    public static let entity = EntityName.subject
    public var id: String
    public var raw: JSONValue
    public init(json: JSONValue) { id = Obj(json).str("id"); raw = json }
    public var knownJSON: JSONValue { raw }
    public var name: String { raw["name"]?.stringValue ?? "" }
}

public struct MTEmployer: Record {
    public static let entity = EntityName.employer
    public var id: String
    public var name: String
    public var reminderHours: Double
    public var createdAt: EpochMs
    public var updatedAt: EpochMs
    public var raw: JSONValue
    public init(json: JSONValue) {
        let r = Obj(json)
        id = r.str("id"); name = r.str("name"); reminderHours = r.num("reminderHours", 2); createdAt = r.int("createdAt"); updatedAt = r.int("updatedAt"); raw = json
    }
    public var knownJSON: JSONValue { .object(["id": id.json, "name": name.json, "reminderHours": .number(reminderHours), "createdAt": createdAt.json, "updatedAt": updatedAt.json]) }
}
