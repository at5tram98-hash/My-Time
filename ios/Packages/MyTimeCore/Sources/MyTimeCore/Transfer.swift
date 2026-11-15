import Foundation

/// Web 版の「データの移行」ファイル（`my-time-device-transfer` 版1）を読み書きする。
///
/// - 形式：`{ body: { format, version, owner, origin, createdAt, tables }, sha256 }`
/// - `sha256` は `canonical(body)` の SHA-256（Web 版 `canonicalJson` と同じ文字列）。1文字でも違えば読み込まない。
/// - 取り込みは「追加だけ」。同じ ID で内容が違うものがあれば、何も変えずに中止する（元データは残る）。
/// - 同じファイルを2回取り込んでも二重にならない（受領の印 `device-import:<sha256>` を操作ログに残す）。
public enum DeviceTransfer {
    public static let format = "my-time-device-transfer"
    public static let maxBytes = 50 * 1024 * 1024

    public struct File: Sendable {
        public var body: JSONValue
        public var sha256: String
        public var owner: String? { body["owner"]?.stringValue }
        public var origin: String { body["origin"]?.stringValue ?? "" }
        public var createdAt: EpochMs { body["createdAt"]?.intValue ?? 0 }
        public func rows(_ table: String) -> [JSONValue] { body["tables"]?[table]?.arrayValue ?? [] }
        /// 取り込む前の確認に出す件数
        public var summary: [(String, Int)] {
            [("予定", rows("events").count), ("タスク", rows("tasks").count), ("サブタスク", rows("subtasks").count), ("カレンダー", rows("calendars").count), ("勤務先", rows("employers").count), ("科目", rows("subjects").count)]
        }
    }

