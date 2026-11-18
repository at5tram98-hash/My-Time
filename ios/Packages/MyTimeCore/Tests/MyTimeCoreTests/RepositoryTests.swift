import XCTest
@testable import MyTimeCore

final class RepositoryTests: XCTestCase {
    let tokyo = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    var now: EpochMs = 1_794_793_200_000 // 2026-11-16 10:40 JST
    var store: InMemoryStore!
    var repo: Repository!

    override func setUp() {
        store = InMemoryStore()
        repo = Repository(store: store, clock: { [unowned self] in now })
    }

    func testCreateEditPersistWithLogAndOutbox() throws {
        try repo.ensureDefaults()
        try repo.ensureDefaults()
        XCTAssertEqual(repo.calendars().map(\.name), ["自分", "みお"])
        var t = MTTask.make(title: "課題", now: now)
        t.plannedStart = now; t.plannedEnd = now + HOUR
        try repo.saveTask(t, isNew: true)
        t.title = "課題（改）"
        try repo.saveTask(t, isNew: false)
        XCTAssertEqual(repo.task(t.id)?.title, "課題（改）")
        XCTAssertEqual(store.logs().map { $0["action"]!.stringValue! }, ["create", "update"])
        XCTAssertEqual(store.logs()[1]["detail"]?["snapshot"]?["title"]?.stringValue, "課題")
        XCTAssertEqual(store.outbox().count, 2)
        XCTAssertEqual(store.outbox()[0]["synced"]?.intValue, 0)
    }

    func testValidationKeepsData() throws {
        var t = MTTask.make(title: "  ", now: now)
        XCTAssertThrowsError(try repo.saveTask(t, isNew: true))
        t.title = "OK"; t.plannedStart = now; t.plannedEnd = now - 1
        XCTAssertThrowsError(try repo.saveTask(t, isNew: true))
        XCTAssertTrue(repo.tasks().isEmpty)
        XCTAssertTrue(store.logs().isEmpty)
    }

    func testTaskStateMachineAndUndo() throws {
        var t = MTTask.make(title: "作業", now: now)
        t.plannedStart = now; t.plannedEnd = now + 2 * HOUR
        try repo.saveTask(t, isNew: true)
        try repo.taskAction(t.id, .start)
        now += 30 * MINUTE
        try repo.taskAction(t.id, .pause)
        XCTAssertThrowsError(try repo.taskAction(t.id, .pause))
        now += 10 * MINUTE
        try repo.taskAction(t.id, .resume)
        now += 20 * MINUTE
        try repo.taskAction(t.id, .finish)
        XCTAssertEqual(workedMs(repo.task(t.id)!, at: now), 50 * MINUTE)
        try repo.taskAction(t.id, .undoFinish)
        XCTAssertEqual(repo.task(t.id)?.status, .paused)
        XCTAssertNil(repo.task(t.id)?.actualEnd)
        XCTAssertEqual(store.logs().map { $0["action"]!.stringValue! }, ["create", "start", "pause", "resume", "finish", "undoFinish"])
    }

    func testProgressAndCompletionFromHundredPercent() throws {
        var t = MTTask.make(title: "進捗", now: now)
        t.plannedStart = now - HOUR; t.plannedEnd = now + HOUR
        try repo.saveTask(t, isNew: true)
        XCTAssertEqual(idealProgress(repo.task(t.id)!, now: now)!, 0.5, accuracy: 1e-9)
        try repo.recordProgress(t.id, value: 0.456)
        XCTAssertEqual(repo.task(t.id)?.manualProgress?.value, 0.46)
        try repo.completeFromProgress(t.id)
        XCTAssertEqual(repo.task(t.id)?.status, .done)
        XCTAssertEqual(actualProgress(repo.task(t.id)!, subtasks: []).value, 1)
    }

    func testSubtasksDriveParentProgressAndBlockManual() throws {
        let t = MTTask.make(title: "親", now: now)
        try repo.saveTask(t, isNew: true)
        try repo.addSubtask(taskId: t.id, title: "A")
        try repo.addSubtask(taskId: t.id, title: "B")
        try repo.addSubtask(taskId: t.id, title: "C")
        let subs = repo.subtasks()
        try repo.toggleSubtask(subs[0].id)
        let ap = actualProgress(repo.task(t.id)!, subtasks: repo.subtasks())
        XCTAssertEqual(ap.value!, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ap.source, .subtasks)
        XCTAssertThrowsError(try repo.recordProgress(t.id, value: 0.5))
        // 予定に内包されるタスクはサブタスクを持てない
        var inner = MTTask.make(title: "内包", now: now)
        inner.eventId = "ev"
        try repo.saveTask(inner, isNew: true)
        XCTAssertThrowsError(try repo.addSubtask(taskId: inner.id, title: "x"))
    }

    func testDeleteKeepsSnapshotAndCheckToggle() throws {
        var c = MTTask.make(title: "確認", kind: .check, now: now)
        c.checkAt = now
        try repo.saveTask(c, isNew: true)
        try repo.toggleCheck(c.id)
        XCTAssertTrue(repo.task(c.id)!.isDone)
        try repo.deleteTask(c.id)
        XCTAssertNil(repo.task(c.id))
        XCTAssertEqual(store.logs().last?["detail"]?["snapshot"]?["title"]?.stringValue, "確認")
        XCTAssertEqual(store.outbox().last?["op"]?.stringValue, "delete")
    }

