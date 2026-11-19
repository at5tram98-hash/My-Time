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
