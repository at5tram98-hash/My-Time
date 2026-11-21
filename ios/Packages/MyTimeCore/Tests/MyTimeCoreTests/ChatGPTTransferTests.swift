import Foundation
import XCTest
@testable import MyTimeCore

final class ChatGPTTransferTests: XCTestCase {
    private let eventID = "ac08513b-8dc5-4c2d-94cd-3c48faa40f80"
    private let taskID = "9645d7c3-593d-458b-a2b0-be4662f88000"
    private let pointID = "498554fa-63ab-4772-aa0d-710637493130"
    private let now: EpochMs = 1_800_000_000_000

    func testAddReviewEditDeleteAndReplay() throws {
        let repo = Repository(store: InMemoryStore(), clock: { self.now })
        try repo.ensureDefaults()
        let adds = [
            change("add", "event", eventID, ["title": "授業".json, "start": now.json, "end": (now + 3_600_000).json, "place": "教室".json]),
            change("add", "task", taskID, ["title": "資料を確認".json, "kind": "check".json, "checkAt": now.json]),
            change("add", "checkpoint", pointID, ["title": "出発".json, "at": now.json, "notifyBefore": .number(10)]),
        ]
        let input = file(adds)
        let preview = try ChatGPTTransfer.preview(input, in: repo)
        XCTAssertEqual(preview.changes.count, 3)
        XCTAssertTrue(repo.events().isEmpty)
        repo.clock = { self.now + 50 }
        XCTAssertEqual(try ChatGPTTransfer.apply(preview, to: repo), 3)
        XCTAssertThrowsError(try ChatGPTTransfer.preview(input, in: repo))

        // 編集の対象にしていない既存の値は保持する。
        let snapshot = ChatGPTTransfer.snapshot(repo, kinds: Set(ChatGPTTransfer.Kind.allCases), from: now, to: now + 86_400_000)
        let edits = [
            change("edit", "event", eventID, ["title": "演習".json], revision: token(snapshot, "event")),
            change("edit", "task", taskID, ["notes": "第5回".json], revision: token(snapshot, "task")),
            change("edit", "checkpoint", pointID, ["alarm": .bool(true)], revision: token(snapshot, "checkpoint")),
        ]
        XCTAssertEqual(try ChatGPTTransfer.apply(ChatGPTTransfer.preview(file(edits), in: repo), to: repo), 3)
        XCTAssertEqual(repo.event(eventID)?.title, "演習")
        XCTAssertEqual(repo.event(eventID)?.placeName, "教室")
        XCTAssertEqual(repo.task(taskID)?.checkAt, now)
        XCTAssertEqual(repo.task(taskID)?.notes, "第5回")
        XCTAssertEqual(repo.settings().raw[ChatGPTTransfer.checkpointsKey]?.arrayValue?.first?["notifyBefore"]?.intValue, 10)

        let updated = ChatGPTTransfer.snapshot(repo, kinds: Set(ChatGPTTransfer.Kind.allCases), from: now, to: now + 86_400_000)
        let deletes = [
            change("delete", "event", eventID, revision: token(updated, "event")),
            change("delete", "task", taskID, revision: token(updated, "task")),
            change("delete", "checkpoint", pointID, revision: token(updated, "checkpoint")),
        ]
        XCTAssertEqual(try ChatGPTTransfer.apply(ChatGPTTransfer.preview(file(deletes), in: repo), to: repo), 3)
        XCTAssertNil(repo.event(eventID))
        XCTAssertNil(repo.task(taskID))
        XCTAssertEqual(repo.settings().raw[ChatGPTTransfer.checkpointsKey]?.arrayValue, [])
        XCTAssertThrowsError(try ChatGPTTransfer.preview(input, in: repo))
    }

    func testStalePreviewLeavesAllRecordsUnchanged() throws {
        let repo = Repository(store: InMemoryStore(), clock: { self.now })
        try repo.ensureDefaults()
        var task = MTTask.make(title: "変更前", now: now, id: taskID)
        try repo.saveTask(task, isNew: true)
        let snapshot = ChatGPTTransfer.snapshot(repo, kinds: [.task], from: now, to: now + 86_400_000)
        XCTAssertNil(snapshot["event"])
        let input = file([
            change("add", "checkpoint", pointID, ["title": "確認".json, "at": now.json]),
            change("edit", "task", taskID, ["title": "ChatGPTの変更".json], revision: token(snapshot, "task")),
        ])
        let preview = try ChatGPTTransfer.preview(input, in: repo)
        task.title = "iPhoneの変更"
        try repo.saveTask(task, isNew: false)
        XCTAssertThrowsError(try ChatGPTTransfer.apply(preview, to: repo))
        XCTAssertEqual(repo.task(taskID)?.title, "iPhoneの変更")
        XCTAssertNil(repo.settings().raw[ChatGPTTransfer.checkpointsKey])
    }

