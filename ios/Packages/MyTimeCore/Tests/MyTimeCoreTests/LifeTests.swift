import XCTest
@testable import MyTimeCore

final class PayrollTests: XCTestCase {
    let time = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    func t(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> EpochMs {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
        return time.ms(time.calendar.date(from: c)!)
    }

    /// T-04：時給・交通費・休憩を含む計算（GU 18:30〜22:00 = 210分、6時間以下なので休憩なし）
    func testShiftPayWithTransportAndBreak() {
        var p = PayProfile()
        p.hourlyWage = 1200
        p.transportMode = .roundTrip
        p.transportAmount = 210
        p.breakRules = [BreakRule(overMinutes: 360, breakMinutes: 45), BreakRule(overMinutes: 480, breakMinutes: 60)]
        let r = PayCalculator.shift(start: t(2026, 11, 18, 18, 30), end: t(2026, 11, 18, 22), profile: p, time: time)!
        XCTAssertEqual(r.scheduledMinutes, 210)
        XCTAssertEqual(r.breakMinutes, 0)
        XCTAssertEqual(r.workMinutes, 210)
        XCTAssertEqual(r.pay, 4200)
        XCTAssertEqual(r.transport, 420)
        XCTAssertEqual(r.total, 4620)

        // 9時間の勤務：8時間超の条件（60分）を使う
        let long = PayCalculator.shift(start: t(2026, 11, 18, 9), end: t(2026, 11, 18, 18), profile: p, time: time)!
        XCTAssertEqual(long.breakMinutes, 60)
        XCTAssertEqual(long.workMinutes, 480)
        XCTAssertEqual(long.pay, 9600)
        XCTAssertFalse(long.belowLegalBreak)
    }

    func testRoundingUnitAndPremiumsAndLegalCheck() {
        var p = PayProfile()
        p.hourlyWage = 1000
        p.unitMinutes = 15
        p.unitRounding = .floor
        p.premiums = [PremiumRule(kind: .night, rate: 0.25, fromMinute: 22 * 60, toMinute: 5 * 60)]
        // 21:10〜23:00 = 110分 → 15分単位で切り捨て 105分。深夜 22:00〜23:00 = 60分 ×25%
        let r = PayCalculator.shift(start: t(2026, 11, 18, 21, 10), end: t(2026, 11, 18, 23), profile: p, time: time)!
        XCTAssertEqual(r.workMinutes, 105)
        XCTAssertEqual(r.basePay, 1750)
        XCTAssertEqual(r.premiumPay, 250)
        XCTAssertEqual(r.pay, 2000)
        // 休憩の条件が無い7時間勤務：計算は勤務先の条件（休憩0）のまま、法令の最低限（45分）を下回ると知らせる
        let seven = PayCalculator.shift(start: t(2026, 11, 18, 9), end: t(2026, 11, 18, 16), profile: p, time: time)!
        XCTAssertEqual(seven.breakMinutes, 0)
        XCTAssertTrue(seven.belowLegalBreak)
        // 予定に休憩が入力されていればそれを使う
        XCTAssertEqual(PayCalculator.shift(start: t(2026, 11, 18, 9), end: t(2026, 11, 18, 16), profile: p, breakOverride: 60, time: time)!.workMinutes, 360)
    }

    /// T-05：月末締めと15日締めを区別する
    func testClosingDays() {
        var endOfMonth = PayProfile(); endOfMonth.closingDay = 0; endOfMonth.paydayDay = 25; endOfMonth.paydayMonthOffset = 1
        var fifteenth = PayProfile(); fifteenth.closingDay = 15; fifteenth.paydayDay = 0; fifteenth.paydayMonthOffset = 0

        let d = t(2026, 11, 18, 18, 30)
        let a = PaySchedule.period(containing: d, profile: endOfMonth, time: time)
        XCTAssertEqual(a.from, t(2026, 11, 1))
        XCTAssertEqual(a.closing, t(2026, 11, 30))
        XCTAssertEqual(a.to, t(2026, 12, 1))
        XCTAssertEqual(a.payday, t(2026, 12, 25))

        // 15日締め：11/18 の勤務は 11/16〜12/15 の期間、支給は当月末（12/31）
        let b = PaySchedule.period(containing: d, profile: fifteenth, time: time)
        XCTAssertEqual(b.from, t(2026, 11, 16))
        XCTAssertEqual(b.closing, t(2026, 12, 15))
        XCTAssertEqual(b.payday, t(2026, 12, 31))
        // 11/15 の勤務は前の期間（10/16〜11/15）
        let c = PaySchedule.period(containing: t(2026, 11, 15, 10), profile: fifteenth, time: time)
        XCTAssertEqual(c.from, t(2026, 10, 16))
        XCTAssertEqual(c.closing, t(2026, 11, 15))
        XCTAssertEqual(c.payday, t(2026, 11, 30))

        // 2月の月末締め・30日払い（2月は28日まで）
        var feb = PayProfile(); feb.closingDay = 0; feb.paydayDay = 30; feb.paydayMonthOffset = 1
        XCTAssertEqual(PaySchedule.period(containing: t(2027, 1, 10), profile: feb, time: time).payday, t(2027, 2, 28))

        // 次の支給：11/18 時点で月末締め翌月25日払いなら 11/25（10月分）
        let next = PaySchedule.nextPayPeriod(after: t(2026, 11, 18, 12), profile: endOfMonth, time: time)
        XCTAssertEqual(next.payday, t(2026, 11, 25))
        XCTAssertEqual(next.from, t(2026, 10, 1))
    }

    func testPayrollLinesAndMonthlyTransport() throws {
        var emp = MTEmployer(json: .object(["id": .string("gu"), "name": .string("GU")]))
        var p = PayProfile(); p.hourlyWage = 1200; p.transportMode = .monthly; p.transportAmount = 5000
        emp.raw = emp.raw.merging(.object(["pay": try JSONValue.from(p)]))
        XCTAssertEqual(emp.pay.hourlyWage, 1200)
        var e = MTEvent.make(title: "GU", calendarId: "c", start: t(2026, 11, 18, 18, 30), end: t(2026, 11, 18, 22), now: 0, id: "e1")
        e.employerId = "gu"
        let lines = Payroll.lines(occurrences: [EventOccurrence(id: "e1", masterId: "e1", originalStart: nil, event: e, start: e.start, end: e.end, title: "GU")], employers: [emp], time: time)
        XCTAssertEqual(lines.first?.best.pay, 4200)
        // 月ごとの定額の交通費は期間に1回だけ
        XCTAssertEqual(Payroll.periodTotal(lines, profile: emp.pay), 9200)
        XCTAssertEqual(Payroll.periodTotal([], profile: emp.pay), 0)
    }

    func testOldEmployerWithoutPayDecodes() {
        let emp = MTEmployer(json: .object(["id": .string("x"), "name": .string("無印"), "pay": .object(["hourlyWage": .number(1100)])]))
        XCTAssertEqual(emp.pay.hourlyWage, 1100)
        XCTAssertEqual(emp.pay.noticeMinutes, 15)
        XCTAssertEqual(emp.pay.closingDay, 0)
    }
}

final class CleaningTests: XCTestCase {
    let time = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    func day(_ d: Int, _ h: Int = 10) -> EpochMs {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = d; c.hour = h
        return time.ms(time.calendar.date(from: c)!)
    }

