import Foundation
import XCTest
@testable import UsageCore

final class QuotaResetTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func window(_ used: Double, id: String = "codex/primary", reset: Double = 2_000) -> UsageWindow {
        UsageWindow(id: id, bucketName: "Codex", kind: .primary,
                    quota: RateWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset))
    }

    func testInitialFullQuotaDoesNotPretendAResetOccurred() {
        var tracker = QuotaResetTracker()
        tracker.observe([window(0)], at: now)
        XCTAssertTrue(tracker.pendingWindowIDs.isEmpty)
    }

    func testManualRefillCelebratesUntilAcknowledgedAndDoesNotRepeat() {
        var tracker = QuotaResetTracker()
        tracker.observe([window(82)], at: now)
        tracker.observe([window(0)], at: now)
        XCTAssertEqual(tracker.pendingWindowIDs, ["codex/primary"])
        tracker.observe([window(0)], at: now)
        XCTAssertFalse(tracker.pendingWindowIDs.isEmpty)
        tracker.acknowledge("codex/primary")
        tracker.observe([window(0)], at: now)
        XCTAssertTrue(tracker.pendingWindowIDs.isEmpty)
    }

    func testFirstUseStopsCelebratingEvenIfRoundedLabelStillSays100Percent() {
        var tracker = QuotaResetTracker()
        tracker.observe([window(60)], at: now)
        tracker.observe([window(0)], at: now)
        tracker.observe([window(0.01)], at: now)
        XCTAssertTrue(tracker.pendingWindowIDs.isEmpty)
    }

    func testPartialRefillAndOrdinaryConsumptionDoNotStartTapping() {
        var tracker = QuotaResetTracker()
        tracker.observe([window(90)], at: now)
        tracker.observe([window(5)], at: now)
        tracker.observe([window(8)], at: now)
        XCTAssertTrue(tracker.pendingWindowIDs.isEmpty)
    }

    func testScheduledResetAtFullQuotaNeedsAnElapsedDeadline() {
        var tracker = QuotaResetTracker()
        tracker.observe([window(0, reset: 900)], at: now)
        tracker.observe([window(0, reset: 2_000)], at: now)
        XCTAssertFalse(tracker.pendingWindowIDs.isEmpty)
        tracker.acknowledge("codex/primary")
        tracker.observe([window(0, reset: 2_001)], at: now)
        XCTAssertTrue(tracker.pendingWindowIDs.isEmpty)
    }

    func testDifferentAndRemovedWindowsCannotSharePendingReset() {
        var tracker = QuotaResetTracker()
        tracker.observe([window(60)], at: now)
        tracker.observe([window(0, id: "other/primary")], at: now)
        XCTAssertTrue(tracker.pendingWindowIDs.isEmpty)
        tracker.observe([window(50, id: "other/primary")], at: now)
        tracker.observe([window(0, id: "other/primary")], at: now)
        XCTAssertEqual(tracker.pendingWindowIDs, ["other/primary"])
        tracker.observe([], at: now)
        XCTAssertTrue(tracker.pendingWindowIDs.isEmpty)
    }
}
