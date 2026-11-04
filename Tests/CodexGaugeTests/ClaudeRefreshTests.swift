import Foundation
import XCTest
import UsageCore
@testable import CodexGauge

final class ClaudeRefreshTests: XCTestCase {
    @MainActor
    func testSuccessfulReadsAreThrottledAndRateLimitRetainsMarkedPreviousValues() async {
        let suite = "Claude-stale-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = SuccessThenLimitedProvider()
        var clock = Date(timeIntervalSince1970: 10_000)
        let store = UsageStore(defaults: defaults, claudeProvider: provider, now: { clock })
        store.selectedWindowID = "claude/primary"
        await store.refreshClaude()
        let lastSuccess = store.claudeLastSuccessAt
        await store.refreshClaude()
        var count = await provider.reads
        XCTAssertEqual(count, 1)
        clock.addTimeInterval(59)
        await store.refreshClaude()
        count = await provider.reads
        XCTAssertEqual(count, 1)
        clock.addTimeInterval(1)
        await store.refreshClaude()
        XCTAssertEqual(store.selectedWindow?.quota.usedPercent, 12)
        XCTAssertEqual(store.claudeLastSuccessAt, lastSuccess)
        XCTAssertNotNil(store.claudeError)
        XCTAssertNotNil(store.claudeRetryAt)
        await store.refreshClaude()
        count = await provider.reads
        XCTAssertEqual(count, 2)
    }
    @MainActor
    func testRateLimitBlocksManualAndRestartRetriesUntilDeadlineThenRecovers() async {
        let suite = "Claude-429-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = RateLimitedClaudeProvider()
        var clock = Date(timeIntervalSince1970: 10_000)
        let store = UsageStore(defaults: defaults, claudeProvider: provider, now: { clock })
        await store.refreshClaude()
        XCTAssertEqual(store.claudeRetryAt, clock.addingTimeInterval(300))
        await store.refreshClaude()
        var reads = await provider.reads
        XCTAssertEqual(reads, 1)
        let restarted = UsageStore(defaults: defaults, claudeProvider: provider, now: { clock })
        XCTAssertNotNil(restarted.claudeError)
        await restarted.refreshClaude()
        reads = await provider.reads
        XCTAssertEqual(reads, 1)
        clock.addTimeInterval(300)
        await restarted.refreshClaude()
        XCTAssertEqual(restarted.claudeRetryAt, clock.addingTimeInterval(600))
        clock.addTimeInterval(600)
        await restarted.refreshClaude()
        XCTAssertEqual(restarted.claudeRetryAt, clock.addingTimeInterval(7200))
        clock.addTimeInterval(7200)
        await restarted.refreshClaude()
        XCTAssertNil(restarted.claudeRetryAt)
        XCTAssertNil(restarted.claudeError)
        XCTAssertEqual(restarted.claudeWindows.first?.quota.usedPercent, 5)
        XCTAssertNil(defaults.object(forKey: "claudeRetryAt"))
        reads = await provider.reads
        XCTAssertEqual(reads, 4)
    }
    @MainActor
    func testExpiredClaudeValuesDisappearAndReturnAfterLoginRefresh() async {
        let suite = "Claude-refresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ChangingClaudeProvider()
        var clock = Date(timeIntervalSince1970: 10_000)
        let store = UsageStore(defaults: defaults, claudeProvider: provider, now: { clock })
        store.selectedWindowID = "claude/primary"
        await store.refreshClaude()
        XCTAssertEqual(store.selectedWindow?.quota.usedPercent, 12)
        clock.addTimeInterval(60)
        await store.refreshClaude()
        XCTAssertTrue(store.claudeWindows.isEmpty)
        XCTAssertNil(store.selectedWindow)
        XCTAssertNotNil(store.claudeError)
        XCTAssertEqual(store.selectedWindowID, "claude/primary")
        clock.addTimeInterval(60)
        await store.refreshClaude()
        XCTAssertNil(store.claudeError)
        XCTAssertEqual(store.selectedWindow?.quota.usedPercent, 74)
    }
}

private actor SuccessThenLimitedProvider: ClaudeUsageProviding {
    private(set) var reads = 0
    func fetchWindows() async throws -> [UsageWindow] {
        reads += 1
        if reads > 1 { throw ClaudeUsageError.rateLimited(retryAfter: nil) }
        return [UsageWindow(id: "claude/primary", bucketName: "Claude", kind: .primary,
                            quota: RateWindow(usedPercent: 12, windowDurationMins: 300))]
    }
}

private actor RateLimitedClaudeProvider: ClaudeUsageProviding {
    private(set) var reads = 0
    func fetchWindows() async throws -> [UsageWindow] {
        reads += 1
        if reads == 1 { throw ClaudeUsageError.rateLimited(retryAfter: nil) }
        if reads == 2 { throw ClaudeUsageError.rateLimited(retryAfter: nil) }
        if reads == 3 { throw ClaudeUsageError.rateLimited(retryAfter: 7200) }
        return [UsageWindow(id: "claude/primary", bucketName: "Claude", kind: .primary,
                            quota: RateWindow(usedPercent: 5, windowDurationMins: 300))]
    }
}

private actor ChangingClaudeProvider: ClaudeUsageProviding {
    private var reads = 0
    func fetchWindows() async throws -> [UsageWindow] {
        reads += 1
        if reads == 2 { throw ClaudeUsageError.tokenExpired }
        return [UsageWindow(id: "claude/primary", bucketName: "Claude", kind: .primary,
                            quota: RateWindow(usedPercent: reads == 1 ? 12 : 74, windowDurationMins: 300))]
    }
}
