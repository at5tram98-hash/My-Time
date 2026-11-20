import Foundation

/// My Time のローカルデータと、ChatGPT で作成した変更ファイルの受け渡し。
public enum ChatGPTTransfer {
    public enum Kind: String, CaseIterable, Hashable {
        case event, task, checkpoint

        public var label: String {
            switch self {
            case .event: return "予定"
            case .task: return "タスク"
            case .checkpoint: return "チェックポイント"
            }
        }

        fileprivate var fields: Set<String> {
            switch self {
            case .event: return ["title", "notes", "calendarId", "start", "end", "timeZone", "allDay", "place", "color"]
            case .task: return ["title", "notes", "calendarId", "plannedStart", "plannedEnd", "timeZone", "location", "estimateMinutes", "checkAt"]
            case .checkpoint: return ["title", "notes", "at", "alarm", "notifyBefore", "repeat"]
            }
        }
    }

    public enum Action: String {
        case add, edit, delete, copy
    }

    public struct Change: Equatable {
        public let kind: Kind
        public let action: Action
        public let id: String
        public let before: JSONValue?
        public let after: JSONValue?
        public let changedFields: [String]
        public let affectsSeries: Bool
        public let relatedTasks: Int
        public var skipped: Bool { action == .copy && after == nil }

        public func value(_ key: String, afterChange: Bool) -> JSONValue? {
            guard let record = afterChange ? after : before else { return nil }
            return ChatGPTTransfer.fields(kind, record)[key] ?? record[key]
        }
    }

    public struct Preview {
        public let changes: [Change]
        fileprivate let input: JSONValue
        fileprivate let preparedAt: EpochMs
    }

    public static let maxBytes = 2_000_000
    public static let checkpointsKey = "iosCheckpoints"
    private static let receiptsKey = "iosChatGPTAppliedFiles"
    private static let japan = TimeZone(identifier: "Asia/Tokyo")!

    /// 設定全体や操作履歴を含めず、選んだ種類と期間だけ書き出す。
    /// 日時未定のタスクは期間にかかわらず含める。
    public static func snapshot(_ repo: Repository, kinds: Set<Kind>, from: EpochMs, to: EpochMs) -> JSONValue {
        let records = activeRecords(repo)
        let calendars = repo.calendars().map { .object(["id": $0.id.json, "name": $0.name.json]) as JSONValue }
        var output: [String: JSONValue] = [
            "format": "my-time-snapshot-v1".json, "from": from.json, "to": to.json,
            "calendars": .array(calendars), "timeZone": TimeZone.current.identifier.json,
        ]
        for kind in Kind.allCases where kinds.contains(kind) {
            let items = (records[kind] ?? []).filter { record in
                switch kind {
                case .event:
                    if record["recurrence"]?.objectValue != nil {
                        return !expandAll([MTEvent(json: record)], from: from, to: to, time: .current).isEmpty
                    }
                    return (record["start"]?.intValue ?? to) < to && (record["end"]?.intValue ?? from) > from
                case .task:
                    guard let at = record["plannedStart"]?.intValue ?? record["checkAt"]?.intValue ?? record["extra"]?["onDay"]?.intValue else { return true }
                    let end = record["plannedEnd"]?.intValue ?? at + 1
                    return at < to && end > from
                case .checkpoint:
                    guard let at = record["at"]?.intValue else { return false }
                    return at < to && (at >= from || record["repeat"]?.stringValue != nil)
                }
            }.sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") }
            output[kind.rawValue] = .array(items.map { record in
                var summary = fields(kind, record)
                summary["id"] = record["id"]
                summary["revision"] = revision(record).json
                if kind == .task {
                    summary["kind"] = record["kind"]
                    summary["status"] = record["status"]
                    summary["checked"] = record["checked"]
                    summary["onDay"] = record["extra"]?["onDay"]
                }
                if kind == .event {
                    summary["recurrence"] = record["recurrence"]
                    summary["exceptions"] = record["exceptions"]
                }
                return .object(summary)
            })
        }
        return .object(output)
    }

