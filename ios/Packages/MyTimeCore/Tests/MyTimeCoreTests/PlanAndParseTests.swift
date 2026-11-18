import XCTest
@testable import MyTimeCore

/// Web 版 redesign.test.ts の「空き時間と提案」「問題の検知」「文章からの入力」と同じ例
final class PlanAndParseTests: XCTestCase {
    let time = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    var day: EpochMs { time.startOfDay(1_794_711_600_000) } // 2026-11-15（日）
    func at(_ h: Int, _ m: Int = 0, _ d: Int = 0) -> EpochMs { time.addDays(day, d) + EpochMs(h) * HOUR + EpochMs(m) * MINUTE }
    var NOW: EpochMs { at(10) }

    func ev(_ title: String, _ s: EpochMs, _ e: EpochMs, id: String? = nil, extra: JSONValue? = nil) -> EventOccurrence {
        var x = MTEvent.make(title: title, calendarId: "c", start: s, end: e, now: NOW, id: id ?? UUID().uuidString)
        x.extra = extra
        return EventOccurrence(id: x.id, masterId: x.id, originalStart: nil, event: x, start: s, end: e, title: title)
    }
    func task(_ title: String, _ s: EpochMs? = nil, _ e: EpochMs? = nil, estimate: Int? = nil, due: EpochMs? = nil) -> MTTask {
        var t = MTTask.make(title: title, now: NOW)
        t.plannedStart = s; t.plannedEnd = e; t.estimateMinutes = estimate
        if let due { t.special = "assignment"; t.assignment = .object(["deadline": due.json]) }
        return t
    }
    func spec(_ type: String, _ details: [String: JSONValue] = [:]) -> JSONValue { .object(["spec": .object(["type": type.json, "details": .object(details)])]) }
    func ctx(_ events: [EventOccurrence] = []) -> ParseContext { ParseContext(now: NOW, events: events, time: time) }

    // MARK: 空き時間と提案

    func testFindSlotsAvoidsEvents() {
        let lunch = ev("昼", at(12), at(13))
        let s = findSlots(minutes: 90, busy: busyItems(events: [lunch], tasks: []).slots, from: NOW, until: at(23), count: 2, time: time)
        XCTAssertEqual(s[0], TimeSlot(start: at(10), end: at(11, 30)))
        XCTAssertTrue(s.allSatisfy { $0.end <= at(12) || $0.start >= at(13) })
    }

    func testPostponeKeepsDeadlineAndWarns() {
        let lunch = ev("昼", at(12), at(13))
        let t = task("課題", at(8), at(9), due: at(20))
        let opts = postponeOptions(t, busy: busyItems(events: [lunch], tasks: [t]), now: NOW, time: time)
        XCTAssertEqual(opts.map { $0.id.components(separatedBy: ":").last! }, ["later", "tomorrow", "inbox"])
        XCTAssertTrue(opts[1].warnings[0].contains("期限"))
        XCTAssertNil(opts[2].changes[0].after.start)
    }

    func testSessionsProposal() {
        let t = task("レポート", estimate: 120)
        let p = sessionsProposal(t, totalMinutes: 120, sessionMinutes: 60, busy: busyItems(events: [ev("昼", at(12), at(13))], tasks: []), now: NOW, until: at(23), time: time)!
        XCTAssertEqual(p.sessions.map(\.title), ["着手", "見直し"])
        XCTAssertTrue(p.sessions.allSatisfy { $0.end - $0.start == 60 * MINUTE })
    }

    func testReplanMovesOnlyPastTasks() {
        let late = task("過ぎた課題", at(8), at(9))
        let ok = task("午後の作業", at(15), at(16))
        let p = replanDay(day, events: [ev("昼", at(12), at(13))], tasks: [late, ok], subtasks: [], now: NOW, time: time)
        XCTAssertEqual(p.changes.map(\.id), [late.id])
        XCTAssertGreaterThanOrEqual(p.changes[0].after.start!, NOW)
        XCTAssertEqual(p.alternatives.first?.title, "明日に回す")
    }