    public struct TransferError: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ d: String) { description = d }
    }

    // MARK: 書き出し

    /// この端末のデータを書き出す。Web 版の「データの移行」で、ログインしていない領域（この端末）へ取り込める
    public static func export(store: RecordStore, origin: String = "ios-app", now: EpochMs) -> String {
        var tables: [String: JSONValue] = [:]
        // 並びを固定する（同じデータなら同じファイル・同じチェックサムになる）
        for e in EntityName.allCases { tables[e.table] = .array(store.all(e).sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") }) }
        tables["operationLog"] = .array(store.logs())
        tables["outbox"] = .array(store.outbox())
        tables["settings"] = .array(store.settings().map { [$0] } ?? [])
        let body: JSONValue = .object(["format": format.json, "version": .number(1), "owner": .null, "origin": origin.json, "createdAt": now.json, "tables": .object(tables)])
        return JSONValue.object(["body": body, "sha256": SHA256.hex(body.canonical).json]).canonical
    }

    // MARK: 読み取り・検証

    public static func read(_ text: String) throws -> File {
        guard text.utf8.count <= maxBytes else { throw TransferError("移行ファイルが大きすぎます（上限50MB）") }
        let root: JSONValue
        do { root = try JSONValue.parse(text) } catch { throw TransferError("移行ファイルを読み取れません") }
        guard let body = root["body"], body["format"]?.stringValue == format, body["version"]?.intValue == 1, let tables = body["tables"]?.objectValue else {
            throw TransferError("対応していない移行ファイルです")
        }
        if let o = body["owner"], !o.isNull, o.stringValue == nil { throw TransferError("対応していない移行ファイルです") }
        guard root["sha256"]?.stringValue == SHA256.hex(body.canonical) else { throw TransferError("移行ファイルの内容が壊れています") }
        for (name, rows) in tables {
            guard let a = rows.arrayValue, a.allSatisfy({ $0.objectValue != nil }) else { throw TransferError("\(name) の形式が不正です") }
        }
        for e in EntityName.allCases {
            guard let rows = tables[e.table]?.arrayValue else { throw TransferError("\(e.rawValue) がありません") }
            var ids = Set<String>()
            for r in rows {
                guard let id = r["id"]?.stringValue, !id.isEmpty, !ids.contains(id) else { throw TransferError("\(e.rawValue) の内容・IDが不正です") }
                ids.insert(id)
                try validate(e, r)
            }
        }
        if (tables["settings"]?.arrayValue?.count ?? 0) > 1 { throw TransferError("設定が重複しています") }
        return File(body: body, sha256: root["sha256"]!.stringValue!)
    }

    /// Web 版の Zod と同じ考え方の最小限の検証（壊れた値で画面が落ちないように）
    private static func validate(_ e: EntityName, _ r: JSONValue) throws {
        func fail() -> TransferError { TransferError("\(e.rawValue) の内容・IDが不正です") }
        switch e {
        case .task:
            guard let title = r["title"]?.stringValue, !title.isEmpty, title.count <= 200 else { throw fail() }
            guard ["do", "check"].contains(r["kind"]?.stringValue ?? ""), ["notStarted", "running", "paused", "done"].contains(r["status"]?.stringValue ?? "") else { throw fail() }
            if let s = r["plannedStart"]?.intValue, let en = r["plannedEnd"]?.intValue, en <= s { throw fail() }
        case .event:
            guard let title = r["title"]?.stringValue, !title.isEmpty, let s = r["start"]?.intValue, let en = r["end"]?.intValue, en > s else { throw fail() }
        case .subtask:
            guard r["taskId"]?.stringValue != nil, r["title"]?.stringValue?.isEmpty == false else { throw fail() }
        case .calendar, .subject, .employer, .category, .studioType:
            guard r["name"]?.stringValue?.isEmpty == false else { throw fail() }
        }
    }

    // MARK: 取り込み（追加だけ）

    /// 取り込んだ件数を返す。2回目以降は 0。
    @discardableResult
    public static func importAddOnly(_ file: File, into store: RecordStore, now: EpochMs, newId: () -> String = { UUID().uuidString.lowercased() }) throws -> Int {
        let receipt = "device-import:\(file.sha256)"
        if store.logs().contains(where: { $0["id"]?.stringValue == receipt }) { return 0 }
        var added = 0
        try store.transaction {
            let initialArea = [EntityName.task, .event, .subtask, .subject, .employer].allSatisfy { store.all($0).isEmpty }
            let defaults = Dictionary(uniqueKeysWithValues: MTCalendar.defaults(now: 0).map { ($0.id, $0.json) })
            for e in EntityName.allCases {
                for rec in file.rows(e.table) {
                    let id = rec["id"]!.stringValue!
                    if let existing = store.get(e, id: id) {
                        if existing.canonical == rec.canonical { continue }
                        // 最初からあるカレンダー（両方の端末にある）は、未変更なら取り込み元で置き換える。変更済みなら中止
                        let untouched = e == .calendar && defaults[id] != nil && existing.merging(.object(["createdAt": .number(0), "updatedAt": .number(0)])).canonical == defaults[id]!.canonical
                        if !untouched { throw TransferError("同じIDで内容の異なるデータがあります。取り込みを中止しました（元データは残っています）") }
                    }
                    store.put(e, id: id, json: rec)
                    store.appendOutbox(.object(["opId": newId().json, "at": now.json, "entity": e.rawValue.json, "entityId": id.json, "op": "put".json, "synced": .number(0)]))
                    added += 1
                }
            }
            for raw in file.rows("operationLog") {
                guard let id = raw["id"]?.stringValue, !store.logs().contains(where: { $0["id"]?.stringValue == id }) else { continue }
                var o = raw.objectValue ?? [:]
                o["seq"] = nil
                store.appendLog(.object(o))
            }
            if initialArea, let s = file.rows("settings").first(where: { $0["key"]?.stringValue == "app" }) {
                store.putSettings(s.merging(.object(["key": "app".json, "onboarded": .bool(true)])))
            }
            store.appendLog(.object(["id": receipt.json, "at": now.json, "entity": "task".json, "entityId": "device-transfer".json, "action": "import-device".json, "detail": .object(["origin": file.origin.json, "added": .number(Double(added))])]))
        }
        return added
    }
}
