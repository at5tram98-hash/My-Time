import XCTest
@testable import MyTimeCore

final class MorningAutoTests: XCTestCase {
    let tokyo = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    var now: EpochMs = 1_794_793_200_000 // 2026-11-16 10:40 JST
    var store: InMemoryStore!
    var repo: Repository!
    var day: EpochMs { tokyo.startOfDay(now) + DAY }

    override func setUp() {
        store = InMemoryStore()
        repo = Repository(store: store, clock: { [unowned self] in now })
        try? repo.ensureDefaults()
    }

    func occ(_ day: EpochMs) -> [EventOccurrence] { expandAll(repo.events(), from: day, to: tokyo.addDays(day, 1), time: tokyo) }

    func addEvent(_ title: String, hour: Int, minute: Int = 0) throws -> MTEvent {
        let s = tokyo.at(day: day, hour: hour, minute: minute)
        let e = MTEvent.make(title: title, calendarId: MTCalendar.selfId, start: s, end: s + HOUR, now: now, timeZone: "Asia/Tokyo")
        try repo.saveEvent(e, isNew: true)
        return e
    }

    func morning() -> MTTask? { repo.tasks().first { $0.isAutoMorning } }

    func testPlacedTwoHoursBeforeFirstEventAndFollowsIt() throws {
        _ = try addEvent("ゼミ", hour: 13)
        var first = try addEvent("1限", hour: 9)
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 50, time: tokyo)
        XCTAssertEqual(morning()?.plannedStart, tokyo.at(day: day, hour: 7))
        XCTAssertEqual(morning()?.plannedEnd, tokyo.at(day: day, hour: 7, minute: 50))
        XCTAssertEqual(morning()?.specType, .morning)
        // もう一度呼んでも増えない
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 50, time: tokyo)
        XCTAssertEqual(repo.tasks().filter(\.isAutoMorning).count, 1)
        // 最初の予定が動くと朝もついていく
        try repo.moveEvent(first.id, newStart: tokyo.at(day: day, hour: 10))
        first = repo.event(first.id)!
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 50, time: tokyo)
        XCTAssertEqual(morning()?.plannedStart, tokyo.at(day: day, hour: 8))
        // 最初の予定を取り消すと、次の予定が基準になる
        try repo.setStruck(eventId: first.id, originalStart: nil, struck: true)
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 50, time: tokyo)
        XCTAssertEqual(morning()?.plannedStart, tokyo.at(day: day, hour: 11))
    }

    func testLengthIsCappedSoItEndsBeforeTheEvent() throws {
        _ = try addEvent("試験", hour: 9)
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 300, time: tokyo)
        XCTAssertEqual(morning()?.plannedEnd, tokyo.at(day: day, hour: 9), "長くても予定の開始まで")
    }

    func testManualMoveStartedOrManualMorningIsLeftAlone() throws {
        let e = try addEvent("1限", hour: 9)
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 60, time: tokyo)
        let m = morning()!
        try repo.moveTask(m.id, newStart: tokyo.at(day: day, hour: 6))
        try repo.moveEvent(e.id, newStart: tokyo.at(day: day, hour: 11))
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 60, time: tokyo)
        XCTAssertEqual(morning()?.plannedStart, tokyo.at(day: day, hour: 6), "手で動かした朝は動かさない")

        // 自分で入れた朝がある日は置かない
        let other = tokyo.addDays(day, 1)
        let s = tokyo.at(day: other, hour: 10)
        try repo.saveEvent(MTEvent.make(title: "授業", calendarId: MTCalendar.selfId, start: s, end: s + HOUR, now: now), isNew: true)
        var mine = MTTask.make(title: "身支度", now: now)
        mine.plannedStart = tokyo.at(day: other, hour: 7); mine.plannedEnd = tokyo.at(day: other, hour: 8)
        mine.extra = .object(["spec": .object(["type": .string("morning"), "details": .object([:])])])
        try repo.saveTask(mine, isNew: true)
        let ev2 = expandAll(repo.events(), from: other, to: tokyo.addDays(other, 1), time: tokyo)
        XCTAssertNil(try repo.autoPlaceMorning(day: other, events: ev2, minutes: 60, time: tokyo))
    }

    func testRemovedWhenNoEventsAndSkippedAfterDelete() throws {
        let e = try addEvent("1限", hour: 9)
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 60, time: tokyo)
        XCTAssertNotNil(morning())
        try repo.deleteEvent(e.id)
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 60, time: tokyo)
        XCTAssertNil(morning(), "予定がなくなった日は、まだ始めていない朝を外す")

        _ = try addEvent("2限", hour: 10)
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 60, time: tokyo)
        try repo.deleteTask(morning()!.id)
        try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 60, time: tokyo)
        XCTAssertNil(morning(), "朝を消した日は置き直さない")
    }

    func testTooEarlyIsNotPlaced() throws {
        _ = try addEvent("早朝バイト", hour: 5)
        XCTAssertNil(try repo.autoPlaceMorning(day: day, events: occ(day), minutes: 60, time: tokyo))
    }
}

final class WakeAlarmTests: XCTestCase {
    let time = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    func testWakeFromFirstEventTravelAndPrep() {
        let day = time.startOfDay(1_800_000_000_000)
        let first = time.at(day: day, hour: 10)
        // 10:00 − 移動40分 − 準備50分 − 10分 = 8:20
        XCTAssertEqual(MorningAuto.wakeMinute(firstStart: first, travelMinutes: 40, prepMinutes: 50, day: day, time: time), 8 * 60 + 20)
        // 早すぎる朝は置かない
        XCTAssertNil(MorningAuto.wakeMinute(firstStart: time.at(day: day, hour: 5), travelMinutes: 30, prepMinutes: 60, day: day, time: time))
    }

    func testAutoAlarmsKeepManualAndMaxThree() {
        var r = MorningRoutine.template()
        r.alarms = [MorningAlarm(id: "m1", hour: 6, minute: 0, label: "自分の"), MorningAlarm(id: "m2", hour: 6, minute: 30, label: "2つ目")]
        let out = MorningAuto.applyWakeAlarms(r, wakeMinute: 8 * 60, weekday: 2)
        XCTAssertEqual(out.alarms.map(\.id), ["auto-wake-1", "auto-wake-2", "m1"], "自動の2つを先に、合わせて3つまで")
        XCTAssertEqual(out.alarms.first?.hour, 7)
        XCTAssertEqual(out.alarms.first?.minute, 50)
        XCTAssertTrue(MorningAuto.turnOffManualAlarms(out).alarms.filter { !$0.label.hasPrefix("自動") }.allSatisfy { !$0.enabled })
        let none = MorningAuto.applyWakeAlarms(out, wakeMinute: nil, weekday: 2)
        XCTAssertEqual(none.alarms.map(\.id), ["m1"], "予定が無い日は自動のアラームを外す")
    }
}

final class StaleMorningTests: XCTestCase {
    func testStaleRunIsClosedAndKeptInHistory() {
        var r = MorningRoutine.template()
        var run = MorningRun(startedAt: 0, steps: r.enabledSteps)
        run.complete(now: 5 * MINUTE)
        r.active = run
        XCTAssertFalse(r.closeStale(now: 2 * HOUR), "6時間までは続ける")
        XCTAssertTrue(r.closeStale(now: 25 * HOUR))
        XCTAssertNil(r.active)
        XCTAssertEqual(r.history.first?.finishedAt, 5 * MINUTE, "最後に動かした所で終わり")
    }
}
