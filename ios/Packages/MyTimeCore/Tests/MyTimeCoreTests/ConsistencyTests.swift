import XCTest
@testable import MyTimeCore

/// 11/19：カレンダーの統合・種類の整合・詳細スケジュール
final class ConsistencyTests: XCTestCase {
    var now: EpochMs = 1_794_793_200_000
    var store: InMemoryStore!
    var repo: Repository!

    override func setUp() {
        store = InMemoryStore()
        repo = Repository(store: store, clock: { [unowned self] in now })
    }

    /// 旧3カレンダー＋取り込みの「みお」→「自分」「みお」の2つ。授業・アルバイトは種類を付けて残す
    func testConsolidateCalendars() throws {
        let old: [(String, String, String)] = [("cal-general", "一般", "general"), ("cal-class", "授業", "class"), ("cal-job", "アルバイト", "job"), ("tt-1", "みお", "general"), ("tt-2", "家族", "general")]
        for (i, c) in old.enumerated() {
            store.put(.calendar, id: c.0, json: .object(["id": .string(c.0), "name": .string(c.1), "kind": .string(c.2), "order": .number(Double(i))]))
        }
        let a = MTEvent.make(title: "統計", calendarId: "cal-class", start: now, end: now + HOUR, now: now)
        let b = MTEvent.make(title: "GU", calendarId: "cal-job", start: now, end: now + HOUR, now: now)
        let c = MTEvent.make(title: "デート", calendarId: "tt-1", start: now, end: now + HOUR, now: now)
        let d = MTEvent.make(title: "法事", calendarId: "tt-2", start: now, end: now + HOUR, now: now)
        for e in [a, b, c, d] { store.put(.event, id: e.id, json: e.json) }

        let r = try repo.consolidateCalendars()
        XCTAssertEqual(r.moved, 4)
        XCTAssertEqual(r.removed, 4)
        XCTAssertEqual(repo.calendars().map(\.name), ["自分", "みお"])
        XCTAssertEqual(repo.event(a.id)?.calendarId, MTCalendar.selfId)
        XCTAssertEqual(repo.event(a.id)?.specType, .class)
        XCTAssertEqual(repo.event(b.id)?.specType, .shift)
        XCTAssertEqual(repo.event(c.id)?.calendarId, MTCalendar.mioId)
        XCTAssertEqual(repo.event(d.id)?.calendarId, MTCalendar.selfId)
        XCTAssertEqual(repo.events().count, 4, "予定は消さない")
        // 2回目は何もしない
        XCTAssertEqual(try repo.consolidateCalendars().moved, 0)
    }

    /// 持ち物は種類の項目に重ねて出さない（予定の「持ち物」1か所だけ）
    func testNoDuplicateBelongingFields() {
        for d in SPEC_PICKABLE {
            let keys = d.fields.map(\.key)
            XCTAssertFalse(keys.contains("bring") || keys.contains("packing"), "\(d.name) に持ち物の項目が重なっている")
            XCTAssertEqual(Set(keys).count, keys.count, "\(d.name) に同じ項目が2つある")
            XCTAssertFalse(d.isEvent && d.isCheck, "\(d.name) は予定なのに確認タスクになっている")
        }
        XCTAssertFalse(SPEC_BY_ID[.class]!.fields.contains { $0.key == "room" }, "教室は授業の欄で入れる")
        XCTAssertFalse(SPEC_BY_ID[.shift]!.fields.contains { $0.key == "workplace" }, "勤務先は勤務先の選択で決める")
        // 選べる種類の名前は重ならない
        let names = SPEC_PICKABLE.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testDetectSpecUsesCurrentTypes() {
        XCTAssertEqual(detectSpec("部屋の掃除"), .cleaning)
        XCTAssertEqual(detectSpec("洗濯"), .chores)
        XCTAssertEqual(detectSpec("朝の準備"), .morning)
        XCTAssertEqual(detectSpec("持ち物の確認"), .belongings)
        XCTAssertNotEqual(detectSpec("本を読む"), .reading)
        for t in SPEC_PICKABLE { XCTAssertNotNil(SPEC_KEYWORDS[t.id], "\(t.name) の判定がない") }
    }

    func testSubScheduleClampColumnsAndRoundTrip() {
        XCTAssertEqual(SubSchedule.clamp(3, 22, total: 60).0, 5)
        XCTAssertEqual(SubSchedule.clamp(3, 22, total: 60).1, 20)
        XCTAssertEqual(SubSchedule.clamp(58, 80, total: 60).1, 60)
        XCTAssertEqual(SubSchedule.clamp(60, 60, total: 60).0, 55, "最後でも5分は取る")
        let xs = [SubItem(id: "a", lane: .event, title: "受付", startMin: 0, endMin: 30),
                  SubItem(id: "b", lane: .event, title: "説明", startMin: 10, endMin: 20),
                  SubItem(id: "c", lane: .task, title: "メモ", startMin: 10, endMin: 20),
                  SubItem(id: "d", lane: .event, title: "休憩", startMin: 30, endMin: 40)]
        let cols = SubSchedule.columns(xs)
        XCTAssertEqual(cols["a"]?.col, 0); XCTAssertEqual(cols["a"]?.of, 2)
        XCTAssertEqual(cols["b"]?.col, 1)
        XCTAssertEqual(cols["c"]?.of, 1, "レーンが違えば重ならない")
        XCTAssertEqual(cols["d"]?.of, 1)
        let extra = SubSchedule.write(xs, into: .object(["color": .string("#FF0000")]))
        XCTAssertEqual(SubSchedule.items(extra).map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(extra["color"]?.stringValue, "#FF0000", "ほかの項目は残す")
        XCTAssertEqual(SubSchedule.current(xs, minute: 12)?.id, "a")
        XCTAssertNil(SubSchedule.write([], into: extra)["subSchedule"])
    }

    func testBelongingSplit() {
        XCTAssertEqual(BelongingSuggest.split("財布、鍵,スマホ、財布"), ["財布", "鍵", "スマホ"])
        XCTAssertFalse(BelongingSuggest.forSpec(.class).isEmpty)
    }
}