    /// T-06・T-07：Yes／No／対象外の保存と、対象外を完了率に入れないこと
    func testStatusesAndCompletionExcludesSkip() throws {
        var book = CleaningBook.template()
        book.active = CleaningSession(id: "s1", startedAt: day(18), areaIds: ["bath"])
        book.active!.results = ["bath-0": .yes, "bath-1": .no, "bath-2": .skip, "bath-3": .yes]
        // 保存と読み込み（JSON を通しても状態が残る）
        let round = try JSONValue.from(book).decode(CleaningBook.self)
        XCTAssertEqual(round.active?.results["bath-2"], .skip)
        let st = round.active!.statuses(in: round.areas).map(\.status)
        XCTAssertEqual(st, [.yes, .no, .skip, .yes, .no])   // 壁は未選択 → No
        let c = CleaningSession.completion(st)
        XCTAssertEqual(c.done, 2)
        XCTAssertEqual(c.total, 4)                            // 対象外は分母に入れない
        XCTAssertEqual(c.ratio!, 0.5, accuracy: 0.0001)
        XCTAssertNil(CleaningSession.completion([.skip, .skip]).ratio)
    }

    /// T-08：清掃を記録すると次回の目標日を更新する
    func testFrequencyNextDueAndFinish() {
        XCTAssertEqual(CleanFrequency.daily.next(after: day(18), time: time), time.startOfDay(day(19)))
        XCTAssertEqual(CleanFrequency(times: 2, unit: .week).next(after: day(18), time: time), time.startOfDay(day(21)))
        XCTAssertEqual(CleanFrequency.weekly.next(after: day(18), time: time), time.startOfDay(day(25)))
        XCTAssertEqual(CleanFrequency.monthly.next(after: day(18), time: time), time.addMonths(time.startOfDay(day(18)), 1))
        XCTAssertEqual(CleanFrequency(times: 2, unit: .week).label, "週2回")
        XCTAssertEqual(CleanFrequency(times: 1, every: 3, unit: .day).label, "3日に1回")

        var book = CleaningBook.template()
        book.active = CleaningSession(id: "s1", startedAt: day(18), areaIds: ["bath"], results: ["bath-0": .yes, "bath-2": .yes])
        let s = book.finish(at: day(18, 11))
        XCTAssertNotNil(s)
        XCTAssertEqual(book.areas[0].items[0].lastDone, day(18, 11))
        XCTAssertEqual(book.areas[0].items[0].nextDue(time: time), time.startOfDay(day(19)))
        XCTAssertNil(book.areas[0].items[1].lastDone)        // No は更新しない
        XCTAssertEqual(book.history.count, 1)
        XCTAssertNil(book.finish(at: day(18, 12)))           // 二度目は何もしない（重複しない）
        XCTAssertEqual(book.history.count, 1)
        // 3日後：浴槽（毎日）は2日遅れ、排水口（週2回 → 11/21）は遅れなし
        XCTAssertEqual(book.areas[0].items[0].overdueDays(now: day(21), time: time), 2)
        XCTAssertEqual(book.areas[0].items[2].overdueDays(now: day(21), time: time), 0)
        XCTAssertTrue(book.neglected(now: day(21), time: time).contains { $0.item.id == "bath-0" })
    }
}

final class MorningTests: XCTestCase {
    let time = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    func testTemplateHas11StepsInOrder() {
        let r = MorningRoutine.template()
        XCTAssertEqual(r.steps.count, 11)
        XCTAssertEqual(r.steps.first?.name, "コンタクト")
        XCTAssertEqual(r.steps[8].name, "涙袋マーカー")
        XCTAssertEqual(r.steps.last?.name, "WSPR（ワックス・スプレー）")
    }

