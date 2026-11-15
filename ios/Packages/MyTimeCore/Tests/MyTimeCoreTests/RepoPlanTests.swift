import XCTest
@testable import MyTimeCore

final class RepoPlanTests: XCTestCase {
    let time = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    var day: EpochMs { time.startOfDay(1_794_711_600_000) }
    func at(_ h: Int, _ m: Int = 0, _ d: Int = 0) -> EpochMs { time.addDays(day, d) + EpochMs(h) * HOUR + EpochMs(m) * MINUTE }
    var store: InMemoryStore!
    var repo: Repository!

    override func setUp() {
        store = InMemoryStore()
        repo = Repository(store: store, clock: { [unowned self] in at(10) })
        try! repo.ensureDefaults()
    }

    func testCreateFromTextSavesEventPrepAndSessions() throws {
        let ctx = ParseContext(now: at(10), time: time)
        guard case .create(let a, _) = parseInput("土曜日はGU 18:30〜22:00、時給1,300円", ctx: ctx),
              case .create(let b, _) = parseInput("金曜までに経済学のレポート、2時間ぐらい", ctx: ctx) else { return XCTFail() }
        let made = try repo.createFromCandidates(a + b)
        XCTAssertEqual(made, 3) // 勤務・出勤の準備・レポート
        let ev = repo.events().first!
        XCTAssertEqual(ev.calendarId, "cal-job")
        XCTAssertEqual(ev.specType, .shift)
        XCTAssertEqual(ev.extra?["spec"]?["details"]?["hourlyWage"]?.doubleValue, 1300)
        let prep = repo.tasks().first { $0.sourceEventId == ev.id }!
        XCTAssertEqual(prep.plannedEnd, ev.start)
        let report = repo.tasks().first { $0.specType == .assignment }!
        XCTAssertEqual(report.estimateMinutes, 120)
        XCTAssertNotNil(report.deadline)
        XCTAssertEqual(repo.subtasks().filter { $0.taskId == report.id }.map(\.title), ["着手", "見直し"])
        XCTAssertTrue(repo.subtasks().allSatisfy { $0.plannedStart != nil })
    }

    func testApplyProposalMovesTaskAndLogsSnapshot() throws {
        var t = MTTask.make(title: "課題", now: at(10))
        t.plannedStart = at(8); t.plannedEnd = at(9)
        try repo.saveTask(t, isNew: true)
        let p = replanDay(day, events: [], tasks: repo.tasks(), subtasks: [], now: at(10), time: time)
        XCTAssertEqual(p.changes.count, 1)
        try repo.applyProposal(p)
        XCTAssertGreaterThanOrEqual(repo.task(t.id)!.plannedStart!, at(10))
        XCTAssertEqual(repo.history().first?["action"]?.stringValue, "plan")
        XCTAssertEqual(repo.history().first?["detail"]?["snapshot"]?["plannedStart"]?.intValue, at(8))
    }

    func testICSExport() {
        var e = MTEvent.make(title: "授業, 経済学", calendarId: "c", start: at(13), end: at(14, 30), now: at(10), id: "e1")
        e.recurrence = RecurrenceRule(freq: .weekly, byWeekday: [0])
        e.exceptions = [RecurrenceException(originalStart: at(13, 0, 7), kind: .cancelled)]
        let s = exportICS(events: [e], tasks: [], now: at(10))
        XCTAssertTrue(s.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(s.contains("SUMMARY:授業\\, 経済学"))
        XCTAssertTrue(s.contains("RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=SU"))
        XCTAssertTrue(s.contains("DTSTART:20261115T040000Z"))
        XCTAssertTrue(s.contains("EXDATE:20261122T040000Z"))
        XCTAssertTrue(s.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 75 })
    }
}
