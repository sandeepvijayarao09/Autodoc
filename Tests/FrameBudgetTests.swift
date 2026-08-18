// Edge cases for the kept-screenshot ring buffer.
import XCTest
@testable import Autodoc

final class FrameBudgetTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func f(_ name: String, _ size: Int, _ age: TimeInterval) -> FrameBudget.FileInfo {
        .init(path: name, size: size, mtime: t0.addingTimeInterval(age))
    }

    /// Four 100-byte frames, oldest first — 400 bytes total.
    private var files: [FrameBudget.FileInfo] {
        [f("a", 100, 0), f("b", 100, 10), f("c", 100, 20), f("d", 100, 30)]
    }

    func testUnderBudgetEvictsNothing() {
        XCTAssertEqual(FrameBudget.toEvict(files, maxBytes: 400), [])
    }

    func testWayUnderBudgetEvictsNothing() {
        XCTAssertEqual(FrameBudget.toEvict(files, maxBytes: 10_000), [])
    }

    func testEvictsOldestToFit250() {
        // 400 → 300 → 200 ≤ 250
        XCTAssertEqual(FrameBudget.toEvict(files, maxBytes: 250), ["a", "b"])
    }

    func testEvictsOldestToFit100() {
        XCTAssertEqual(FrameBudget.toEvict(files, maxBytes: 100), ["a", "b", "c"])
    }

    func testJustUnderTotalEvictsOne() {
        XCTAssertEqual(FrameBudget.toEvict(files, maxBytes: 399), ["a"])
    }

    func testZeroBudgetEvictsAll() {
        XCTAssertEqual(FrameBudget.toEvict(files, maxBytes: 0), ["a", "b", "c", "d"])
    }

    func testEmptyInputEvictsNothing() {
        XCTAssertEqual(FrameBudget.toEvict([], maxBytes: 100), [])
    }

    func testEvictsByAgeNotInputOrder() {
        let shuffled = [f("new", 100, 100), f("old", 100, 0), f("mid", 100, 50)]
        XCTAssertEqual(FrameBudget.toEvict(shuffled, maxBytes: 150), ["old", "mid"])
    }
}