    /// T-09：最大3つまで
    func testMaxThreeAlarms() {
        var r = MorningRoutine.template()
        XCTAssertTrue(r.addAlarm(MorningAlarm(hour: 7, minute: 0)))
        XCTAssertTrue(r.addAlarm(MorningAlarm(hour: 7, minute: 5)))
        XCTAssertTrue(r.addAlarm(MorningAlarm(hour: 7, minute: 10)))
        XCTAssertFalse(r.addAlarm(MorningAlarm(hour: 7, minute: 15)))
        XCTAssertEqual(r.alarms.count, 3)
    }

    func testAlarmNextRespectsWeekdays() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 18; c.hour = 8   // 水曜 8:00
        let now = time.ms(time.calendar.date(from: c)!)
        let daily = MorningAlarm(hour: 7, minute: 0)
        XCTAssertEqual(time.weekday(daily.next(after: now, time: time)!), 4)          // 翌日（木）
        let monOnly = MorningAlarm(hour: 7, minute: 0, weekdays: [1])
        XCTAssertEqual(time.weekday(monOnly.next(after: now, time: time)!), 1)
        var off = daily; off.enabled = false
        XCTAssertNil(off.next(after: now, time: time))
    }

    /// T-10・T-11：並べ替えた順に進み、進み具合（完了数／総数）が一致する
    func testRunProgressPauseBackAndAverages() {
        var r = MorningRoutine.template()
        r.moveStep(from: 1, to: 0)     // 洗顔を先頭へ
        XCTAssertEqual(r.steps[0].name, "洗顔")
        var run = MorningRun(id: "r1", startedAt: 0, steps: r.enabledSteps)
        XCTAssertEqual(run.current?.name, "洗顔")
        XCTAssertEqual(run.next?.name, "コンタクト")
        run.complete(now: 2 * MINUTE)
        XCTAssertEqual(run.doneCount, 1)
        run.pause(now: 3 * MINUTE)
        run.resume(now: 8 * MINUTE)                                       // 5分止めた
        run.complete(now: 10 * MINUTE)                                    // コンタクト：実質3分
        XCTAssertEqual(run.records[1].ms, 3 * MINUTE)
        XCTAssertEqual(run.elapsed(now: 10 * MINUTE), 5 * MINUTE)
        run.complete(now: 11 * MINUTE, skipped: true)
        run.back(now: 12 * MINUTE)                                        // スキップを取り消して戻る
        XCTAssertEqual(run.doneCount, 2)
        XCTAssertEqual(run.records.count, 2)
        while run.finishedAt == nil { run.complete(now: 20 * MINUTE) }
        XCTAssertEqual(run.doneCount, 11)
        r.active = run
        r.finishActive()
        XCTAssertNil(r.active)
        XCTAssertEqual(r.average(stepId: r.steps[0].id)?.ms, 2 * MINUTE)
        // 記録の無い工程は平均を出さない（推測を実測として扱わない）
        let fresh = MorningRoutine.template()
        XCTAssertNil(fresh.average(stepId: "face-0"))
        XCTAssertEqual(fresh.estimate().unknown, 11)
    }