    public static func preview(_ data: Data, in repo: Repository) throws -> Preview {
        guard data.count <= maxBytes else { throw RepositoryError("ファイルは2MBまでです") }
        // Foundation 側の深さ制限を先に適用してから既存の JSON 型で読む。
        _ = try JSONSerialization.jsonObject(with: data)
        let input = try JSONValue.parse(data)
        let now = repo.clock()
        return Preview(changes: try plan(input, repo, now), input: input, preparedAt: now)
    }

    /// 確認後に状態を再検証し、既存の保存口から一括反映する。
    @discardableResult
    public static func apply(_ preview: Preview, to repo: Repository) throws -> Int {
        var applied = 0
        try repo.store.transaction {
            let changes = try plan(preview.input, repo, preview.preparedAt)
            guard changes == preview.changes else { throw RepositoryError("確認後にデータが変わりました。ファイルを読み込み直してください") }
            for change in changes where !change.skipped {
                try write(change, repo)
                applied += 1
            }
            if applied > 0, preview.input["format"]?.stringValue == "my-time-changes-v1" {
                let receipt = revision(preview.input).json
                repo.updateSettings { settings in
                    let previous = settings.raw[receiptsKey]?.arrayValue ?? []
                    settings.raw = settings.raw.merging(.object([receiptsKey: .array(previous + [receipt])]))
                }
            }
        }
        return applied
    }

    private static func activeRecords(_ repo: Repository) -> [Kind: [JSONValue]] {
        [
            .event: repo.events().filter { !$0.isArchived }.map(\.raw),
            .task: repo.tasks().filter { !$0.isArchived }.map(\.raw),
            .checkpoint: repo.settings().raw[checkpointsKey]?.arrayValue ?? [],
        ]
    }

    private static func revision(_ record: JSONValue) -> String { SHA256.hex(record.canonical) }

    private static func fields(_ kind: Kind, _ record: JSONValue) -> [String: JSONValue] {
        var values = (record.objectValue ?? [:]).filter { kind.fields.contains($0.key) }
        if kind == .event {
            values["allDay"] = record["extra"]?["allDay"] ?? .bool(false)
            values["place"] = record["extra"]?["place"]?["name"]
            values["color"] = record["extra"]?["color"]
        }
        return values
    }

