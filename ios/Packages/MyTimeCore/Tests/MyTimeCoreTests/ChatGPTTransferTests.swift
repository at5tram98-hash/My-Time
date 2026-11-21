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

    func testEditsAdvancedFieldsAndSubtasks() throws {
        let repo = Repository(store: InMemoryStore(), clock: { self.now })
        try repo.ensureDefaults()
        let childID = "a345ce62-7181-4d49-88a3-ff5fab23da53"
        let added = file([
            change("add", "event", eventID, [
                "title": "授業".json, "start": now.json, "end": (now + HOUR).json,
                "place": .object(["name": "教室".json, "lat": .number(35), "lng": .number(135)]),
                "room": "302".json, "subjectName": "経済学".json, "travelMinutes": .number(20),
                "meetingUrl": "https://example.com/meeting".json,
                "notifies": .array([.number(15), .number(5)]), "bring": .array(["教科書".json]),
            ]),
            change("add", "task", taskID, [
                "title": "課題".json, "category": "授業".json, "flagged": .bool(true), "priority": .number(2),
                "tags": .array(["提出".json]), "onDay": now.json, "taskAction": "start".json,
                "subtasks": .array([.object(["id": childID.json, "title": "資料を読む".json, "estimateMinutes": .number(20)])]),
            ]),
        ])
        XCTAssertEqual(try ChatGPTTransfer.apply(ChatGPTTransfer.preview(added, in: repo), to: repo), 2)
        XCTAssertEqual(repo.event(eventID)?.classInfo?["room"]?.stringValue, "302")
        XCTAssertEqual(repo.event(eventID)?.extra?["place"]?["lat"]?.doubleValue, 35)
        XCTAssertEqual(repo.task(taskID)?.status, .running)
        XCTAssertEqual(repo.task(taskID)?.extra?["onDay"]?.intValue, now)
        XCTAssertEqual(repo.task(taskID)?.tags, ["提出"])
        XCTAssertEqual(repo.subtasks().first?.estimateMinutes, 20)

        let snapshot = ChatGPTTransfer.snapshot(repo, kinds: [.task], from: now, to: now + DAY)
        let done = file([change("edit", "task", taskID, [
            "subtasks": .array([.object(["id": childID.json, "done": .bool(true), "title": "読み終えた".json])]),
            "taskAction": "finish".json, "calendarId": .null,
        ], revision: token(snapshot, "task"))])
        let preview = try ChatGPTTransfer.preview(done, in: repo)
        try repo.toggleSubtask(childID)
        XCTAssertThrowsError(try ChatGPTTransfer.apply(preview, to: repo))
        try repo.toggleSubtask(childID)
        let unchanged = ChatGPTTransfer.snapshot(repo, kinds: [.task], from: now, to: now + DAY)
        let refreshed = try JSONValue.parse(done)["changes"]!.arrayValue![0]
            .merging(.object(["revision": token(unchanged, "task")!]))
        XCTAssertEqual(try ChatGPTTransfer.apply(ChatGPTTransfer.preview(file([refreshed]), in: repo), to: repo), 1)
        XCTAssertEqual(repo.task(taskID)?.status, .done)
        XCTAssertEqual(repo.subtasks().first?.title, "読み終えた")
        XCTAssertEqual(repo.subtasks().first?.done, true)
    }

    func testOccurrenceEditsPreserveOtherDates() throws {
        let repo = Repository(store: InMemoryStore(), clock: { self.now })
        try repo.ensureDefaults()
        let time = DomainTime.current
        let day = time.startOfDay(now)
        let first = day + HOUR * 12
        let second = time.addDays(first, 1), third = time.addDays(first, 2)
        let moved = time.addDays(first, 20)
        let input = file([
            change("add", "event", eventID, [
                "title": "繰り返し予定".json, "start": first.json, "end": (first + HOUR).json,
                "recurrence": .object(["freq": "daily".json]),
            ]),
            change("add", "checkpoint", pointID, [
                "title": "繰り返し確認".json, "at": first.json, "repeat": "daily".json,
            ]),
        ])
        try ChatGPTTransfer.apply(ChatGPTTransfer.preview(input, in: repo), to: repo)
        let snapshot = ChatGPTTransfer.snapshot(repo, kinds: [.event, .checkpoint], from: day, to: time.addDays(day, 30))
        let changes = [
            change("edit", "event", eventID, [
                "title": "この回だけ".json, "notes": "変更メモ".json, "start": moved.json, "end": (moved + HOUR).json,
            ], revision: token(snapshot, "event")).merging(.object(["occurrenceStart": second.json])),
            change("delete", "event", eventID, revision: token(snapshot, "event")).merging(.object(["occurrenceStart": third.json])),
            change("edit", "checkpoint", pointID, ["title": "確認を変更".json, "at": moved.json, "alarm": .bool(true)],
                   revision: token(snapshot, "checkpoint")).merging(.object(["occurrenceStart": second.json])),
            change("delete", "checkpoint", pointID, revision: token(snapshot, "checkpoint")).merging(.object(["occurrenceStart": third.json])),
        ]
        XCTAssertEqual(try ChatGPTTransfer.apply(ChatGPTTransfer.preview(file(changes), in: repo), to: repo), 4)
        let master = try XCTUnwrap(repo.event(eventID))
        XCTAssertEqual(master.title, "繰り返し予定")
        XCTAssertFalse(expandEvent(master, from: day, to: time.addDays(day, 4)).contains { $0.originalStart == third })
        XCTAssertEqual(expandEvent(master, from: moved, to: moved + HOUR).first { $0.originalStart == second }?.event.notes, "変更メモ")

        let records = repo.settings().raw[ChatGPTTransfer.checkpointsKey]?.arrayValue ?? []
        XCTAssertEqual(ChatGPTTransfer.checkpoints(records, on: day).first?["title"]?.stringValue, "繰り返し確認")
        XCTAssertTrue(ChatGPTTransfer.checkpoints(records, on: third).isEmpty)
        XCTAssertTrue(ChatGPTTransfer.checkpoints(records, on: second).isEmpty)
        XCTAssertEqual(ChatGPTTransfer.checkpoints(records, on: moved).first {
            $0["occurrenceStart"]?.intValue == second
        }?["alarm"]?.boolValue, true)
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