    /// 移動時間が不明なときは出発時刻を決めない
    func testDeparture() {
        var r = MorningRoutine.template()
        for i in r.steps.indices { r.steps[i].plannedMinutes = 3 }       // 11工程 × 3分 = 33分
        let start: EpochMs = 10 * HOUR + 45 * MINUTE
        let unknown = DeparturePlan.make(eventStart: start, travelMinutes: nil, routine: r)
        XCTAssertTrue(unknown.travelUnknown)
        XCTAssertNil(unknown.leaveAt)
        let p = DeparturePlan.make(eventStart: start, travelMinutes: 75, routine: r)
        XCTAssertEqual(p.leaveAt, 9 * HOUR + 30 * MINUTE)
        XCTAssertEqual(p.prepStartAt, 8 * HOUR + 57 * MINUTE)
    }
}

final class LivePlannerTests: XCTestCase {
    func testPriorityAndDisabledAndLimit() {
        let c = [
            LiveCandidate(id: "class", kind: .classNext, showFrom: 0, showUntil: 100, start: 50),
            LiveCandidate(id: "shift", kind: .shift, showFrom: 0, showUntil: 100, start: 60),
            LiveCandidate(id: "morning", kind: .morning, showFrom: 0, showUntil: 100, start: 0),
            LiveCandidate(id: "later", kind: .task, showFrom: 200, showUntil: 300, start: 200),
        ]
        XCTAssertEqual(LivePlanner.select(c, now: 10).map(\.id), ["morning", "shift"])
        XCTAssertEqual(LivePlanner.select(c, now: 10, disabled: [.morning]).map(\.id), ["shift", "class"])
        XCTAssertEqual(LivePlanner.select(c, now: 10, limit: 1).map(\.id), ["morning"])
        XCTAssertEqual(LivePlanner.upcoming(c, now: 10, within: 1000).map(\.id), ["later"])
        XCTAssertTrue(LivePlanner.select(c, now: 150).isEmpty)
    }

