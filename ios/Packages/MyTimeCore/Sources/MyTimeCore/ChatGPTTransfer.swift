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
            case .event:
                return Set(["title", "notes", "calendarId", "start", "end", "timeZone", "recurrence", "hideAfterEnd",
                        "employerId", "subjectName", "room"]).union(extraFields)
            case .task:
                return Set(["title", "notes", "calendarId", "plannedStart", "plannedEnd", "timeZone", "kind",
                        "location", "estimateMinutes", "checkAt", "flagged", "priority", "tags", "icon", "category",
                        "notifyMinutesBefore", "autoStartAt", "autoEndAt", "eventId", "checked", "repeat"]).union(extraFields)
            case .checkpoint:
                return ["title", "notes", "at", "alarm", "notifyBefore", "repeat"]
            }
        }

        fileprivate var extraFields: Set<String> {
            let common: Set<String> = ["color", "place", "travelMinutes", "meetingUrl", "notifies", "urls", "spec", "studio", "bring"]
            switch self {
            case .event: return common.union(["allDay", "shiftPending"])
            case .task: return common.union(["onDay", "alarm"])
            case .checkpoint: return []
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
        public var occurrenceStart: EpochMs? = nil
        public var subtaskUpdates: [JSONValue]? = nil
        public var skipped: Bool { action == .copy && after == nil }

        public func value(_ key: String, afterChange: Bool) -> JSONValue? {
            guard let record = afterChange ? after : before else { return nil }
            if key == "progress" { return record[key] ?? record["manualProgress"]?["value"] }
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
        let subtasks = Dictionary(grouping: repo.subtasks(), by: \.taskId)
        let calendars = repo.calendars().map { .object(["id": $0.id.json, "name": $0.name.json]) as JSONValue }
        let employers = repo.employers().map { .object(["id": $0.id.json, "name": $0.name.json]) as JSONValue }
        let studioTypes = repo.studioTypes().map {
            .object(["id": $0.id.json, "name": $0.name.json, "version": .number(Double($0.version)), "target": $0.target.json]) as JSONValue
        }
        var output: [String: JSONValue] = [
            "format": "my-time-snapshot-v1".json, "editVersion": .number(2), "from": from.json, "to": to.json,
            "calendars": .array(calendars), "employers": .array(employers), "studioTypes": .array(studioTypes),
            "timeZone": TimeZone.current.identifier.json,
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
                let children = subtasks[record["id"]?.stringValue ?? ""] ?? []
                summary["revision"] = recordRevision(kind, record, children).json
                if kind == .task {
                    summary["subtasks"] = .array(children.map(editableSubtask))
                    summary["progress"] = record["manualProgress"]?["value"]
                    summary["kind"] = record["kind"]
                    summary["status"] = record["status"]
                    summary["checked"] = record["checked"]
                    summary["onDay"] = record["extra"]?["onDay"]
                }
                if kind == .event { summary["exceptions"] = record["exceptions"] }
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

    private static func recordRevision(_ kind: Kind, _ record: JSONValue, _ children: [MTSubtask]) -> String {
        if kind != .task || children.isEmpty { return revision(record) }
        return revision(.array([record] + children.sorted { $0.id < $1.id }.map(\.raw)))
    }

    private static func editableSubtask(_ task: MTSubtask) -> JSONValue {
        .object((task.json.objectValue ?? [:]).filter {
            ["id", "title", "done", "plannedStart", "plannedEnd", "estimateMinutes"].contains($0.key)
        })
    }

    public static func occurrenceFields(_ event: MTEvent) -> [String: JSONValue] {
        fields(.event, event.json)
    }

    private static func fields(_ kind: Kind, _ record: JSONValue) -> [String: JSONValue] {
        var values = (record.objectValue ?? [:]).filter { kind.fields.contains($0.key) }
        for key in kind.extraFields { values[key] = record["extra"]?[key] }
        if kind == .event {
            values["allDay"] = record["extra"]?["allDay"] ?? .bool(false)
            values["subjectName"] = record["classInfo"]?["subjectName"]
            values["room"] = record["classInfo"]?["room"]
        }
        return values
    }

    private static func plan(_ input: JSONValue, _ repo: Repository, _ now: EpochMs) throws -> [Change] {
        let records = activeRecords(repo)
        let calendars = Set(repo.calendars().map(\.id))
        let employers = Set(repo.employers().map(\.id))
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
                    let children = kind == .task ? subtasks[id] ?? [] : []
                    if action == .add {
                        guard UUID(uuidString: id) != nil, current == nil, !(kind == .event && eventIDs.contains(id)),
                              !(kind == .task && taskIDs.contains(id)) else { throw RepositoryError("新規追加には未使用のUUIDを指定してください") }
                    } else {
                        guard let current, let expected = entry["revision"]?.stringValue,
                              expected == recordRevision(kind, current, children)
                                || (entry["fields"]?["subtasks"] == nil && expected == revision(current)) else {
                            throw RepositoryError("対象が見つからないか書き出し後に変わりました。先に書き出し直してください")
                        }
                    }
                    if let occurrence = entry["occurrenceStart"] {
                        guard kind != .task, action != .add, entry["wholeSeries"]?.boolValue != true,
                              timestamp(occurrence), let start = occurrence.intValue, let current else {
                            throw RepositoryError("指定した回を確認してください")
                        }
                        if kind == .checkpoint {
                            return try checkpointChange(current, action, start, entry["fields"], now)
                        }
                        return try occurrenceChange(current, action, start, entry["fields"], now, calendars, employers, repo.studioTypes())
                    }
                    let affectsSeries = kind == .event && current?["recurrence"]?.objectValue != nil
                        || kind == .checkpoint && current?["repeat"]?.stringValue != nil
                        || kind == .task && current?["repeat"].map { !$0.isNull } == true
                    if action != .add, affectsSeries, entry["wholeSeries"]?.boolValue != true {
                        throw RepositoryError("繰り返し全体を変更する場合は wholeSeries を true にしてください")
                    }
                    let related = children.count
                    if action == .delete {
                        guard entry["fields"] == nil else { throw RepositoryError("削除に変更項目は指定できません") }
                        return Change(kind: kind, action: action, id: id, before: current, after: nil, changedFields: [], affectsSeries: affectsSeries, relatedTasks: related)
                    }
                    let allowed = kind == .task ? kind.fields.union(["taskAction", "progress", "subtasks"]) : kind.fields
                    guard let patch = entry["fields"]?.objectValue, !patch.isEmpty, Set(patch.keys).isSubset(of: allowed) else {
                        throw RepositoryError("変更項目が空か、対応していない項目が含まれています")
                    }
                    if let employer = patch["employerId"]?.stringValue, !employers.contains(employer) {
                        throw RepositoryError("勤務先が見つかりません")
                    }
                    if let parent = patch["eventId"]?.stringValue, !eventIDs.contains(parent) {
                        throw RepositoryError("内包先の予定が見つかりません")
                    }
                    if let studio = patch["studio"]?["typeId"]?.stringValue,
                       !repo.studioTypes().contains(where: { $0.id == studio && Int64($0.version) == patch["studio"]?["version"]?.intValue
                            && ($0.target == "calendar") == (kind == .event) }) {
                        throw RepositoryError("指定した種類が見つかりません")
                    }
                    var next = try updated(kind, id, current, patch, now, calendars)
                    var before = current
                    var childUpdates: [JSONValue]?
                    if kind == .task {
                        childUpdates = try patch["subtasks"].map { try plannedSubtasks($0, children: children, task: MTTask(json: next), at: now, repo: repo) }
                        if let childUpdates {
                            before = current?.merging(.object(["subtasks": .array(children.map(editableSubtask))]))
                            next = next.merging(.object(["subtasks": .array(childUpdates.map { editableSubtask(MTSubtask(json: $0)) })]))
                        }
                        let childrenAfter = childUpdates?.map(MTSubtask.init) ?? children
                        let task = MTTask(json: next)
                        if !childrenAfter.isEmpty, !canAddSubtask(task) { throw RepositoryError("このタスクにはサブタスクを付けられません") }
                        next = try taskOperations(task, patch: patch, subtasks: childrenAfter, at: now)
                    }
                    let fields = patch.keys.map { $0 == "taskAction" ? "status" : $0 }.sorted()
                    return Change(kind: kind, action: action, id: id, before: before, after: next, changedFields: fields, affectsSeries: affectsSeries, relatedTasks: related, subtaskUpdates: childUpdates)
                }
            }
        default:
            throw RepositoryError("My Time の変更ファイルまたは TimeTree のコピー用ファイルを選んでください")
        }
        let groups = Dictionary(grouping: changes, by: { "\($0.kind.rawValue):\($0.id)" })
        guard groups.values.allSatisfy({ group in
            if group.count == 1 { return true }
            let starts = group.compactMap(\.occurrenceStart)
            return starts.count == group.count && starts.count == Set(starts).count
        }) else { throw RepositoryError("同じ項目がファイル内に複数あります") }
        let newSubtasks = changes.flatMap { $0.subtaskUpdates ?? [] }.compactMap { $0["id"]?.stringValue }
        guard newSubtasks.count == Set(newSubtasks).count else { throw RepositoryError("同じサブタスクが複数のタスクに指定されています") }
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
        var classInfo = current?["classInfo"]?.objectValue ?? [:]
        for (key, value) in patch {
            try validate(key, value, calendars, kind: kind)
            switch key {
            case "place":
                var place = extra["place"]?.objectValue ?? [:]
                if let name = value.stringValue {
                    if place["name"]?.stringValue != name { place = ["name": name.json] }
                    extra["place"] = .object(place)
                } else { extra["place"] = value.isNull ? nil : value }
                values.removeValue(forKey: key)
            case "subjectName", "room":
                classInfo[key] = value.isNull ? nil : value
                values["classInfo"] = classInfo.isEmpty ? .null : .object(classInfo)
                values.removeValue(forKey: key)
            case "checked", "taskAction", "progress", "subtasks":
                values.removeValue(forKey: key)
            default:
                if kind.extraFields.contains(key) {
                    extra[key] = value.isNull ? nil : value
                    values.removeValue(forKey: key)
                }
            }
        }
        let initial: JSONValue
        switch kind {
        case .event:
            initial = MTEvent.make(title: "", calendarId: MTCalendar.selfId, start: 0, end: 0, now: now, id: id).json
            if current == nil, patch["start"] == nil || patch["end"] == nil { throw RepositoryError("開始と終了を指定してください") }
        case .task: initial = MTTask.make(title: "", now: now, id: id).json
        case .checkpoint:
            initial = .object(["id": id.json, "title": "".json, "notes": "".json, "alarm": .bool(false)])
        }
        if !extra.isEmpty || current?["extra"]?.objectValue != nil { values["extra"] = .object(extra) }
        var next = (current ?? initial).merging(.object(values))
        if kind == .task, let newKind = patch["kind"]?.stringValue, let current,
           newKind != current["kind"]?.stringValue {
            guard MTTask(json: current).status == .notStarted else {
                throw RepositoryError("実行済みのタスクは種類を変更できません")
            }
            let clear = newKind == "check" ? ["plannedStart", "plannedEnd", "estimateMinutes", "autoStartAt", "autoEndAt"] : ["checkAt"]
            next = next.merging(.object(Dictionary(uniqueKeysWithValues: clear.filter { patch[$0] == nil }.map { ($0, .null) })))
        }
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
            if next["kind"]?.stringValue == "check", start != nil || end != nil {
                throw RepositoryError("確認タスクには確認時刻を指定してください")
            }
            if let start = next["autoStartAt"]?.intValue, let end = next["autoEndAt"]?.intValue, start >= end {
                throw RepositoryError("自動終了は自動開始より後にしてください")
            }
        case .checkpoint:
            guard next["at"]?.intValue != nil else { throw RepositoryError("チェックポイントの時刻を指定してください") }
        }
        return next
    }

    private static func validate(_ key: String, _ value: JSONValue, _ calendars: Set<String>, kind: Kind) throws {
        let valid: Bool
        switch key {
        case "title": valid = value.stringValue != nil
        case "kind": valid = TaskKind(rawValue: value.stringValue ?? "") != nil
        case "notes": valid = (value.stringValue?.count ?? 20_001) <= 20_000
        case "calendarId": valid = (kind == .task && value.isNull) || (value.stringValue.map(calendars.contains) ?? false)
        case "timeZone": valid = value.stringValue.flatMap(TimeZone.init(identifier:)) != nil
        case "start", "end", "at": valid = timestamp(value)
        case "plannedStart", "plannedEnd", "checkAt", "onDay", "autoStartAt", "autoEndAt": valid = value.isNull || timestamp(value)
        case "alarm", "allDay", "hideAfterEnd", "flagged", "checked", "shiftPending": valid = value.boolValue != nil
        case "location", "subjectName", "room", "employerId", "eventId", "category":
            valid = value.isNull || (value.stringValue?.count ?? 501) <= 500
        case "icon": valid = value.stringValue.map { !$0.isEmpty && $0.count <= 100 } ?? false
        case "place": valid = value.isNull || (value.stringValue?.count ?? 501) <= 500 || validPlace(value)
        case "color": valid = value.isNull || (value.stringValue?.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil)
        case "repeat":
            valid = value.isNull || (kind == .checkpoint ? ["daily", "weekdays", "weekly"].contains(value.stringValue ?? "") : validTaskRepeat(value))
        case "recurrence": valid = value.isNull || validRecurrence(value)
        case "notifyBefore", "notifyMinutesBefore", "travelMinutes":
            valid = value.isNull || value.intValue.map { (0...1440).contains($0) } == true
        case "estimateMinutes": valid = value.isNull || value.intValue.map { (1...10_000).contains($0) } == true
        case "priority": valid = value.intValue.map { (0...3).contains($0) } == true
        case "tags", "bring":
            valid = value.isNull || value.arrayValue.map { $0.count <= 100 && $0.allSatisfy { ($0.stringValue?.count ?? 201) <= 200 } } == true
        case "notifies":
            valid = value.isNull || value.arrayValue.map { $0.count <= 20 && $0.allSatisfy { $0.intValue.map { (0...1440).contains($0) } == true } } == true
        case "meetingUrl": valid = value.isNull || validHttps(value.stringValue)
        case "urls":
            valid = value.isNull || value.arrayValue.map { $0.count <= 30 && $0.allSatisfy { link in
                validHttps(link["url"]?.stringValue) && (link["id"]?.stringValue?.count ?? 101) <= 100
                    && (link["title"]?.stringValue?.count ?? 201) <= 200
            } } == true
        case "spec":
            let type = SpecTypeId(rawValue: value["type"]?.stringValue ?? "").flatMap { SPEC_BY_ID[$0] }
            valid = value.isNull || (type?.isEvent == (kind == .event) && value["details"]?.objectValue != nil)
        case "studio":
            valid = value.isNull || (value["typeId"]?.stringValue != nil && (value["version"]?.intValue ?? 0) > 0 && value["values"]?.objectValue != nil)
        case "taskAction": valid = TaskAction(rawValue: value.stringValue ?? "") != nil
        case "progress": valid = value.doubleValue.map { (0...1).contains($0) } == true
        case "subtasks": valid = value.arrayValue != nil
        default: valid = false
        }
        guard valid else { throw RepositoryError("\(key) の値が正しくありません") }
    }

    private static func validPlace(_ value: JSONValue) -> Bool {
        guard let place = value.objectValue, let name = place["name"]?.stringValue,
              !name.isEmpty, name.count <= 500, Set(place.keys).isSubset(of: ["name", "address", "lat", "lng"]) else { return false }
        let address = place["address"] ?? .null
        let lat = place["lat"] ?? .null, lng = place["lng"] ?? .null
        return (address.isNull || (address.stringValue?.count ?? 1001) <= 1000)
            && (lat.isNull || lat.doubleValue.map { (-90...90).contains($0) } == true)
            && (lng.isNull || lng.doubleValue.map { (-180...180).contains($0) } == true)
    }

    private static func validHttps(_ value: String?) -> Bool {
        guard let value, value.count <= 2048, let url = URLComponents(string: value),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    private static func validRecurrence(_ value: JSONValue) -> Bool {
        guard let data = value.objectValue, Set(data.keys).isSubset(of: ["freq", "interval", "byWeekday", "until"]),
              RecurrenceFreq(rawValue: data["freq"]?.stringValue ?? "") != nil else { return false }
        if let interval = data["interval"], interval.intValue.map({ (1...366).contains($0) }) != true { return false }
        if let days = data["byWeekday"], !days.isNull {
            guard let days = days.arrayValue, days.count <= 7, days.allSatisfy({ $0.intValue.map { (0...6).contains($0) } == true }) else { return false }
            guard Set(days.compactMap(\.intValue)).count == days.count else { return false }
        }
        return data["until"].map { $0.isNull || timestamp($0) } ?? true
    }

    private static func validTaskRepeat(_ value: JSONValue) -> Bool {
        ["daily", "weekdays", "weekly"].contains(value.stringValue ?? "") || validRecurrence(value)
    }

    private static func taskOperations(_ raw: MTTask, patch: [String: JSONValue], subtasks: [MTSubtask], at: EpochMs) throws -> JSONValue {
        var task = raw
        if let checked = patch["checked"]?.boolValue {
            guard task.kind == .check else { throw RepositoryError("確認状態は確認タスクにだけ指定できます") }
            if task.checked != checked { task = try toggleCheck(task, at: at).task }
        }
        if let progress = patch["progress"]?.doubleValue {
            task = try recordManualProgress(task, subtasks: subtasks, value: progress, at: at).task
        }
        if let name = patch["taskAction"]?.stringValue, let action = TaskAction(rawValue: name) {
            task = try applyTaskAction(task, action, at: at).task
        }
        if patch["progress"] != nil {
            return task.json.merging(.object(["progress": task.manualProgress.map { .number($0.value) } ?? .null]))
        }
        return task.json
    }

    private static func plannedSubtasks(_ value: JSONValue, children: [MTSubtask], task: MTTask, at: EpochMs, repo: Repository) throws -> [JSONValue] {
        guard let list = value.arrayValue, list.count <= 100 else { throw RepositoryError("サブタスクは100件までです") }
        let existing = Dictionary(children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allIDs = Set(repo.subtasks().map(\.id))
        var seen = Set<String>()
        return try list.enumerated().map { index, item in
            guard let fields = item.objectValue,
                  Set(fields.keys).isSubset(of: ["id", "title", "done", "plannedStart", "plannedEnd", "estimateMinutes"]),
                  let id = fields["id"]?.stringValue, seen.insert(id).inserted,
                  existing[id] != nil || (UUID(uuidString: id) != nil && !allIDs.contains(id)) else {
                throw RepositoryError("サブタスクのIDを確認してください")
            }
            var subtask = existing[id] ?? MTSubtask.make(taskId: task.id, title: "", order: Int64(index), now: at, id: id)
            let before = subtask.done
            let patch = fields.filter { $0.key != "id" }
            for (key, value) in patch {
                if key == "done" {
                    guard value.boolValue != nil else { throw RepositoryError("完了は true または false で指定してください") }
                } else { try validate(key, value, [], kind: .task) }
            }
            subtask = MTSubtask(json: subtask.json.merging(.object(patch)))
            guard !subtask.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, subtask.title.count <= 200 else {
                throw RepositoryError("サブタスクの名前は1〜200文字です")
            }
            if let start = subtask.plannedStart, let end = subtask.plannedEnd, start >= end {
                throw RepositoryError("サブタスクの終了は開始より後にしてください")
            }
            subtask.order = Int64(index)
            if subtask.done != before { subtask.completedAt = subtask.done ? at : nil }
            return subtask.json
        }
    }

    private static func occurrenceChange(_ raw: JSONValue, _ action: Action, _ start: EpochMs,
                                         _ patch: JSONValue?, _ now: EpochMs, _ calendars: Set<String>,
                                         _ employers: Set<String>, _ studioTypes: [StudioType]) throws -> Change {
        let event = MTEvent(json: raw)
        guard event.recurrence != nil, ruleStarts(event, from: start, to: start + 1).contains(start) else {
            throw RepositoryError("繰り返し予定の指定された回が見つかりません")
        }
        let exception = event.exceptions.first { $0.originalStart == start }
        guard exception?.kind != .cancelled, exception?.kind != .archived else { throw RepositoryError("この回は削除されています") }
        var effective = event.applyingOccurrence(exception)
        effective.start = exception?.start ?? start
        effective.end = exception?.end ?? (start + event.end - event.start)
        effective.title = exception?.title ?? event.title
        effective.notes = exception?.notes ?? event.notes
        if action == .delete {
            guard patch == nil else { throw RepositoryError("削除に変更項目は指定できません") }
            return Change(kind: .event, action: action, id: event.id, before: effective.json, after: nil,
                          changedFields: [], affectsSeries: false, relatedTasks: 0, occurrenceStart: start)
        }
        guard let patch = patch?.objectValue, !patch.isEmpty, Set(patch.keys).isSubset(of: Kind.event.fields.subtracting(["recurrence"])) else {
            throw RepositoryError("指定回に繰り返しルールは設定できません")
        }
        if let employer = patch["employerId"]?.stringValue, !employers.contains(employer) {
            throw RepositoryError("勤務先が見つかりません")
        }
        if let id = patch["studio"]?["typeId"]?.stringValue,
           !studioTypes.contains(where: { $0.id == id && $0.target == "calendar" && Int64($0.version) == patch["studio"]?["version"]?.intValue }) {
            throw RepositoryError("指定した種類が見つかりません")
        }
        let next = try updated(.event, event.id, effective.json, patch, now, calendars)
        return Change(kind: .event, action: action, id: event.id, before: effective.json, after: next,
                      changedFields: patch.keys.sorted(), affectsSeries: false, relatedTasks: 0, occurrenceStart: start)
    }

    private static let checkpointOverrides = "occurrenceOverrides"

    private static func checkpointStart(_ record: JSONValue, day: EpochMs, time: DomainTime) -> EpochMs? {
        guard let at = record["at"]?.intValue, at < time.addDays(day, 1) else { return nil }
        if at >= day { return at }
        let eligible: Bool
        switch record["repeat"]?.stringValue {
        case "daily": eligible = true
        case "weekdays": eligible = (1...5).contains(time.weekday(day))
        case "weekly": eligible = time.weekday(day) == time.weekday(at)
        default: eligible = false
        }
        return eligible ? day + at - time.startOfDay(at) : nil
    }

    /// Recurring checkpoint occurrences for the timeline, alarms, and sync.
    public static func checkpoints(_ records: [JSONValue], on day: EpochMs, time: DomainTime = .current,
                                   forSync: Bool = false) -> [JSONValue] {
        let from = time.startOfDay(day), to = time.addDays(from, 1)
        return records.flatMap { record -> [JSONValue] in
            let overrides = record[checkpointOverrides]?.objectValue ?? [:]
            var results: [JSONValue] = []
            if let original = checkpointStart(record, day: from, time: time), overrides[String(original)] == nil {
                results.append(record.merging(.object(["at": original.json, "occurrenceStart": original.json])))
            }
            for (key, override) in overrides {
                guard let original = EpochMs(key), let at = override["at"]?.intValue, at >= from, at < to,
                      checkpointStart(record, day: time.startOfDay(original), time: time) == original else { continue }
                results.append(record.merging(override).merging(.object(["occurrenceStart": original.json])))
            }
            if !forSync { return results }
            let version = revision(record).json
            return results.map { value in
                var summary = fields(.checkpoint, value)
                summary["id"] = value["id"]
                summary["revision"] = version
                if record["repeat"]?.stringValue != nil {
                    summary["occurrenceStart"] = value["occurrenceStart"]
                    summary["seriesAt"] = record["at"]
                }
                return .object(summary)
            }
        }.sorted { ($0["at"]?.intValue ?? 0) < ($1["at"]?.intValue ?? 0) }
    }

    private static func checkpointChange(_ raw: JSONValue, _ action: Action, _ start: EpochMs,
                                         _ patch: JSONValue?, _ now: EpochMs) throws -> Change {
        let time = DomainTime.current
        guard let id = raw["id"]?.stringValue, raw["repeat"]?.stringValue != nil,
              checkpointStart(raw, day: time.startOfDay(start), time: time) == start else {
            throw RepositoryError("チェックポイントの指定された回が見つかりません")
        }
        let override = raw[checkpointOverrides]?[String(start)]
        guard override?.isNull != true else { throw RepositoryError("この回は削除されています") }
        let initial = raw.merging(.object(["at": start.json]))
        let current = override.map { initial.merging($0) } ?? initial
        if action == .delete {
            guard patch == nil else { throw RepositoryError("削除に変更項目は指定できません") }
            return Change(kind: .checkpoint, action: action, id: id, before: current, after: nil,
                          changedFields: [], affectsSeries: false, relatedTasks: 0, occurrenceStart: start)
        }
        guard let patch = patch?.objectValue, !patch.isEmpty, Set(patch.keys).isSubset(of: Kind.checkpoint.fields.subtracting(["repeat"])) else {
            throw RepositoryError("指定回では繰り返し自体の変更はできません")
        }
        return Change(kind: .checkpoint, action: action, id: id, before: current,
                      after: try updated(.checkpoint, id, current, patch, now, []), changedFields: patch.keys.sorted(),
                      affectsSeries: false, relatedTasks: 0, occurrenceStart: start)
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
        let previous = points.first { $0["id"]?.stringValue == id }
        points.removeAll { $0["id"]?.stringValue == id }
        if let value { points.append(previous?.merging(value) ?? value) }
        settings.raw = settings.raw.merging(.object([checkpointsKey: .array(points)]))
    }

    private static func write(_ change: Change, _ repo: Repository) throws {
        if let original = change.occurrenceStart {
            if change.kind == .checkpoint {
                repo.updateSettings { settings in
                    guard let master = settings.raw[checkpointsKey]?.arrayValue?.first(where: { $0["id"]?.stringValue == change.id }) else { return }
                    var overrides = master[checkpointOverrides]?.objectValue ?? [:]
                    let key = String(original)
                    if let after = change.after {
                        var values = overrides[key]?.objectValue ?? [:]
                        for field in change.changedFields { values[field] = after[field] }
                        values["at"] = after["at"]
                        overrides[key] = .object(values)
                    } else { overrides[key] = .null }
                    let next = master.merging(.object([checkpointOverrides: .object(overrides)]))
                    updateCheckpoint(next, id: change.id, settings: &settings)
                }
                return
            }
            if let value = change.after {
                let event = MTEvent(json: value)
                var overrides: [String: JSONValue] = [:]
                for key in change.changedFields where !["start", "end", "title", "notes"].contains(key) {
                    if Kind.event.extraFields.contains(key) { overrides[key] = value["extra"]?[key] ?? .null }
                    else if ["subjectName", "room"].contains(key) { overrides[key] = value["classInfo"]?[key] ?? .null }
                    else { overrides[key] = value[key] ?? .null }
                }
                try repo.editOccurrence(masterId: change.id, originalStart: original, start: event.start, end: event.end,
                                        title: change.changedFields.contains("title") ? event.title : nil,
                                        notes: change.changedFields.contains("notes") ? event.notes : nil,
                                        overrides: overrides)
            } else {
                try repo.cancelOccurrence(masterId: change.id, originalStart: original)
            }
            return
        }
        switch (change.kind, change.after) {
        case (.event, .some(let value)): try repo.saveEvent(MTEvent(json: value), isNew: change.before == nil)
        case (.event, .none): try repo.deleteEvent(change.id)
        case (.task, .some(let value)):
            var record = value.objectValue ?? [:]
            record.removeValue(forKey: "subtasks")
            record.removeValue(forKey: "progress")
            // 親を予定内包・確認タスクに切り替えるときは、取り除く子を先に消す。
            let children = change.subtaskUpdates?.map(MTSubtask.init)
            if let children {
                let ids = Set(children.map(\.id))
                for child in repo.subtasks() where child.taskId == change.id && !ids.contains(child.id) {
                    try repo.deleteSubtask(child.id)
                }
            }
            try repo.saveTask(MTTask(json: .object(record)), isNew: change.before == nil)
            if let children {
                for child in children { try repo.saveSubtask(child) }
            }
        case (.task, .none): try repo.deleteTask(change.id)
        case (.checkpoint, let value):
            repo.updateSettings { settings in
                updateCheckpoint(value, id: change.id, settings: &settings)
            }
        }
    }
}