    func testTimeTreeCopiesTimedAndAllDayEventsWithoutDuplicates() throws {
        let repo = Repository(store: InMemoryStore(), clock: { self.now })
        try repo.ensureDefaults()
        let data = Data("""
            {"format":"my-time-timetree-v1","events":[
              {"id":"tt-1","calendarId":"calendar","calendarName":"共有","title":"終日の予定","start":"2026-11-20T00:00:00.000Z","end":"2026-11-22T00:00:00.000Z","timezone":"UTC","allDay":true,"participants":["自分","同伴者"],"owners":["self","mio"],"location":"京都駅","label":{"name":"移動","color":"#FF0000"}},
              {"id":"tt-2","calendar_id":"calendar","title":"打ち合わせ","start":"2026-11-20T18:30:00+09:00","end":"2026-11-20T20:00:00+09:00","timezone":"Asia/Tokyo","allDay":false,"owners":["mio"]}
            ]}
            """.utf8)
        let preview = try ChatGPTTransfer.preview(data, in: repo)
        XCTAssertEqual(try ChatGPTTransfer.apply(preview, to: repo), 2)

        let allDay = try XCTUnwrap(repo.events().first(where: \.allDay))
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2026-11-20T00:00:00+09:00"))
        XCTAssertEqual(allDay.start, EpochMs(start.timeIntervalSince1970 * 1000))
        XCTAssertEqual(allDay.end - allDay.start, 2 * 86_400_000)
        XCTAssertEqual(allDay.timeZone, "Asia/Tokyo")
        XCTAssertEqual(allDay.calendarId, MTCalendar.selfId)
        XCTAssertEqual(allDay.placeName, "京都駅")
        XCTAssertEqual(allDay.colorOverride, "#FF0000")
        XCTAssertEqual(allDay.extra?["timeTree"]?["participants"]?.arrayValue?.count, 2)

        let timed = try XCTUnwrap(repo.events().first { !$0.allDay })
        let timedStart = try XCTUnwrap(formatter.date(from: "2026-11-20T09:30:00Z"))
        XCTAssertEqual(timed.start, EpochMs(timedStart.timeIntervalSince1970 * 1000))
        XCTAssertEqual(timed.calendarId, MTCalendar.mioId)
        let again = try ChatGPTTransfer.preview(data, in: repo)
        XCTAssertTrue(again.changes.allSatisfy(\.skipped))
        XCTAssertEqual(try ChatGPTTransfer.apply(again, to: repo), 0)
    }

    func testImportedClassroomAndShiftCanBeEdited() throws {
        let repo = Repository(store: InMemoryStore(), clock: { self.now })
        try repo.ensureDefaults()
        let input = Data("""
            {"format":"my-time-timetree-v1","events":[
              {"id":"lesson","calendarId":"tt","title":"マクロ経済学","myTimeSpecType":"class","myTimeRoom":"5302","start":"2026-11-20T10:45:00+09:00","end":"2026-11-20T12:15:00+09:00","allDay":false},
              {"id":"shift","calendarId":"tt","title":"無印18-23","start":"2026-11-20T18:00:00+09:00","end":"2026-11-20T23:00:00+09:00","allDay":false}
            ]}
            """.utf8)
        let imported = try ChatGPTTransfer.preview(input, in: repo)
        XCTAssertEqual(try ChatGPTTransfer.apply(imported, to: repo), 2)
        let lesson = try XCTUnwrap(repo.events().first { $0.specType == .class })
        XCTAssertEqual(lesson.classInfo?["room"]?.stringValue, "5302")
        XCTAssertEqual(lesson.classInfo?["subjectName"]?.stringValue, "マクロ経済学")
        XCTAssertTrue(repo.events().contains { $0.specType == .shift })

        let snapshot = ChatGPTTransfer.snapshot(repo, kinds: [.event], from: lesson.start, to: lesson.start + 86_400_000)
        let summary = try XCTUnwrap(snapshot["event"]?.arrayValue?.first { $0["id"]?.stringValue == lesson.id })
        let edit = change("edit", "event", lesson.id, [
            "room": "6301".json, "bring": .array(["ノート".json]),
            "recurrence": .object(["freq": "weekly".json]),
        ], revision: summary["revision"])
        let preview = try ChatGPTTransfer.preview(file([edit]), in: repo)
        XCTAssertEqual(try ChatGPTTransfer.apply(preview, to: repo), 1)

        let updated = try XCTUnwrap(repo.event(lesson.id))
        XCTAssertEqual(updated.classInfo?["room"]?.stringValue, "6301")
        XCTAssertEqual(updated.extra?["spec"]?["details"]?["room"]?.stringValue, "6301")
        XCTAssertEqual(updated.extra?["bring"]?.arrayValue, ["ノート".json])
        XCTAssertEqual(updated.recurrence?.freq, .weekly)
        XCTAssertEqual(updated.classInfo?["subjectName"]?.stringValue, "マクロ経済学")
    }

    private func token(_ snapshot: JSONValue, _ kind: String) -> JSONValue? {
        snapshot[kind]?.arrayValue?.first?["revision"]
    }

    private func change(_ action: String, _ kind: String, _ id: String,
                        _ fields: [String: JSONValue]? = nil, revision: JSONValue? = nil) -> JSONValue {
        var entry = ["action": action.json, "kind": kind.json, "id": id.json]
        if let fields { entry["fields"] = .object(fields) }
        entry["revision"] = revision
        return .object(entry)
    }

    private func file(_ entries: [JSONValue]) -> Data {
        JSONValue.object(["format": "my-time-changes-v1".json, "changes": .array(entries)]).data
    }
}
