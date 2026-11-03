import Foundation
import XCTest
import UsageCore
@testable import CodexGauge

final class ClaudeRefreshTests: XCTestCase {
    @MainActor
    func testExpiredClaudeValuesDisappearAndReturnAfterLoginRefresh() async {
        let suite = "Claude-refresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ChangingClaudeProvider()
        let store = UsageStore(defaults: defaults, claudeProvider: provider)
        store.selectedWindowID = "claude/primary"
        await store.refreshClaude()
        XCTAssertEqual(store.selectedWindow?.quota.usedPercent, 12)
        await store.refreshClaude()
        XCTAssertTrue(store.claudeWindows.isEmpty)
        XCTAssertNil(store.selectedWindow)
        XCTAssertNotNil(store.claudeError)
        XCTAssertEqual(store.selectedWindowID, "claude/primary")
        await store.refreshClaude()
        XCTAssertNil(store.claudeError)
        XCTAssertEqual(store.selectedWindow?.quota.usedPercent, 74)
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