    func testRecurringCancelOnlyThatOccurrence() throws {
        var e = MTEvent.make(title: "ゼミ", calendarId: "cal-class", start: now, end: now + HOUR, now: now)
        e.recurrence = RecurrenceRule(freq: .weekly, interval: 1)
        try repo.saveEvent(e, isNew: true)
        let occ = expandEvent(repo.event(e.id)!, from: now, to: tokyo.addDays(now, 21), time: tokyo)
        XCTAssertEqual(occ.count, 3)
        try repo.cancelOccurrence(masterId: e.id, originalStart: occ[1].originalStart!)
        XCTAssertEqual(expandEvent(repo.event(e.id)!, from: now, to: tokyo.addDays(now, 21), time: tokyo).count, 2)
    }

    func testMoveOnlyThisOccurrenceKeepsOthers() throws {
        var e = MTEvent.make(title: "ゼミ", calendarId: "cal-class", start: now, end: now + HOUR, now: now)
        e.recurrence = RecurrenceRule(freq: .weekly, interval: 1)
        try repo.saveEvent(e, isNew: true)
        let before = expandEvent(repo.event(e.id)!, from: now, to: tokyo.addDays(now, 21), time: tokyo)
        let target = before[1]
        try repo.editOccurrence(masterId: e.id, originalStart: target.originalStart!, start: target.start + 30 * MINUTE, end: target.end + 30 * MINUTE)
        let after = expandEvent(repo.event(e.id)!, from: now, to: tokyo.addDays(now, 21), time: tokyo)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[0].start, before[0].start)
        XCTAssertEqual(after[1].start, target.start + 30 * MINUTE)
        XCTAssertEqual(after[1].id, target.id, "回の ID（元の開始時刻）は変わらない")
        XCTAssertEqual(after[2].start, before[2].start)
        XCTAssertEqual(repo.event(e.id)?.start, now, "元の予定は変えない")
        // 2回目の変更は同じ例外を更新する（増えない）
        try repo.editOccurrence(masterId: e.id, originalStart: target.originalStart!, start: target.start + HOUR, end: target.end + HOUR)
        XCTAssertEqual(repo.event(e.id)?.exceptions.count, 1)
        XCTAssertEqual(repo.event(e.id)?.json["exceptions"]?.arrayValue?.first?["kind"]?.stringValue, "override")
        XCTAssertEqual(store.logs().last?["action"]?.stringValue, "occurrence-edit")
    }

    func testResizeChangesOnlyTheGrabbedEdge() throws {
        let e = MTEvent.make(title: "面談", calendarId: "cal-general", start: now, end: now + HOUR, now: now)
        try repo.saveEvent(e, isNew: true)
        try repo.resizeEvent(e.id, start: now, end: now + 105 * MINUTE)
        XCTAssertEqual(repo.event(e.id)?.start, now)
        XCTAssertEqual(repo.event(e.id)?.end, now + 105 * MINUTE)
        XCTAssertThrowsError(try repo.resizeEvent(e.id, start: now + HOUR, end: now + HOUR))
        XCTAssertEqual(repo.event(e.id)?.end, now + 105 * MINUTE, "失敗したら変えない")
        var t = MTTask.make(title: "課題", now: now)
        t.plannedStart = now; t.plannedEnd = now + HOUR
        try repo.saveTask(t, isNew: true)
        try repo.resizeTask(t.id, start: now - 15 * MINUTE, end: now + HOUR)
        XCTAssertEqual(repo.task(t.id)?.plannedStart, now - 15 * MINUTE)
        XCTAssertEqual(store.logs().last?["action"]?.stringValue, "resize")
    }

    func testMoveKeepsLength() throws {
        let e = MTEvent.make(title: "面談", calendarId: "cal-general", start: now, end: now + 90 * MINUTE, now: now)
        try repo.saveEvent(e, isNew: true)
        try repo.moveEvent(e.id, newStart: now + 2 * HOUR)
        XCTAssertEqual(repo.event(e.id)?.end, now + 2 * HOUR + 90 * MINUTE)
    }

    func testNextActionPriority() {
        var run = MTTask.make(title: "実行中", now: now); run.status = .running; run.intervals = [WorkInterval(start: now - HOUR, end: nil)]
        var soon = MTTask.make(title: "すぐ", now: now); soon.plannedStart = now + 10 * MINUTE; soon.plannedEnd = now + HOUR
        XCTAssertEqual(nextAction(events: [], tasks: [run, soon], now: now, time: tokyo).kind, .continue)
        XCTAssertEqual(nextAction(events: [], tasks: [soon], now: now, time: tokyo).title, "すぐ")
        XCTAssertEqual(nextAction(events: [], tasks: [], now: now, time: tokyo).kind, .free)
    }

    func testFreeTimeDoesNotDoubleCount() {
        let a = BusyItem(id: "a", title: "", start: now, end: now + 2 * HOUR, fixed: true)
        let b = BusyItem(id: "b", title: "", start: now + HOUR, end: now + 3 * HOUR, fixed: true)
        XCTAssertEqual(unionMinutes([a, b], from: now - DAY, to: now + DAY), 180)
    }

    func testJSONNumberFormattingLikeJavaScript() {
        XCTAssertEqual(JSONValue.formatNumber(1_794_793_200_000), "1794793200000")
        XCTAssertEqual(JSONValue.formatNumber(0.4), "0.4")
        XCTAssertEqual(JSONValue.formatNumber(1e-7), "1e-7")
        XCTAssertEqual(JSONValue.formatNumber(1e21), "1e+21")
        XCTAssertEqual(JSONValue.formatNumber(-5), "-5")
    }
}