    func testShiftProposalMovesPrepAndWarns() {
        let e = ev("勤務", at(14), at(18), id: "ev")
        var prep = task("準備", at(13, 40), at(14)); prep.sourceEventId = "ev"
        let other = ev("夕食", at(18, 30), at(19, 30))
        let p = shiftProposal(entity: .event, id: "ev", title: "勤務", start: e.start, end: e.end, deltaMin: 60, tasks: [prep], busy: busyItems(events: [e, other], tasks: [prep]))
        XCTAssertEqual(p.changes.count, 2)
        XCTAssertTrue(p.warnings[0].contains("夕食"))
    }

    func testPrepBefore() {
        let r = prepBefore(eventStart: at(17), travelMinutes: 20, items: [("A", 30), ("B", 5)])
        XCTAssertEqual(r.map(\.start), [at(16, 5), at(16, 35)])
        XCTAssertEqual(r.map(\.end), [at(16, 35), at(16, 40)])
    }

    // MARK: 問題の検知

    func testDetectIssues() {
        let a = ev("授業", at(13), at(14, 30)), b = ev("授業", at(13), at(14, 30)), c = ev("会議", at(14), at(15))
        let d = ev("勤務", at(15, 10), at(18), extra: .object(["travelMinutes": .number(30)]))
        let t = task("レポート", estimate: 900, due: at(23))
        let issues = detectIssues(events: [a, b, c, d], tasks: [t], subtasks: [], now: NOW, from: day, to: time.addDays(day, 1), time: time)
        let kinds = Set(issues.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.duplicate, .overlap, .travel, .deadline]))
        XCTAssertTrue(issues.filter { $0.kind == .overlap && $0.taskIds.isEmpty }.allSatisfy { $0.proposals.isEmpty })
        XCTAssertTrue(issues.first { $0.kind == .deadline }!.reason.contains("見込み"))
    }

    func testTravelUnknownIsLowConfidence() {
        let a = ev("授業", at(13), at(14), extra: .object(["place": .object(["name": "大学".json])]))
        let b = ev("勤務", at(14, 20), at(18), extra: .object(["place": .object(["name": "駅前店".json])]))
        let i = detectIssues(events: [a, b], tasks: [], subtasks: [], now: NOW, from: day, to: time.addDays(day, 1), time: time).first { $0.kind == .travel }!
        XCTAssertFalse(i.confident)
    }

    func testTaskOverlapProposesMovingTaskOnly() {
        let a = ev("授業", at(13), at(15))
        let t = task("読書", at(14), at(15))
        let i = detectIssues(events: [a], tasks: [t], subtasks: [], now: NOW, from: day, to: time.addDays(day, 1), time: time).first { $0.id == "tovl:\(t.id)" }!
        XCTAssertEqual(i.proposals[0].changes[0].entity, .task)
    }

    // MARK: 文章からの入力

    func testExampleA_Shift() {
        guard case .create(let cs, _) = parseInput("土曜日はGU 18:30〜22:00、時給1,300円", ctx: ctx()) else { return XCTFail() }
        XCTAssertEqual(cs.count, 1)
        let c = cs[0]
        XCTAssertEqual(c.entity, .event); XCTAssertEqual(c.spec, .shift); XCTAssertEqual(c.workplace, "GU"); XCTAssertTrue(c.timeCertain)
        XCTAssertEqual(time.weekday(c.start!), 6)
        XCTAssertEqual(c.end! - c.start!, 210 * MINUTE)
        XCTAssertEqual(c.details["hourlyWage"]?.doubleValue, 1300)
        XCTAssertEqual(c.details["breakMinutes"]?.doubleValue, 0)
        XCTAssertEqual(c.prep.first?.title, "出勤の準備")
    }

    func testExampleB_DeadlineSessions() {
        guard case .create(let cs, _) = parseInput("金曜までに経済学のレポート、2時間ぐらい", ctx: ctx()) else { return XCTFail() }
        XCTAssertEqual(cs.count, 1)
        let c = cs[0]
        XCTAssertEqual(c.entity, .task); XCTAssertEqual(c.spec, .assignment); XCTAssertEqual(c.title, "経済学のレポート"); XCTAssertEqual(c.estimateMinutes, 120); XCTAssertNil(c.start)
        XCTAssertEqual(time.weekday(c.due!), 5)
        XCTAssertEqual(c.sessions.map(\.title), ["着手", "見直し"])
        XCTAssertTrue(c.sessions.allSatisfy { $0.end <= c.due! })
    }

    func testExampleC_Outing() {
        guard case .create(let cs, _) = parseInput("17時に出かける", ctx: ctx()) else { return XCTFail() }
        let c = cs[0]
        XCTAssertEqual(c.entity, .event); XCTAssertEqual(c.spec, .outing); XCTAssertEqual(c.title, "外出"); XCTAssertEqual(c.start, at(17))
        XCTAssertEqual(c.prep.map(\.title), ["髪・身支度"])
        XCTAssertEqual(c.prep.last?.end, at(17))
        XCTAssertTrue(c.reasons.joined().contains("移動時間は分からない"))
    }

    func testMultipleItems() {
        guard case .create(let cs, _) = parseInput("明日は課題2つと買い物", ctx: ctx()) else { return XCTFail() }
        XCTAssertEqual(cs.map(\.title), ["課題1", "課題2", "買い物"])
        XCTAssertTrue(cs.allSatisfy { $0.start != nil && time.startOfDay($0.start!) == time.addDays(day, 1) && !$0.timeCertain })
        XCTAssertEqual(Set(cs.map { $0.start! }).count, 3)
    }

    func testVagueTimes() {
        let cls = ev("経済学", at(13), at(14, 30), extra: spec("class"))
        guard case .create(let a, _) = parseInput("夕方に買い物", ctx: ctx([cls])) else { return XCTFail() }
        XCTAssertFalse(a[0].timeCertain); XCTAssertEqual(a[0].start, at(17))
        XCTAssertTrue(a[0].reasons.joined().contains("夕方"))
        guard case .create(let b, _) = parseInput("授業後に図書館で勉強 1時間", ctx: ctx([cls])) else { return XCTFail() }
        XCTAssertEqual(b[0].start, at(14, 30))
        XCTAssertTrue(b[0].reasons.joined().contains("経済学"))
    }

    func testSearch() {
        guard case .search(let q) = parseInput("来週のバイト", ctx: ctx()) else { return XCTFail() }
        XCTAssertEqual(q.spec, .shift)
        let s1 = ev("GU", at(18, 0, 7), at(22, 0, 7), extra: spec("shift")), s2 = ev("GU", at(18, 0, 9), at(22, 0, 9), extra: spec("shift")), s3 = ev("GU", at(18, 0, 1), at(22, 0, 1), extra: spec("shift"))
        XCTAssertEqual(searchItems(q, events: [s1, s2, s3], tasks: []).map(\.at), [s1.start, s2.start])
    }

    func testShiftIntent() {
        guard case .shift(let q, let delta) = parseInput("明日のバイト前の勉強を1時間遅らせて", ctx: ctx()) else { return XCTFail() }
        XCTAssertEqual(delta, 60)
        XCTAssertEqual(q.words, ["勉強"]); XCTAssertEqual(q.before, "バイト")
        let job = ev("GU", at(18, 0, 1), at(22, 0, 1), extra: spec("shift"))
        let before = task("英語の勉強", at(15, 0, 1), at(16, 0, 1)), after = task("勉強", at(22, 30, 1), at(23, 0, 1))
        XCTAssertEqual(searchItems(q, events: [job], tasks: [before, after]).map(\.id), [before.id])
    }

    func testReplanIntent() {
        XCTAssertEqual(parseInput("急用ができたので今日の課題を移して", ctx: ctx()), .replan(day: day, spec: .assignment))
    }

    func testEmptyInput() {
        guard case .create(let cs, let notes) = parseInput("   ", ctx: ctx()) else { return XCTFail() }
        XCTAssertTrue(cs.isEmpty)
        XCTAssertTrue(notes[0].contains("書いてください"))
    }
}
