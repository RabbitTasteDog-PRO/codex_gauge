import Foundation
import XCTest
import UsageCore
@testable import CodexGauge

final class UsageStoreAuthenticationTests: XCTestCase {
    @MainActor
    func testSignedOutLaunchAutomaticallyLogsInAndFetchesUsageWithoutCachingEmail() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = LoginAuthentication()
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: auth)
        defer { store.stop() }
        var browserOpens = 0
        await store.launch { _ in browserOpens += 1; return true }
        try await waitUntil { store.loginURL != nil }
        XCTAssertTrue(store.isLoggingIn)
        XCTAssertEqual(browserOpens, 1)
        await auth.completeLogin()
        try await waitUntil { store.report != nil && !store.isAuthenticating }
        XCTAssertEqual(store.account?.email, "login@example.com")
        XCTAssertNil(store.loginURL)
        let cached = defaults.data(forKey: "usageCache")!
        XCTAssertFalse(String(decoding: cached, as: UTF8.self).contains("login@example.com"))
    }

    @MainActor
    func testSignedInLaunchFetchesUsageWithoutOpeningLogin() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: FakeAuthentication())
        defer { store.stop() }
        var browserOpens = 0
        await store.launch { _ in browserOpens += 1; return true }
        XCTAssertNotNil(store.report)
        XCTAssertNotNil(store.account)
        XCTAssertEqual(browserOpens, 0)
        XCTAssertFalse(store.isLoggingIn)
    }

    @MainActor
    func testAPIKeyLaunchStartsChatGPTLogin() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = LoginAuthentication(account: CodexAccount(type: "apiKey"))
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: auth)
        defer { store.stop() }
        var browserOpens = 0
        await store.launch { _ in browserOpens += 1; return true }
        try await waitUntil { store.loginURL != nil }
        XCTAssertEqual(browserOpens, 1)
        XCTAssertNil(store.report)
        await auth.completeLogin()
        try await waitUntil { store.report != nil }
        XCTAssertTrue(store.account?.supportsUsage == true)
    }

    @MainActor
    func testUnknownAccountOnLaunchShowsErrorWithoutOpeningBrowser() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: LoginAuthentication(failsAccountRead: true))
        defer { store.stop() }
        var browserOpens = 0
        await store.launch { _ in browserOpens += 1; return true }
        XCTAssertFalse(store.hasCheckedAccount)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(browserOpens, 0)
        XCTAssertFalse(store.shouldTerminate)
    }

    @MainActor
    func testCancelledStartupLoginIsNotRepeatedOnReopen() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: LoginAuthentication())
        defer { store.stop() }
        var browserOpens = 0
        await store.launch { _ in browserOpens += 1; return true }
        try await waitUntil { store.loginURL != nil }
        await store.cancelLogin()
        await store.launch { _ in browserOpens += 1; return true }
        XCTAssertEqual(browserOpens, 1)
        XCTAssertFalse(store.isAuthenticating)
    }

    @MainActor
    func testLoginCancellationReturnsToSignedOutStateWithoutError() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: LoginAuthentication())
        defer { store.stop() }
        store.login { _ in true }
        try await waitUntil { store.loginURL != nil }
        await store.cancelLogin()
        XCTAssertFalse(store.isAuthenticating)
        XCTAssertFalse(store.isLoggingIn)
        XCTAssertNil(store.loginURL)
        XCTAssertNil(store.authError)
        XCTAssertNil(store.report)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Authentication state did not settle")
    }

    @MainActor
    func testLogoutClearsUsageAndCache() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = FakeAuthentication()
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: auth)
        defer { store.stop() }
        await store.refresh()
        XCTAssertNotNil(defaults.data(forKey: "usageCache"))
        await store.logout()
        XCTAssertNil(store.account)
        XCTAssertNil(store.report)
        XCTAssertNil(store.lastUpdated)
        XCTAssertNil(defaults.data(forKey: "usageCache"))
        XCTAssertTrue(store.hasCheckedAccount)
        XCTAssertTrue(store.shouldTerminate)
        await store.refresh()
        await store.launch { _ in XCTFail("Logout must not start another login"); return false }
        XCTAssertNil(store.report)
    }

    @MainActor
    func testFailedLogoutKeepsAccountAndMetrics() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = FakeAuthentication(failsLogout: true)
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: auth)
        defer { store.stop() }
        await store.refresh()
        await store.logout()
        XCTAssertNotNil(store.account)
        XCTAssertNotNil(store.report)
        XCTAssertNotNil(store.authError)
        XCTAssertNotNil(defaults.data(forKey: "usageCache"))
        XCTAssertFalse(store.shouldTerminate)
    }

    @MainActor
    func testOldRefreshCannotRestoreMetricsAfterLogout() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = DeferredUsage()
        let store = UsageStore(defaults: defaults, provider: provider, authentication: FakeAuthentication())
        defer { store.stop() }
        let refresh = Task { await store.refresh() }
        for _ in 0..<100 {
            if await provider.hasStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await provider.hasStarted
        XCTAssertTrue(started)
        await store.logout()
        await provider.complete()
        await refresh.value
        XCTAssertNil(store.report)
        XCTAssertNil(store.account)
        XCTAssertNil(defaults.data(forKey: "usageCache"))
    }

    @MainActor
    func testExternalLogoutClearsPreviousMetrics() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = FakeAuthentication()
        let store = UsageStore(defaults: defaults, provider: ImmediateUsage(), authentication: auth)
        defer { store.stop() }
        await store.refresh()
        try await auth.logout(executablePath: nil)
        await store.refresh()
        XCTAssertNil(store.report)
        XCTAssertNil(store.account)
        XCTAssertEqual(store.connectionLabel, "로그아웃됨")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "Gauge-auth-store-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private actor FakeAuthentication: AccountAuthenticating {
    private var account: CodexAccount? = CodexAccount(type: "chatgpt", email: "test@example.com", planType: "plus")
    private let failsLogout: Bool
    init(failsLogout: Bool = false) { self.failsLogout = failsLogout }
    func readAccount(executablePath: String?) async throws -> CodexAccount? { account }
    func beginLogin(executablePath: String?) async throws -> any CodexLoginSession { throw UsageProviderError.loginFailed }
    func logout(executablePath: String?) async throws {
        if failsLogout { throw UsageProviderError.disconnected }
        account = nil
    }
}

