import Foundation
import XCTest
import UsageCore
@testable import CodexGauge

final class UsageStoreAuthenticationTests: XCTestCase {
    @MainActor
    func testInterruptedInitialAccountCheckResumesLoginOnceBeforeOldReadFinishes() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = InterruptedStartupSnapshotUsage()
        let store = UsageStore(defaults: defaults, provider: provider, authentication: LoginAuthentication())
        defer { store.stop() }
        var opened = 0
        let startup = Task { await store.launch { _ in opened += 1; return true } }
        for _ in 0..<100 {
            if await provider.reads == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let initialReads = await provider.reads
        XCTAssertEqual(initialReads, 1)
        store.suspendPollingForInactivity()
        // The cancelled first read deliberately has not completed when wake arrives.
        store.resumePollingAfterInactivity()
        store.resumePollingAfterInactivity()
        try await waitUntil { store.isLoggingIn && store.loginURL != nil }
        XCTAssertEqual(opened, 1)
        let resumedReads = await provider.reads
        XCTAssertEqual(resumedReads, 2)
        await provider.finishFirstRead()
        await startup.value
        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testCancelledStartupLoginDoesNotReopenOnSleepWake() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = AlwaysSignedOutSnapshotUsage()
        let store = UsageStore(defaults: defaults, provider: provider, authentication: LoginAuthentication())
        defer { store.stop() }
        var opened = 0
        await store.launch { _ in opened += 1; return true }
        try await waitUntil { store.loginURL != nil }
        await store.cancelLogin()
        for _ in 0..<100 {
            if await provider.reads >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        store.suspendPollingForInactivity()
        store.resumePollingAfterInactivity()
        for _ in 0..<100 {
            if await provider.reads >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let reads = await provider.reads
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(store.isLoggingIn)
        XCTAssertNil(store.loginURL)
    }

    @MainActor
    func testSnapshotSignedOutLaunchAutomaticallyLogsIn() async throws {
        try await assertSnapshotLaunchLogsIn(account: nil)
    }

    @MainActor
    func testSnapshotAPIKeyLaunchAutomaticallyLogsIn() async throws {
        try await assertSnapshotLaunchLogsIn(account: CodexAccount(type: "apiKey"))
    }

    @MainActor
    private func assertSnapshotLaunchLogsIn(account: CodexAccount?) async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = LoginAuthentication(account: account)
        let provider = SnapshotUsage(snapshots: [UsageSnapshot(account: account), goodSnapshot(email: "login@example.com")])
        let store = UsageStore(defaults: defaults, provider: provider, authentication: auth)
        defer { store.stop() }
        var opened = 0
        await store.launch { _ in opened += 1; return true }
        try await waitUntil { store.isLoggingIn && store.loginURL != nil }
        XCTAssertEqual(opened, 1)
        await auth.completeLogin()
        try await waitUntil { store.report != nil }
        XCTAssertEqual(store.account?.email, "login@example.com")
        let reads = await provider.snapshotReads
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testSnapshotUnknownAccountDoesNotOpenBrowser() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults, provider: FailedSnapshotUsage(), authentication: NoAccountReadsAuthentication())
        defer { store.stop() }
        var opened = 0
        await store.launch { _ in opened += 1; return true }
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(store.hasCheckedAccount)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isLoggingIn)
    }

    @MainActor
    func testSnapshotPathDoesNotReadAccountAgain() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = SnapshotUsage(snapshots: [goodSnapshot(email: "one@example.com")])
        let store = UsageStore(defaults: defaults, provider: provider, authentication: NoAccountReadsAuthentication())
        defer { store.stop() }
        await store.refresh()
        XCTAssertEqual(store.account?.email, "one@example.com")
        XCTAssertNotNil(store.report)
        let count = await provider.snapshotReads
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testAccountChangeClearsCachedUsageEvenWhenNewQuotaFails() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = SnapshotUsage(snapshots: [goodSnapshot(email: "old@example.com"),
            UsageSnapshot(account: CodexAccount(type: "chatgpt", email: "new@example.com", planType: "plus"), usageError: .disconnected)])
        let store = UsageStore(defaults: defaults, provider: provider, authentication: NoAccountReadsAuthentication())
        defer { store.stop() }
        await store.refresh()
        XCTAssertNotNil(defaults.data(forKey: "usageCache"))
        await store.refresh()
        XCTAssertEqual(store.account?.email, "new@example.com")
        XCTAssertTrue(store.hasCheckedAccount)
        XCTAssertNil(store.report)
        XCTAssertNil(store.lastUpdated)
        XCTAssertNil(defaults.data(forKey: "usageCache"))
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testSameAccountQuotaFailureKeepsItsPreviousMetrics() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = goodSnapshot(email: "same@example.com")
        let provider = SnapshotUsage(snapshots: [snapshot, UsageSnapshot(account: snapshot.account, usageError: .timedOut)])
        let store = UsageStore(defaults: defaults, provider: provider, authentication: NoAccountReadsAuthentication())
        defer { store.stop() }
        await store.refresh()
        await store.refresh()
        XCTAssertNotNil(store.report)
        XCTAssertNotNil(defaults.data(forKey: "usageCache"))
        XCTAssertTrue(store.isStale)
    }

    @MainActor
    func testInactivityCancelsManualRefreshAndWakeRefreshesOnce() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = CancellableSnapshotUsage()
        let store = UsageStore(defaults: defaults, provider: provider, authentication: NoAccountReadsAuthentication())
        defer { store.stop() }
        let manualRefresh = Task { await store.refresh() }
        for _ in 0..<100 {
            if await provider.reads > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        store.suspendPollingForInactivity()
        await manualRefresh.value
        let cancelled = await provider.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertFalse(store.isRefreshing)
        await store.refresh()
        let suspendedReads = await provider.reads
        XCTAssertEqual(suspendedReads, 1)
        store.resumePollingAfterInactivity()
        store.resumePollingAfterInactivity()
        try await waitUntil { store.report != nil }
        let resumedReads = await provider.reads
        XCTAssertEqual(resumedReads, 2)
    }

    @MainActor
    func testStopCancelsManualRefreshAndPreventsRestart() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = CancellableSnapshotUsage()
        let store = UsageStore(defaults: defaults, provider: provider, authentication: NoAccountReadsAuthentication())
        let manualRefresh = Task { await store.refresh() }
        for _ in 0..<100 {
            if await provider.reads > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        store.stop()
        await manualRefresh.value
        store.start()
        await store.refresh()
        let reads = await provider.reads
        XCTAssertEqual(reads, 1)
        let cancelled = await provider.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertNil(store.report)
    }

    private func goodSnapshot(email: String) -> UsageSnapshot {
        UsageSnapshot(account: CodexAccount(type: "chatgpt", email: email, planType: "plus"),
                      report: UsageReport(limits: RateLimitsResponse(rateLimits: RateLimitSnapshot(primary: RateWindow(usedPercent: 25)))))
    }

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

