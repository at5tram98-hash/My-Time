import XCTest
@testable import MyTimeCore

/// Create Studio：Web 版 studio.test.ts と同じ進捗の計算と、保存（版・履歴・隠す）
final class StudioTests: XCTestCase {
    private func type(_ mode: StudioProgressMode, fields: [StudioField], fieldId: String? = nil, target: Double? = nil) -> StudioType {
        var t = StudioType.make(name: "読書", target: "task", now: 0, id: "s1")
        t.fields = fields
        t.progress = StudioProgress(mode: mode, fieldId: fieldId, target: target)
        return t
    }

    func testNumberProgressAndOver() {
        let f = StudioField(id: "p", type: .number, label: "ページ", sectionId: "main", unit: "page")
        let t = type(.number, fields: [f], fieldId: "p", target: 100)
        let a = studioProgress(t, values: ["p": .number(20)])
        XCTAssertEqual(a.value, 0.2); XCTAssertEqual(a.label, "20/100ページ"); XCTAssertFalse(a.over)
        let b = studioProgress(t, values: ["p": .number(150)])
        XCTAssertEqual(b.value, 1); XCTAssertTrue(b.over)
        // 目標が0なら割らない
        XCTAssertNil(studioProgress(type(.number, fields: [f], fieldId: "p", target: 0), values: ["p": .number(5)]).value)
    }

    func testChecklistAndManual() {
        let c1 = StudioField(id: "a", type: .check, label: "A", sectionId: "main")
        let c2 = StudioField(id: "b", type: .check, label: "B", sectionId: "main")
        let t = type(.checklist, fields: [c1, c2])
        XCTAssertEqual(studioProgress(t, values: ["a": .bool(true)]).label, "1/2項目")
        let m = StudioField(id: "m", type: .progress, label: "進捗", sectionId: "main")
        XCTAssertEqual(studioProgress(type(.manual, fields: [m], fieldId: "m"), values: ["m": .number(45)]).value, 0.45)
    }

    func testSaveBumpsVersionKeepsRevisionsAndHides() throws {
        let store = InMemoryStore()
        let repo = Repository(store: store, clock: { 1000 })
        var t = StudioType.make(name: "読書", target: "task", now: 0, id: "s1")
        t.fields = [StudioField(id: "p", type: .number, label: "ページ", sectionId: "main")]
        try repo.saveStudioType(t, isNew: true)
        var u = repo.studioTypes()[0]
        u.name = "読書記録"
        try repo.saveStudioType(u, isNew: false)
        let saved = repo.studioTypes()[0]
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.raw["revisions"]?.arrayValue?.count, 1)
        XCTAssertEqual(saved.fields.first?.label, "ページ")
        try repo.hideStudioType("s1")
        XCTAssertEqual(repo.studioTypes()[0].status, "hidden")
        // 名前のない項目・同じ名前の項目は保存しない
        var bad = saved; bad.fields.append(StudioField(id: "q", type: .text, label: "ページ", sectionId: "main"))
        XCTAssertThrowsError(try repo.saveStudioType(bad, isNew: false))
    }
}
