import AppKit
import XCTest
import UsageCore
@testable import CodexGauge

final class QuotaResetCelebrationTests: XCTestCase {
    @MainActor
    func testClickAcknowledgesLocallyAndNextUseAutomaticallyStops() async throws {
        let suite = "Gauge-reset-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ResetTestProvider(values: [60, 0, 0, 12, 0, 0.01])
        let store = UsageStore(defaults: defaults, provider: provider)
        await store.refresh()
        XCTAssertFalse(store.isCelebratingReset)
        await store.refresh()
        XCTAssertTrue(store.isCelebratingReset)
        store.acknowledgeQuotaReset()
        XCTAssertFalse(store.isCelebratingReset)
        let readsAfterClick = await provider.reads
        XCTAssertEqual(readsAfterClick, 2, "Acknowledging must not query or consume a reset credit")
        await store.refresh()
        XCTAssertFalse(store.isCelebratingReset)
        await store.refresh()
        await store.refresh()
        XCTAssertTrue(store.isCelebratingReset)
        await store.refresh()
        XCTAssertFalse(store.isCelebratingReset)
    }

    @MainActor
    func testChangingAccountDoesNotCelebratePreviousAccountsUsage() async {
        let suite = "Gauge-reset-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ResetTestProvider(values: [70, 0], changesAccount: true)
        let store = UsageStore(defaults: defaults, provider: provider)
        await store.refresh()
        await store.refresh()
        XCTAssertFalse(store.isCelebratingReset)
    }

    func testTapSpritesAndGreenGaugeReturnToBlueWithoutChangingFrameRate() async {
        await MainActor.run {
            let renderer = CatStatusRenderer()
            XCTAssertTrue(renderer.hasValidTapFrames)
            let reaching = renderer.tapMasks[4].pixels.indices.filter { renderer.tapMasks[4].pixels[$0] }.map { $0 % CatStatusRenderer.TapMask.width }.max() ?? 0
            XCTAssertGreaterThanOrEqual(reaching, 49, "Contact paw should reach the gauge")
            let tapping = renderer.menuFrames(remainingPercent: 100, isDark: true, celebratingReset: true)
            XCTAssertEqual(tapping.count, CatIdleCycle.frameCount)
            XCTAssertTrue(tapping[4] === renderer.menuFrames(remainingPercent: 100, isDark: true, celebratingReset: true)[4])
            XCTAssertLessThanOrEqual(Set(tapping.map { ObjectIdentifier($0) }).count, 8)
            XCTAssertNotEqual(tapping[0].tiffRepresentation, tapping[4].tiffRepresentation)
            let green = NSBitmapImageRep(data: GaugeStyle.menuImage(percent: 100, isDark: true, celebratingReset: true).tiffRepresentation!)!.colorAt(x: 14, y: 6)!.usingColorSpace(.deviceRGB)!
            let blue = NSBitmapImageRep(data: GaugeStyle.menuImage(percent: 100, isDark: true).tiffRepresentation!)!.colorAt(x: 14, y: 6)!.usingColorSpace(.deviceRGB)!
            XCTAssertGreaterThan(green.greenComponent, green.blueComponent)
            XCTAssertGreaterThan(blue.blueComponent, blue.greenComponent)
            let belowFull = renderer.menuFrames(remainingPercent: 99.99, isDark: true, celebratingReset: true)
            XCTAssertEqual(belowFull[0].tiffRepresentation, renderer.menuFrames(remainingPercent: 99.99, isDark: true)[0].tiffRepresentation)
        }
    }
}

private actor ResetTestProvider: UsageProviding, UsageSnapshotProviding {
    private var values: [Double]
    private let changesAccount: Bool
    private(set) var reads = 0
    init(values: [Double], changesAccount: Bool = false) {
        self.values = values
        self.changesAccount = changesAccount
    }
    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot {
        reads += 1
        let used = values.removeFirst()
        let account = CodexAccount(type: "chatgpt", email: changesAccount && reads > 1 ? "other@example.com" : "fixture@example.com", planType: "plus")
        return UsageSnapshot(account: account, report: UsageReport(limits: RateLimitsResponse(rateLimits: RateLimitSnapshot(
            primary: RateWindow(usedPercent: used, windowDurationMins: 10080, resetsAt: 9_999_999_999)))))
    }
    func fetchUsage(executablePath: String?) async throws -> UsageReport { throw UsageProviderError.invalidResponse }
}
