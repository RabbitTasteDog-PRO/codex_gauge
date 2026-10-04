import XCTest
@testable import CodexGauge

final class BackgroundActivityTests: XCTestCase {
    func testSessionWakeDoesNotResumeWhileDisplayStillSleeps() {
        var activity = BackgroundActivity()
        activity.set(.screenSleep, paused: true)
        activity.set(.inactiveSession, paused: true)
        activity.set(.inactiveSession, paused: false)
        XCTAssertFalse(activity.allowsAnimation)
        XCTAssertFalse(activity.allowsPolling)
        activity.set(.screenSleep, paused: false)
        XCTAssertTrue(activity.allowsAnimation)
        XCTAssertTrue(activity.allowsPolling)
    }

    func testReduceMotionAndLowPowerPauseAnimationWithoutStoppingQuotaRefresh() {
        var activity = BackgroundActivity()
        activity.set(.reduceMotion, paused: true)
        activity.set(.lowPowerMode, paused: true)
        XCTAssertFalse(activity.allowsAnimation)
        XCTAssertTrue(activity.allowsPolling)
        activity.set(.reduceMotion, paused: false)
        XCTAssertFalse(activity.allowsAnimation)
        activity.set(.lowPowerMode, paused: false)
        XCTAssertTrue(activity.allowsAnimation)
    }

    func testSystemWakeDoesNotClearInactiveSessionOrLowPowerMode() {
        var activity = BackgroundActivity()
        activity.set(.systemSleep, paused: true)
        activity.set(.inactiveSession, paused: true)
        activity.set(.lowPowerMode, paused: true)
        activity.set(.systemSleep, paused: false)
        XCTAssertFalse(activity.allowsPolling)
        activity.set(.inactiveSession, paused: false)
        XCTAssertTrue(activity.allowsPolling)
        XCTAssertFalse(activity.allowsAnimation)
    }
}