    /// T-01：次の授業（終わった授業・休講の回は選ばない）
    func testNextClass() {
        func occ(_ id: String, _ s: EpochMs) -> EventOccurrence {
            let e = MTEvent.make(title: id, calendarId: "class", start: s, end: s + 90 * MINUTE, now: 0, id: id)
            return EventOccurrence(id: id, masterId: id, originalStart: nil, event: e, start: s, end: s + 90 * MINUTE, title: id)
        }
        let list = [occ("マクロ", 10 * HOUR + 45 * MINUTE), occ("演習", 13 * HOUR + 15 * MINUTE), occ("朝", 9 * HOUR)]
        let n = LivePlanner.nextClass(list, isClass: { $0.calendarId == "class" }, now: 10 * HOUR, endAfterStartMinutes: 10)
        XCTAssertEqual(n?.title, "マクロ")
        // 開始から10分たったら次の授業へ
        XCTAssertEqual(LivePlanner.nextClass(list, isClass: { _ in true }, now: 10 * HOUR + 56 * MINUTE, endAfterStartMinutes: 10)?.title, "演習")
    }
}

final class AutoDeleteTests: XCTestCase {
    func testExpiryAndRetention() {
        let now: EpochMs = 100 * DAY
        func ev(_ id: String, end: EpochMs, rec: Bool = false) -> MTEvent {
            var e = MTEvent.make(title: id, calendarId: "c", start: end - HOUR, end: end, now: 0, id: id)
            if rec { e.recurrence = RecurrenceRule(freq: .weekly) }
            return e
        }
        let events = [ev("old", end: now - 3 * DAY), ev("recent", end: now - DAY), ev("repeat", end: now - 10 * DAY, rec: true)]
        XCTAssertEqual(AutoDeleteRules.expiredEvents(events, now: now, days: 2), ["old"])
        // 2日未満の指定は2日として扱う
        XCTAssertEqual(AutoDeleteRules.expiredEvents(events, now: now, days: 1), ["old"])
        XCTAssertEqual(AutoDeleteRules.expiredEvents(events, now: now, days: 7), [])

        var done = MTTask.make(title: "done", now: 0, id: "done"); done.plannedStart = now - 5 * DAY; done.plannedEnd = now - 5 * DAY + HOUR; done.status = .done; done.actualEnd = now - 5 * DAY
        var open = MTTask.make(title: "open", now: 0, id: "open"); open.plannedStart = now - 5 * DAY; open.plannedEnd = now - 5 * DAY + HOUR
        let none = MTTask.make(title: "none", now: 0, id: "none")
        XCTAssertEqual(AutoDeleteRules.expiredTasks([done, open, none], now: now, days: 2, includeUnfinished: false), ["done"])
        XCTAssertEqual(Set(AutoDeleteRules.expiredTasks([done, open, none], now: now, days: 2, includeUnfinished: true)), ["done", "open"])

        // 片づけてから30日は残す
        XCTAssertEqual(AutoDeleteRules.purgeable(archivedAt: ["a": now - 31 * DAY, "b": now - 29 * DAY], now: now), ["a"])
    }
}

