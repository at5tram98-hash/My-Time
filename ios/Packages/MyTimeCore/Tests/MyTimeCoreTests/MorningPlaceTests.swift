import XCTest
@testable import MyTimeCore

final class MorningPlaceTests: XCTestCase {
    let time = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    func testPlacesTwoHoursBeforeFirstAndFollows() throws {
        let repo = Repository(store: InMemoryStore(), clock: { 0 })
        let day = time.at(day: time.startOfDay(1_800_000_000_000), hour: 0)
        func occ(_ h: Int, _ m: Int = 0, cal: String = MTCalendar.selfId) -> EventOccurrence {
            let s = time.at(day: day, hour: h, minute: m)
            let e = MTEvent.make(title: "x", calendarId: cal, start: s, end: s + 60 * MINUTE, now: 0)
            return EventOccurrence(id: e.id, masterId: e.id, originalStart: nil, event: e, start: s, end: s + 60 * MINUTE, title: "x")
        }
        try repo.placeMornings(days: [day], occurrences: [occ(13), occ(9), occ(6, cal: MTCalendar.mioId)], minutes: 50, now: 0, time: time)
        var ts = repo.tasks()
        XCTAssertEqual(ts.count, 1)
        XCTAssertEqual(ts[0].plannedStart, time.at(day: day, hour: 7), "自分の一番初めの予定（9時）の2時間前。みおの予定は見ない")
        XCTAssertEqual(ts[0].specType, .morning)
        // 予定が動けば付いて動く
        try repo.placeMornings(days: [day], occurrences: [occ(10)], minutes: 50, now: 0, time: time)
        ts = repo.tasks()
        XCTAssertEqual(ts.count, 1)
        XCTAssertEqual(ts[0].plannedStart, time.at(day: day, hour: 8))
        // 早すぎる朝（4時より前）は置かず、外す
        try repo.placeMornings(days: [day], occurrences: [occ(5)], minutes: 50, now: 0, time: time)
        XCTAssertTrue(repo.tasks().isEmpty)
        // 始めた朝は動かさない
        try repo.placeMornings(days: [day], occurrences: [occ(9)], minutes: 50, now: 0, time: time)
        try repo.taskAction(repo.tasks()[0].id, .start)
        try repo.placeMornings(days: [day], occurrences: [occ(11)], minutes: 50, now: 0, time: time)
        XCTAssertEqual(repo.tasks()[0].plannedStart, time.at(day: day, hour: 7))
    }
}