private actor SnapshotUsage: UsageProviding, UsageSnapshotProviding {
    private var snapshots: [UsageSnapshot]
    private(set) var snapshotReads = 0
    init(snapshots: [UsageSnapshot]) { self.snapshots = snapshots }
    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot {
        snapshotReads += 1
        return snapshots.removeFirst()
    }
    func fetchUsage(executablePath: String?) async throws -> UsageReport {
        XCTFail("Snapshot-capable providers must bypass the legacy metrics method")
        throw UsageProviderError.invalidResponse
    }
}

private struct FailedSnapshotUsage: UsageProviding, UsageSnapshotProviding {
    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot { throw UsageProviderError.disconnected }
    func fetchUsage(executablePath: String?) async throws -> UsageReport { throw UsageProviderError.invalidResponse }
}

private actor InterruptedStartupSnapshotUsage: UsageProviding, UsageSnapshotProviding {
    private var continuation: CheckedContinuation<UsageSnapshot, Never>?
    private(set) var reads = 0
    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot {
        reads += 1
        if reads == 1 {
            // A late response proves wake does not wait for the old operation to finish.
            return await withCheckedContinuation { continuation = $0 }
        }
        return UsageSnapshot(account: nil)
    }
    func finishFirstRead() {
        continuation?.resume(returning: UsageSnapshot(account: nil))
        continuation = nil
    }
    func fetchUsage(executablePath: String?) async throws -> UsageReport { throw UsageProviderError.invalidResponse }
}

private actor AlwaysSignedOutSnapshotUsage: UsageProviding, UsageSnapshotProviding {
    private(set) var reads = 0
    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot {
        reads += 1
        return UsageSnapshot(account: nil)
    }
    func fetchUsage(executablePath: String?) async throws -> UsageReport { throw UsageProviderError.invalidResponse }
}

private struct NoAccountReadsAuthentication: AccountAuthenticating {
    func readAccount(executablePath: String?) async throws -> CodexAccount? {
        XCTFail("Snapshot refresh must not independently read the account")
        throw UsageProviderError.invalidResponse
    }
    func beginLogin(executablePath: String?) async throws -> any CodexLoginSession { throw UsageProviderError.loginFailed }
    func logout(executablePath: String?) async throws {}
}

private actor CancellableSnapshotUsage: UsageProviding, UsageSnapshotProviding {
    private(set) var reads = 0
    private(set) var cancelled = false
    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot {
        reads += 1
        if reads == 1 {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { cancelled = true; throw error }
        }
        return UsageSnapshot(account: CodexAccount(type: "chatgpt", planType: "plus"),
                             report: UsageReport(limits: RateLimitsResponse(rateLimits: RateLimitSnapshot(primary: RateWindow(usedPercent: 25)))))
    }
    func fetchUsage(executablePath: String?) async throws -> UsageReport { throw UsageProviderError.invalidResponse }
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
