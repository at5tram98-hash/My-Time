import XCTest
@testable import MyTimeCore

final class SubScheduleTests: XCTestCase {
    func item(_ id: String, _ lane: SubItem.Lane, _ s: Int, _ e: Int, done: Bool = false) -> SubItem {
        SubItem(id: id, lane: lane, title: id, startMin: s, endMin: e, done: done)
    }

    func testGapsOnlyInTheLaneAndLongEnough() {
        let xs = [item("a", .event, 0, 30), item("b", .event, 40, 60), item("c", .event, 90, 100), item("t", .task, 30, 90)]
        let g = SubSchedule.gaps(xs, lane: .event, total: 120)
        XCTAssertEqual(g.map(\.startMin), [60, 100], "10分の空きは出さない。タスクのレーンは関係ない")
        XCTAssertEqual(g.map(\.endMin), [90, 120])
        XCTAssertEqual(SubSchedule.gaps([], lane: .task, total: 60).map(\.endMin), [60], "何もなければ全体が空き")
        // 重なった札があっても、空きは重なりの終わりから
        let ov = [item("a", .event, 0, 50), item("b", .event, 10, 20)]
        XCTAssertEqual(SubSchedule.gaps(ov, lane: .event, total: 80).map(\.startMin), [50])
    }

    func testCopyFitsThisOccurrenceAndResetsDone() {
        var n = 0
        let src = [item("a", .event, 0, 30, done: true), item("b", .task, 50, 80), item("c", .event, 70, 90)]
        let out = SubSchedule.copy(src, total: 60) { n += 1; return "new\(n)" }
        XCTAssertEqual(out.map(\.title), ["a", "b"], "はみ出す札は外す")
        XCTAssertEqual(out.map(\.endMin), [30, 60], "途中で切れる札は終わりにそろえる")
        XCTAssertTrue(out.allSatisfy { !$0.done })
        XCTAssertEqual(Set(out.map(\.id)), ["new1", "new2"])
    }
}