    private static func plan(_ input: JSONValue, _ repo: Repository, _ now: EpochMs) throws -> [Change] {
        let records = activeRecords(repo)
        let calendars = Set(repo.calendars().map(\.id))
        let changes: [Change]
        switch input["format"]?.stringValue {
        case "my-time-timetree-v1":
            guard let events = input["events"]?.arrayValue, (1...500).contains(events.count) else {
                throw RepositoryError("TimeTree の予定は1〜500件を指定してください")
            }
            let existing = repo.events()
            let ids = Set(existing.map(\.id))
            let sources = Set(existing.filter { $0.source?["type"]?.stringValue == "timetree" }.compactMap { $0.source?["externalId"]?.stringValue })
            changes = try events.enumerated().map { index, event in
                try row(index) { try timeTreeChange(event, now, calendars, ids, sources) }
            }
        case "my-time-changes-v1":
            guard let entries = input["changes"]?.arrayValue, (1...500).contains(entries.count) else {
                throw RepositoryError("変更は1〜500件を指定してください")
            }
            if (repo.settings().raw[receiptsKey]?.arrayValue ?? []).contains(revision(input).json) {
                throw RepositoryError("この変更ファイルは反映済みです")
            }
            let eventIDs = Set(repo.events().map(\.id))
            let tasks = repo.tasks()
            let taskIDs = Set(tasks.map(\.id))
            let subtasks = Dictionary(grouping: repo.subtasks(), by: \.taskId)
            let active = records.mapValues { Dictionary(grouping: $0, by: { $0["id"]?.stringValue ?? "" }) }
            changes = try entries.enumerated().map { index, entry in
                try row(index) {
                    guard let kind = Kind(rawValue: entry["kind"]?.stringValue ?? ""),
                          let action = Action(rawValue: entry["action"]?.stringValue ?? ""), action != .copy,
                          let id = entry["id"]?.stringValue, !id.isEmpty, id.count <= 500 else {
                        throw RepositoryError("種類・操作・IDを確認してください")
                    }
                    let current = active[kind]?[id]?.first
                    if action == .add {
                        guard UUID(uuidString: id) != nil, current == nil, !(kind == .event && eventIDs.contains(id)),
                              !(kind == .task && taskIDs.contains(id)) else { throw RepositoryError("新規追加には未使用のUUIDを指定してください") }
                    } else {
                        guard let current, entry["revision"]?.stringValue == revision(current) else {
                            throw RepositoryError("対象が見つからないか書き出し後に変わりました。先に書き出し直してください")
                        }
                    }
                    let affectsSeries = kind == .event && current?["recurrence"]?.objectValue != nil
                        || kind == .checkpoint && current?["repeat"]?.stringValue != nil
                    if action != .add, affectsSeries, entry["wholeSeries"]?.boolValue != true {
                        throw RepositoryError("繰り返し全体を変更する場合は wholeSeries を true にしてください")
                    }
                    let related = kind == .task ? subtasks[id]?.count ?? 0 : 0
                    if action == .delete {
                        guard entry["fields"] == nil else { throw RepositoryError("削除に変更項目は指定できません") }
                        return Change(kind: kind, action: action, id: id, before: current, after: nil, changedFields: [], affectsSeries: affectsSeries, relatedTasks: related)
                    }
                    guard let patch = entry["fields"]?.objectValue, !patch.isEmpty, Set(patch.keys).isSubset(of: kind == .task && action == .add ? kind.fields.union(["kind"]) : kind.fields) else {
                        throw RepositoryError("変更項目が空か、対応していない項目が含まれています")
                    }
                    let next = try updated(kind, id, current, patch, now, calendars)
                    return Change(kind: kind, action: action, id: id, before: current, after: next, changedFields: patch.keys.sorted(), affectsSeries: affectsSeries, relatedTasks: related)
                }
            }
        default:
            throw RepositoryError("My Time の変更ファイルまたは TimeTree のコピー用ファイルを選んでください")
        }
        let targets = changes.map { "\($0.kind.rawValue):\($0.id)" }
        guard Set(targets).count == targets.count else { throw RepositoryError("同じ項目がファイル内に複数あります") }
        return changes
    }

    private static func row(_ index: Int, _ build: () throws -> Change) throws -> Change {
        do { return try build() }
        catch { throw RepositoryError("\(index + 1)件目　\(error)") }
    }

    private static func updated(_ kind: Kind, _ id: String, _ current: JSONValue?,
                                _ patch: [String: JSONValue], _ now: EpochMs, _ calendars: Set<String>) throws -> JSONValue {
        var extra = current?["extra"]?.objectValue ?? [:]
        var values = patch
        for (key, value) in patch {
            try validate(key, value, calendars)
            switch key {
            case "place":
                var place = extra["place"]?.objectValue ?? [:]
                if let name = value.stringValue {
                    if place["name"]?.stringValue != name { place = ["name": name.json] }
                    extra["place"] = .object(place)
                } else { extra.removeValue(forKey: "place") }
                values.removeValue(forKey: key)
            case "allDay", "color":
                extra[key] = value.isNull ? nil : value
                values.removeValue(forKey: key)
            default: break
            }
        }
        let initial: JSONValue
        switch kind {
        case .event:
            initial = MTEvent.make(title: "", calendarId: MTCalendar.selfId, start: 0, end: 0, now: now, id: id).json
            if !extra.isEmpty || current?["extra"]?.objectValue != nil { values["extra"] = .object(extra) }
            if current == nil, patch["start"] == nil || patch["end"] == nil { throw RepositoryError("開始と終了を指定してください") }
        case .task: initial = MTTask.make(title: "", now: now, id: id).json
        case .checkpoint:
            initial = .object(["id": id.json, "title": "".json, "notes": "".json, "alarm": .bool(false)])
        }
        let next = (current ?? initial).merging(.object(values))
        guard let title = next["title"]?.stringValue,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else {
            throw RepositoryError("タイトルは1〜200文字で入力してください")
        }
        switch kind {
        case .event:
            guard let start = next["start"]?.intValue, let end = next["end"]?.intValue, start < end else {
                throw RepositoryError("終了は開始より後にしてください")
            }
        case .task:
            let start = next["plannedStart"]?.intValue
            let end = next["plannedEnd"]?.intValue
            if patch["plannedStart"] != nil || patch["plannedEnd"] != nil,
               (start == nil) != (end == nil) || (start ?? 0) >= (end ?? 1) {
                throw RepositoryError("タスクの予定時刻は開始と終了を組で指定してください")
            }
            if patch["checkAt"] != nil, next["checkAt"]?.intValue != nil, next["kind"]?.stringValue != "check" {
                throw RepositoryError("確認時刻は確認タスクにだけ指定できます")
            }
        case .checkpoint:
            guard next["at"]?.intValue != nil else { throw RepositoryError("チェックポイントの時刻を指定してください") }
        }
        return next
    }

