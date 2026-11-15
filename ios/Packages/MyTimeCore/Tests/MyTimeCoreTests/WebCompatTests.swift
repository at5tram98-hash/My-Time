import XCTest
@testable import MyTimeCore

/// Web 版（TypeScript）の実際の出力と、iOS 版の結果が一致するか。
/// 基準データ Fixtures/web-compat.json は packages/domain/src/ios-fixture.test.ts が Web 版のコードで作る。
final class WebCompatTests: XCTestCase {
    var fx: JSONValue!
    let tokyo = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "web-compat", withExtension: "json", subdirectory: "Fixtures"))
        fx = try JSONValue.parse(Data(contentsOf: url))
    }

    func testCanonicalJsonAndSha256MatchWeb() throws {
        for s in fx["canonical"]!.arrayValue! {
            let v = try JSONValue.parse(s["value"]!.stringValue!)
            XCTAssertEqual(v.canonical, s["canonical"]!.stringValue!)
            XCTAssertEqual(SHA256.hex(v.canonical), s["sha256"]!.stringValue!)
        }
    }

    func testSha256KnownVectors() {
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testReadsWebTransferFileAndVerifiesChecksum() throws {
        let file = try DeviceTransfer.read(fx["transfer"]!.stringValue!)
        XCTAssertNil(file.owner)
        XCTAssertEqual(file.rows("tasks").count, 2)
        let t = MTTask(json: file.rows("tasks").first { $0["id"]?.stringValue == "task-1" }!)
        XCTAssertEqual(t.title, "統計のレポート \"引用\" \\ 改行\n😀 é")
        XCTAssertEqual(t.specType, .assignment)
        XCTAssertEqual(t.travelMinutes, 15)
        XCTAssertEqual(t.tags, ["大学", "ゼミ"])
        // 知らない項目も含めて、往復で1文字も変わらない
        XCTAssertEqual(t.json.canonical, file.rows("tasks").first { $0["id"]?.stringValue == "task-1" }!.canonical)
        for e in file.rows("events") { XCTAssertEqual(MTEvent(json: e).json.canonical, e.canonical) }
        for c in file.rows("calendars") { XCTAssertEqual(MTCalendar(json: c).json.canonical, c.canonical) }
        for s in file.rows("subtasks") { XCTAssertEqual(MTSubtask(json: s).json.canonical, s.canonical) }
    }

    func testRejectsTamperedFile() {
        let text = fx["transfer"]!.stringValue!.replacingOccurrences(of: "ゼミ", with: "ゼミX")
        XCTAssertThrowsError(try DeviceTransfer.read(text)) { XCTAssertEqual(($0 as? DeviceTransfer.TransferError)?.description, "移行ファイルの内容が壊れています") }
    }

    func testImportIsAddOnlyAndIdempotent() throws {
        let file = try DeviceTransfer.read(fx["transfer"]!.stringValue!)
        let store = InMemoryStore()
        let repo = Repository(store: store, clock: { 1 })
        try repo.ensureDefaults()
        XCTAssertEqual(try DeviceTransfer.importAddOnly(file, into: store, now: 2), 3 + 2 + 2 + 1 + 1)
        XCTAssertEqual(try DeviceTransfer.importAddOnly(file, into: store, now: 3), 0)
        XCTAssertEqual(repo.tasks().count, 2)
        XCTAssertEqual(repo.settings().laneFocus, "main")
        XCTAssertTrue(store.logs().contains { $0["id"]?.stringValue == "log-1" && $0["seq"] == nil })
        // 同じ ID で内容が違えば中止し、何も変えない
        var changed = repo.task("task-1")!
        changed.title = "別の内容"
        store.put(.task, id: "task-1", json: changed.json)
        let other = try DeviceTransfer.read(DeviceTransfer.export(store: { let s = InMemoryStore(); for e in EntityName.allCases { for r in file.rows(e.table) { s.put(e, id: r["id"]!.stringValue!, json: r) } }; return s }(), now: 9))
        let before = store.all(.event).count
        XCTAssertThrowsError(try DeviceTransfer.importAddOnly(other, into: store, now: 4))
        XCTAssertEqual(store.all(.event).count, before)
        XCTAssertEqual(repo.task("task-1")?.title, "別の内容")
    }

    func testExportIsReadableByTheSameRules() throws {
        let store = InMemoryStore()
        let repo = Repository(store: store, clock: { 1_700_000_000_000 })
        try repo.ensureDefaults()
        try repo.saveTask(MTTask.make(title: "iOS で作成", now: 1_700_000_000_000), isNew: true)
        let text = DeviceTransfer.export(store: store, now: 1_700_000_000_001)
        let file = try DeviceTransfer.read(text)
        XCTAssertEqual(file.rows("tasks").count, 1)
        XCTAssertEqual(file.rows("outbox").count, 1)
        // Web 版のスキーマで必須の null の項目を省略しない
        let t = file.rows("tasks")[0]
        for k in ["plannedStart", "plannedEnd", "assignment", "testPrep", "sourceEventId", "estimateMinutes", "manualProgress", "checkAt", "calendarId"] { XCTAssertNotNil(t[k], k) }
    }

    func testDomainResultsMatchWeb() throws {
        let file = try DeviceTransfer.read(fx["transfer"]!.stringValue!)
        let day = fx["day"]!.intValue!, now = fx["now"]!.intValue!
        let ex = fx["expect"]!
        let tasks = file.rows("tasks").map(MTTask.init)
        let task = tasks.first { $0.id == "task-1" }!
        XCTAssertEqual(idealProgress(task, now: now)!, ex["idealAtNow"]!.doubleValue!, accuracy: 1e-12)
        XCTAssertEqual(tokyo.startOfDay(tokyo.addDays(day, 1)), ex["startOfDayPlus1"]!.intValue!)
        XCTAssertEqual(tasksForDay(tasks, day: day, time: tokyo).map(\.id), ex["tasksForDay"]!.arrayValue!.map { $0.stringValue! })
        let weekly = MTEvent(json: file.rows("events").first { $0["id"]?.stringValue == "ev-1" }!)
        XCTAssertEqual(expandEvent(weekly, from: day, to: tokyo.addDays(day, 14), time: tokyo).map(\.id), ex["weeklyIds"]!.arrayValue!.map { $0.stringValue! })
        let items = ex["layout"]!.arrayValue!.map { TimedItem(id: $0["item"]!["id"]!.stringValue!, start: $0["item"]!["start"]!.intValue!, end: $0["item"]!["end"]!.intValue!) }
        let placed = layoutDay(items, day: day, time: tokyo)
        for (p, e) in zip(placed, ex["layout"]!.arrayValue!) {
            XCTAssertEqual(p.id, e["item"]!["id"]!.stringValue!)
            XCTAssertEqual([p.top, p.height, p.column, p.columns], [e["top"]!, e["height"]!, e["column"]!, e["columns"]!].map { Int($0.intValue!) })
            XCTAssertEqual([p.clippedStart, p.clippedEnd], [e["clippedStart"]!.boolValue!, e["clippedEnd"]!.boolValue!])
        }
        let started = try applyTaskAction(task, .start, at: day + 10 * HOUR + 5 * MINUTE).task
        let paused = try applyTaskAction(started, .pause, at: day + 10 * HOUR + 35 * MINUTE).task
        let wp = ex["paused"]!
        XCTAssertEqual(paused.status.rawValue, wp["status"]!.stringValue!)
        XCTAssertEqual(paused.pausedEver, wp["pausedEver"]!.boolValue!)
        XCTAssertEqual(paused.actualStart, wp["actualStart"]!.intValue!)
        XCTAssertEqual(.array(paused.intervals.map(\.json)), wp["intervals"]!)
        let sp = try XCTUnwrap(shiftPay(start: day + 18 * HOUR + 30 * MINUTE, end: day + 22 * HOUR, hourlyWage: 1300, breakMinutes: 0))
        XCTAssertEqual(sp.pay, Int(ex["shiftPay"]!["pay"]!.intValue!))
        XCTAssertEqual(sp.pay, 4550)
    }
}

