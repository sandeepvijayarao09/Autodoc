// Edge cases for the activity-driven capture policy.
import XCTest
@testable import Autodoc

final class TriggerPolicyTests: XCTestCase {

    private let policy = TriggerPolicy(minInterval: 15, debounce: 2,
                                       maxActive: 60, activityWindow: 2)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }

    private func decide(now: TimeInterval, idle: TimeInterval,
                        appSwitch: TimeInterval? = nil,
                        lastEmit: TimeInterval, firstInput: TimeInterval?) -> String? {
        policy.decide(ActivitySnapshot(now: at(now), idleSeconds: idle,
                                       lastAppSwitch: appSwitch.map(at)),
                      lastEmit: at(lastEmit), firstInputSinceEmit: firstInput.map(at))
    }

    // MARK: - Core behaviours

    func testIdleNeverCaptures() {
        XCTAssertNil(decide(now: 100, idle: 500, lastEmit: 0, firstInput: nil))
    }

    func testRateLimitFloor() {
        XCTAssertNil(decide(now: 3, idle: 0.1, lastEmit: 0, firstInput: 1))
    }

    func testAppSwitchCaptures() {
        XCTAssertEqual(decide(now: 20, idle: 0.1, appSwitch: 19,
                              lastEmit: 0, firstInput: nil), "app-switch")
    }

    func testStaleAppSwitchIgnored() {
        XCTAssertNil(decide(now: 20, idle: 0.1, appSwitch: 5,
                            lastEmit: 10, firstInput: nil))
    }

    func testInputSettledCaptures() {
        XCTAssertEqual(decide(now: 20, idle: 2.5, lastEmit: 0, firstInput: 16),
                       "input-settled")
    }

    func testStillTypingWaits() {
        XCTAssertNil(decide(now: 20, idle: 0.5, lastEmit: 0, firstInput: 16))
    }

    func testSustainedActivityForcesCapture() {
        XCTAssertEqual(decide(now: 70, idle: 0.3, lastEmit: 0, firstInput: 2),
                       "sustained-activity")
    }

    // MARK: - Boundary values

    func testFloorExactlyAtMinIntervalFires() {
        XCTAssertEqual(decide(now: 15, idle: 0.1, appSwitch: 14,
                              lastEmit: 0, firstInput: nil), "app-switch")
    }

    func testFloorJustUnderBlocks() {
        XCTAssertNil(decide(now: 14.999, idle: 0.1, appSwitch: 14,
                            lastEmit: 0, firstInput: nil))
    }

    func testDebounceExactlyFires() {
        XCTAssertEqual(decide(now: 30, idle: 2.0, lastEmit: 0, firstInput: 20),
                       "input-settled")
    }

    func testDebounceJustUnderWaits() {
        XCTAssertNil(decide(now: 30, idle: 1.999, lastEmit: 0, firstInput: 20))
    }

    func testMaxActiveExactlyForces() {
        XCTAssertEqual(decide(now: 60, idle: 0.5, lastEmit: 0, firstInput: 0),
                       "sustained-activity")
    }

    func testAppSwitchExactlyAtLastEmitIgnored() {
        XCTAssertNil(decide(now: 30, idle: 0.1, appSwitch: 10,
                            lastEmit: 10, firstInput: nil))
    }

    // MARK: - Precedence & degenerate input

    func testAppSwitchBeatsInputSettled() {
        XCTAssertEqual(decide(now: 30, idle: 5, appSwitch: 25,
                              lastEmit: 0, firstInput: 20), "app-switch")
    }

    func testActiveWithNoFirstInputAndNoSwitchDoesNotFire() {
        XCTAssertNil(decide(now: 30, idle: 0.1, lastEmit: 0, firstInput: nil))
    }

    func testFirstEverCaptureWithDistantPastLastEmit() {
        let got = policy.decide(
            ActivitySnapshot(now: at(30), idleSeconds: 3, lastAppSwitch: nil),
            lastEmit: .distantPast, firstInputSinceEmit: at(10))
        XCTAssertEqual(got, "input-settled")
    }

    func testHugeIdleNeverCaptures() {
        XCTAssertNil(decide(now: 1_000_000, idle: 999_999, lastEmit: 0, firstInput: nil))
    }

    func testMinIntervalZeroDisablesFloor() {
        let noFloor = TriggerPolicy(minInterval: 0, debounce: 2,
                                    maxActive: 60, activityWindow: 2)
        let got = noFloor.decide(
            ActivitySnapshot(now: at(0.1), idleSeconds: 0.1, lastAppSwitch: at(0.05)),
            lastEmit: at(0), firstInputSinceEmit: nil)
        XCTAssertEqual(got, "app-switch")
    }

    // MARK: - isActive

    func testIsActiveTrue() {
        XCTAssertTrue(policy.isActive(
            ActivitySnapshot(now: at(0), idleSeconds: 0.5, lastAppSwitch: nil)))
    }

    func testIsActiveFalse() {
        XCTAssertFalse(policy.isActive(
            ActivitySnapshot(now: at(0), idleSeconds: 9, lastAppSwitch: nil)))
    }

    func testIsActiveBoundaryEqualsWindowIsFalse() {
        XCTAssertFalse(policy.isActive(
            ActivitySnapshot(now: at(0), idleSeconds: 2.0, lastAppSwitch: nil)))
    }
}