    private static func validate(_ key: String, _ value: JSONValue, _ calendars: Set<String>) throws {
        let valid: Bool
        switch key {
        case "title": valid = value.stringValue != nil
        case "kind": valid = TaskKind(rawValue: value.stringValue ?? "") != nil
        case "notes": valid = (value.stringValue?.count ?? 20_001) <= 20_000
        case "calendarId": valid = value.stringValue.map(calendars.contains) ?? false
        case "timeZone": valid = value.stringValue.flatMap(TimeZone.init(identifier:)) != nil
        case "start", "end", "at": valid = timestamp(value)
        case "plannedStart", "plannedEnd", "checkAt": valid = value.isNull || timestamp(value)
        case "alarm", "allDay": valid = value.boolValue != nil
        case "location", "place": valid = value.isNull || (value.stringValue?.count ?? 501) <= 500
        case "color": valid = value.isNull || (value.stringValue?.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil)
        case "repeat": valid = value.isNull || ["daily", "weekdays", "weekly"].contains(value.stringValue ?? "")
        case "notifyBefore": valid = value.isNull || value.intValue.map { (0...1440).contains($0) } == true
        case "estimateMinutes": valid = value.isNull || value.intValue.map { (1...10_000).contains($0) } == true
        default: valid = false
        }
        guard valid else { throw RepositoryError("\(key) の値が正しくありません") }
    }

    private static func timestamp(_ value: JSONValue) -> Bool {
        value.intValue.map { (-2_208_988_800_000...7_258_118_400_000).contains($0) } ?? false
    }