final class StrikeTests: XCTestCase {
    func testStrikeSingleAndOccurrence() throws {
        let store = InMemoryStore()
        let repo = Repository(store: store, clock: { 1000 })
        let one = MTEvent.make(title: "授業", calendarId: "c", start: 10 * HOUR, end: 11 * HOUR, now: 0, id: "one")
        try repo.saveEvent(one, isNew: true)
        try repo.setStruck(eventId: "one", originalStart: nil, struck: true)
        let occ1 = expandAll(repo.events(), from: 0, to: DAY)
        XCTAssertEqual(occ1.count, 1)                       // 消えずに残る
        XCTAssertTrue(occ1[0].isStruck)
        try repo.setStruck(eventId: "one", originalStart: nil, struck: false)
        XCTAssertFalse(expandAll(repo.events(), from: 0, to: DAY)[0].isStruck)

        var rep = MTEvent.make(title: "ゼミ", calendarId: "c", start: 10 * HOUR, end: 11 * HOUR, now: 0, id: "rep")
        rep.recurrence = RecurrenceRule(freq: .daily)
        try repo.saveEvent(rep, isNew: true)
        let first = expandAll(repo.events().filter { $0.id == "rep" }, from: 0, to: 3 * DAY)
        XCTAssertEqual(first.count, 3)
        try repo.setStruck(eventId: "rep", originalStart: first[1].originalStart, struck: true)
        let after = expandAll(repo.events().filter { $0.id == "rep" }, from: 0, to: 3 * DAY)
        XCTAssertEqual(after.count, 3)                      // その回も残る
        XCTAssertEqual(after.map(\.isStruck), [false, true, false])
        // Web 版との互換：JSON を通しても印が残る
        let reread = MTEvent(json: repo.events().first { $0.id == "rep" }!.json)
        XCTAssertEqual(expandAll([reread], from: 0, to: 3 * DAY).map(\.isStruck), [false, true, false])
    }
}

/// 保存の失敗を起こす保存先（故障注入）。transaction の最後で失敗し、途中の変更を取り消す
final class FailingStore: RecordStore {
    let inner = InMemoryStore()
    var fail = false
    struct DiskFull: Error {}
    func all(_ e: EntityName) -> [JSONValue] { inner.all(e) }
    func get(_ e: EntityName, id: String) -> JSONValue? { inner.get(e, id: id) }
    func put(_ e: EntityName, id: String, json: JSONValue) { inner.put(e, id: id, json: json) }
    func delete(_ e: EntityName, id: String) { inner.delete(e, id: id) }
    func appendLog(_ entry: JSONValue) { inner.appendLog(entry) }
    func logs() -> [JSONValue] { inner.logs() }
    func appendOutbox(_ entry: JSONValue) { inner.appendOutbox(entry) }
    func outbox() -> [JSONValue] { inner.outbox() }
    func settings() -> JSONValue? { inner.settings() }
    func putSettings(_ value: JSONValue) { inner.putSettings(value) }
    func transaction(_ body: () throws -> Void) throws {
        try inner.transaction { try body(); if fail { throw DiskFull() } }
    }
}

final class SaveFailureTests: XCTestCase {
    /// 保存に失敗したら、エラーを返し、元のデータを保つ（偽の成功にしない）
    func testFailedSaveKeepsPreviousData() throws {
        let store = FailingStore()
        let repo = Repository(store: store, clock: { 1 })
        let e = MTEvent.make(title: "授業", calendarId: "c", start: 0, end: HOUR, now: 0, id: "e")
        try repo.saveEvent(e, isNew: true)
        store.fail = true
        var changed = e; changed.title = "変更"
        XCTAssertThrowsError(try repo.saveEvent(changed, isNew: false))
        XCTAssertEqual(repo.events().first?.title, "授業")
        XCTAssertThrowsError(try repo.setStruck(eventId: "e", originalStart: nil, struck: true))
        XCTAssertFalse(expandAll(repo.events(), from: 0, to: DAY)[0].isStruck)
        XCTAssertThrowsError(try repo.deleteEvent("e"))
        XCTAssertEqual(repo.events().count, 1)
    }
}