private struct ImmediateUsage: UsageProviding {
    func fetchUsage(executablePath: String?) async throws -> UsageReport {
        UsageReport(limits: RateLimitsResponse(rateLimits: RateLimitSnapshot(primary: RateWindow(usedPercent: 25))))
    }
}

private actor DeferredUsage: UsageProviding {
    private var continuation: CheckedContinuation<UsageReport, Never>?
    private(set) var hasStarted = false
    func fetchUsage(executablePath: String?) async throws -> UsageReport {
        await withCheckedContinuation {
            continuation = $0
            hasStarted = true
        }
    }
    func complete() {
        continuation?.resume(returning: UsageReport(limits: RateLimitsResponse(rateLimits: RateLimitSnapshot(primary: RateWindow(usedPercent: 90)))))
        continuation = nil
    }
}

private actor LoginAuthentication: AccountAuthenticating {
    private var account: CodexAccount?
    private let failsAccountRead: Bool
    private let session = ControlledLoginSession()
    init(account: CodexAccount? = nil, failsAccountRead: Bool = false) {
        self.account = account
        self.failsAccountRead = failsAccountRead
    }
    func readAccount(executablePath: String?) async throws -> CodexAccount? {
        if failsAccountRead { throw UsageProviderError.disconnected }
        return account
    }
    func beginLogin(executablePath: String?) async throws -> any CodexLoginSession { session }
    func logout(executablePath: String?) async throws { account = nil }
    func completeLogin() {
        account = CodexAccount(type: "chatgpt", email: "login@example.com", planType: "plus")
        session.succeed()
    }
}

private final class ControlledLoginSession: CodexLoginSession, @unchecked Sendable {
    let authURL = URL(string: "https://auth.openai.com/authorize?state=fixture")!
    private let events: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    init() {
        var sink: AsyncStream<Bool>.Continuation!
        events = AsyncStream { sink = $0 }
        continuation = sink
    }
    func waitForCompletion() async throws {
        for await _ in events { return }
        throw CancellationError()
    }
    func cancel() async throws { continuation.finish() }
    func stop() { continuation.finish() }
    func succeed() { continuation.yield(true) }
}
