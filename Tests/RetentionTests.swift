// Age-based expiry of encrypted session records.
import XCTest
@testable import Autodoc

final class RetentionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, daysAgo: Double) -> Retention.SessionFile {
        .init(name: name, modified: now.addingTimeInterval(-daysAgo * 86_400))
    }

    private var files: [Retention.SessionFile] {
        [file("today.enc", daysAgo: 0),
         file("threeDays.enc", daysAgo: 3),
         file("tenDays.enc", daysAgo: 10),
         file("ancient.enc", daysAgo: 400)]
    }

    func testZeroDaysKeepsEverything() {
        XCTAssertEqual(Retention.expired(files, days: 0, now: now), [])
    }

    func testNegativeDaysKeepsEverything() {
        XCTAssertEqual(Retention.expired(files, days: -5, now: now), [])
    }

    func testExpiresOnlyOlderThanCutoff() {
        XCTAssertEqual(Retention.expired(files, days: 7, now: now),
                       ["tenDays.enc", "ancient.enc"])
    }

    func testShortWindowExpiresMore() {
        XCTAssertEqual(Retention.expired(files, days: 1, now: now),
                       ["threeDays.enc", "tenDays.enc", "ancient.enc"])
    }

    func testLongWindowExpiresNothingRecent() {
        XCTAssertEqual(Retention.expired(files, days: 365, now: now), ["ancient.enc"])
    }

    /// A file exactly at the boundary is still inside the window.
    func testExactBoundaryIsKept() {
        let boundary = [file("edge.enc", daysAgo: 7)]
        XCTAssertEqual(Retention.expired(boundary, days: 7, now: now), [])
    }

    func testEmptyInput() {
        XCTAssertEqual(Retention.expired([], days: 30, now: now), [])
    }
}