final class CleanupTransactionTests: XCTestCase {
    func testCleanupIsAllOrNothing() throws {
        let store = FailingStore()
        let repo = Repository(store: store, clock: { 1 })
        try repo.saveEvent(MTEvent.make(title: "a", calendarId: "c", start: 0, end: HOUR, now: 0, id: "a"), isNew: true)
        try repo.saveEvent(MTEvent.make(title: "b", calendarId: "c", start: 0, end: HOUR, now: 0, id: "b"), isNew: true)
        // 存在しない ID が混ざる → 全部やめる
        XCTAssertThrowsError(try repo.applyCleanup(archiveEvents: ["a", "missing"], archiveTasks: [], purgeEvents: [], purgeTasks: [], at: 5))
        XCTAssertNil(repo.events().first { $0.id == "a" }?.extra?["archivedAt"])
        // 保存の失敗 → 何も変わらない
        store.fail = true
        XCTAssertThrowsError(try repo.applyCleanup(archiveEvents: ["a"], archiveTasks: [], purgeEvents: ["b"], purgeTasks: [], at: 5))
        XCTAssertEqual(repo.events().count, 2)
        store.fail = false
        try repo.applyCleanup(archiveEvents: ["a"], archiveTasks: [], purgeEvents: ["b"], purgeTasks: [], at: 5)
        XCTAssertEqual(repo.events().count, 1)
        XCTAssertEqual(repo.events().first?.extra?["archivedAt"]?.intValue, 5)
        try repo.restoreArchived(events: ["a"], tasks: [])
        XCTAssertNil(repo.events().first?.extra?["archivedAt"])
    }

    /// 30日の境界：29日は残す、31日は完全削除
    func testRetentionBoundary() {
        let now: EpochMs = 100 * DAY
        XCTAssertEqual(AutoDeleteRules.purgeable(archivedAt: ["d29": now - 29 * DAY, "d30": now - 30 * DAY, "d31": now - 31 * DAY], now: now), ["d31"])
    }
}

final class BreakBoundaryTests: XCTestCase {
    /// 境界：「4時間以上で15分・6.5時間以上で45分・8時間以上で60分」と「超」の違い
    func testInclusiveAndExclusiveBoundaries() {
        var inc = PayProfile(); inc.hourlyWage = 1000
        inc.breakRules = [BreakRule(overMinutes: 240, breakMinutes: 15, inclusive: true), BreakRule(overMinutes: 390, breakMinutes: 45, inclusive: true), BreakRule(overMinutes: 480, breakMinutes: 60, inclusive: true)]
        var exc = inc
        exc.breakRules = inc.breakRules.map { var r = $0; r.inclusive = false; return r }
        func brk(_ p: PayProfile, _ m: Int) -> Int { PayCalculator.shift(start: 0, end: EpochMs(m) * MINUTE, profile: p)!.breakMinutes }
        let cases: [(Int, Int, Int)] = [  // 勤務分, 以上の休憩, 超の休憩
            (239, 0, 0), (240, 15, 0), (241, 15, 15),
            (389, 15, 15), (390, 45, 15), (391, 45, 45),
            (419, 45, 45), (420, 45, 45), (421, 45, 45),
            (479, 45, 45), (480, 60, 45), (481, 60, 60),
        ]
        for (m, a, b) in cases {
            XCTAssertEqual(brk(inc, m), a, "以上 \(m)分")
            XCTAssertEqual(brk(exc, m), b, "超 \(m)分")
        }
        // 古いデータ（inclusive なし）は「超」として読む
        let old = try! JSONValue.parse(#"{"id":"x","overMinutes":360,"breakMinutes":45}"#).decode(BreakRule.self)
        XCTAssertFalse(old.inclusive)
    }
}