    private static func timeTreeChange(_ source: JSONValue, _ now: EpochMs, _ calendars: Set<String>,
                                       _ existingIDs: Set<String>, _ existingSources: Set<String>) throws -> Change {
        guard let eventID = source["id"]?.stringValue, !eventID.isEmpty, eventID.count <= 200,
              let calendarID = (source["calendarId"] ?? source["calendar_id"])?.stringValue, !calendarID.isEmpty, calendarID.count <= 200,
              let title = source["title"], let allDay = source["allDay"]?.boolValue,
              let startText = source["start"]?.stringValue, let endText = source["end"]?.stringValue else {
            throw RepositoryError("TimeTree の予定に必要な項目がありません")
        }
        let iso = ISO8601DateFormatter()
        let zone = source["timezone"]?.stringValue.flatMap(TimeZone.init(identifier:)) ?? japan
        let displayZone = allDay && (source["timezone"]?.stringValue == "UTC" || zone.identifier == "GMT") ? japan : zone
        let start: EpochMs
        let end: EpochMs
        if allDay {
            // Companion の終日予定は UTC 午前0時で日付を表す。日付を現地の午前0時に置き直す。
            let dateOnly = DateFormatter()
            dateOnly.calendar = Calendar(identifier: .gregorian)
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.timeZone = displayZone
            dateOnly.dateFormat = "yyyy-MM-dd"
            guard let first = dateOnly.date(from: String(startText.prefix(10))),
                  let last = dateOnly.date(from: String(endText.prefix(10))) else {
                throw RepositoryError("終日予定の日付を確認してください")
            }
            start = milliseconds(first)
            end = milliseconds(last)
        } else {
            func parse(_ text: String) -> Date? {
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: text) { return date }
                iso.formatOptions = [.withInternetDateTime]
                return iso.date(from: text)
            }
            guard let first = parse(startText), let last = parse(endText) else {
                throw RepositoryError("開始と終了はタイムゾーン付きの ISO 8601 日時にしてください")
            }
            start = milliseconds(first)
            end = milliseconds(last)
        }
        let key = revision(.array([calendarID.json, eventID.json]))
        let id = "tt-companion-" + key
        let externalID = "\(calendarID):\(eventID)"
        if existingIDs.contains(id) || existingSources.contains(externalID) {
            return Change(kind: .event, action: .copy, id: id, before: .object(["title": title]), after: nil,
                          changedFields: [], affectsSeries: false, relatedTasks: 0)
        }
        let owners = source["owners"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let belongsToMio = source["owner"]?.stringValue == "mio" || owners == ["mio"]
        let target = source["myTimeCalendarId"]?.stringValue ?? (belongsToMio ? MTCalendar.mioId : MTCalendar.selfId)
        var patch = ["title": title, "start": start.json, "end": end.json, "allDay": allDay.json,
                     "calendarId": target.json, "timeZone": displayZone.identifier.json]
        patch["notes"] = (source["description"] ?? source["notes"])?.stringValue?.json
        patch["place"] = source["location"]?.stringValue?.json ?? source["location"]?["name"]?.stringValue?.json
        let color = (source["color"] ?? source["label"]?["color"])?.stringValue
        if let color, color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil { patch["color"] = color.json }

        var event = MTEvent(json: try updated(.event, id, nil, patch, now, calendars))
        event.source = .object(["type": "timetree".json, "externalId": externalID.json, "fingerprint": key.json,
                                "owner": (belongsToMio ? "partner" : "me").json, "calendarName": source["calendarName"] ?? .null])
        let metadataKeys: Set<String> = ["id", "calendarId", "calendar_id", "calendarName", "participants",
                                         "owners", "owner", "parent_id", "label", "color", "location"]
        let metadata = (source.objectValue ?? [:]).filter { metadataKeys.contains($0.key) }
        event.extra = (event.extra ?? .object([:])).merging(.object(["timeTree": .object(metadata)]))
        if let place = source["location"], place["name"]?.stringValue != nil {
            let mapped = (place.objectValue ?? [:]).filter { ["name", "address", "lat", "lng"].contains($0.key) }
            event.extra = event.extra?.merging(.object(["place": .object(mapped)]))
        }
        return Change(kind: .event, action: .copy, id: id, before: nil, after: event.json,
                      changedFields: patch.keys.sorted(), affectsSeries: false, relatedTasks: 0)
    }

    private static func milliseconds(_ date: Date) -> EpochMs {
        EpochMs((date.timeIntervalSince1970 * 1_000).rounded())
    }

    public static func updateCheckpoint(_ value: JSONValue?, id: String, settings: inout AppSettings) {
        var points = settings.raw[checkpointsKey]?.arrayValue ?? []
        points.removeAll { $0["id"]?.stringValue == id }
        if let value { points.append(value) }
        settings.raw = settings.raw.merging(.object([checkpointsKey: .array(points)]))
    }

    private static func write(_ change: Change, _ repo: Repository) throws {
        switch (change.kind, change.after) {
        case (.event, .some(let value)): try repo.saveEvent(MTEvent(json: value), isNew: change.before == nil)
        case (.event, .none): try repo.deleteEvent(change.id)
        case (.task, .some(let value)): try repo.saveTask(MTTask(json: value), isNew: change.before == nil)
        case (.task, .none): try repo.deleteTask(change.id)
        case (.checkpoint, let value):
            repo.updateSettings { settings in
                updateCheckpoint(value, id: change.id, settings: &settings)
            }
        }
    }
}