/// iOS で作ったデータを書き出し、Web 版の取り込み（apps/web/src/data/ios-compat.test.ts）で読めることを確かめるための基準データを作る。
/// 作り直すとき：GEN_IOS_EXPORT=1 swift test --filter IOSExportFixture
final class IOSExportFixture: XCTestCase {
    func testWriteIOSExportFixture() throws {
        let tokyo = DomainTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        var now: EpochMs = 1_794_793_200_000
        var n = 0
        let store = InMemoryStore()
        let repo = Repository(store: store, clock: { now }, newId: { n += 1; return "ios-\(n)" })
        try repo.ensureDefaults()
        var t = MTTask.make(title: "iOSで作った課題 \"引用\" 😀", now: now, id: "ios-task-1", timeZone: "Asia/Tokyo")
        t.plannedStart = tokyo.at(day: now, hour: 14); t.plannedEnd = tokyo.at(day: now, hour: 15); t.estimateMinutes = 60
        try repo.saveTask(t, isNew: true)
        try repo.addSubtask(taskId: t.id, title: "構成")
        now += 60_000
        try repo.taskAction(t.id, .start)
        var e = MTEvent.make(title: "iOSで作った予定", calendarId: "cal-general", start: tokyo.at(day: now, hour: 18), end: tokyo.at(day: now, hour: 19), now: now, id: "ios-event-1", timeZone: "Asia/Tokyo")
        e.recurrence = RecurrenceRule(freq: .weekly, interval: 1, byWeekday: [1], until: nil)
        try repo.saveEvent(e, isNew: true)
        repo.updateSettings { $0.laneFocus = "detail" }
        let text = DeviceTransfer.export(store: store, origin: "ios-app", now: now)
        _ = try DeviceTransfer.read(text)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ios-export.json")
        if ProcessInfo.processInfo.environment["GEN_IOS_EXPORT"] == "1" { try text.write(to: url, atomically: true, encoding: .utf8) }
        // 保存済みのファイルと、今の iOS 版の出力が一致する（片方だけ変えたら失敗する）
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }
}
