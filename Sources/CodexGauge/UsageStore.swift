import Foundation
import Combine
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var report: UsageReport?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var account: CodexAccount?
    @Published private(set) var hasCheckedAccount = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var isCancellingLogin = false
    @Published private(set) var authError: String?
    @Published private(set) var loginURL: URL?
    @Published private(set) var shouldTerminate = false
    @Published var selectedWindowID: String {
        didSet { defaults.set(selectedWindowID, forKey: "selectedWindowID") }
    }
    @Published var executablePath: String {
        didSet { defaults.set(executablePath, forKey: "executablePath") }
    }

    private let defaults: UserDefaults
    private let snapshotProvider: any UsageSnapshotProviding
    private let authentication: any AccountAuthenticating
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<UsageSnapshot, Error>?
    private var loginTask: Task<Void, Never>?
    private var loginSession: (any CodexLoginSession)?
    private var authOperationID: UUID?
    private var refreshGeneration = 0
    private var failureCount = 0
    private var didHandleLaunch = false
    private var initialLaunchBrowser: ((URL) -> Bool)?
    private var launchDecisionTask: Task<Void, Never>?
    private var launchDecisionID: UUID?
    private var pollingSuspended = false
    private var isStopped = false

    private struct Cache: Codable {
        let report: UsageReport
        let fetchedAt: Date
    }

    init(defaults: UserDefaults = .standard, provider: any UsageProviding = CodexUsageProvider(),
         authentication: any AccountAuthenticating = CodexAuthentication()) {
        self.defaults = defaults
        snapshotProvider = (provider as? any UsageSnapshotProviding)
            ?? AuthenticatedUsageAdapter(provider: provider, authentication: authentication)
        self.authentication = authentication
        selectedWindowID = defaults.string(forKey: "selectedWindowID") ?? "codex/primary"
        executablePath = defaults.string(forKey: "executablePath") ?? ""
        if let data = defaults.data(forKey: "usageCache"), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            report = cache.report
            lastUpdated = cache.fetchedAt
        }
    }

    var windows: [UsageWindow] { report?.limits.windows ?? [] }
    var selectedWindow: UsageWindow? { windows.first { $0.id == selectedWindowID } ?? windows.first }
    var isStale: Bool { errorMessage != nil || lastUpdated.map { Date().timeIntervalSince($0) > 180 } ?? true }
    var connectionLabel: String {
        if isLoggingIn { return "로그인 대기 중" }
        if isAuthenticating { return "로그아웃 중" }
        if isRefreshing { return "갱신 중" }
        if hasCheckedAccount, account == nil { return "로그아웃됨" }
        if errorMessage != nil { return report == nil ? "연결 확인 필요" : "갱신 실패" }
        if report != nil { return isStale ? "저장된 사용량" : "연결됨" }
        return "연결 대기"
    }

    /// Check the account once per launch, then sign in or use its existing session.
    func launch(openBrowser: @escaping (URL) -> Bool) async {
        guard !didHandleLaunch, !shouldTerminate, !isStopped else { return }
        didHandleLaunch = true
        initialLaunchBrowser = openBrowser
        if let task = beginInitialLaunchDecision() { await task.value }
    }

    /// An interrupted first account check retains its login decision until activity resumes.
    private func beginInitialLaunchDecision() -> Task<Void, Never>? {
        guard initialLaunchBrowser != nil, !pollingSuspended, !isStopped,
              !shouldTerminate, !isAuthenticating else { return nil }
        if let launchDecisionTask { return launchDecisionTask }
        let operation = UUID()
        launchDecisionID = operation
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.launchDecisionID == operation {
                    self.launchDecisionTask = nil
                    self.launchDecisionID = nil
                }
            }
            let generation = self.refreshGeneration
            await self.refresh()
            guard !Task.isCancelled, self.launchDecisionID == operation,
                  generation == self.refreshGeneration, !self.pollingSuspended,
                  !self.shouldTerminate, !self.isAuthenticating, !self.isStopped,
                  let openBrowser = self.initialLaunchBrowser else { return }
            self.initialLaunchBrowser = nil
            if self.hasCheckedAccount, self.account?.supportsUsage != true {
                self.login(openBrowser: openBrowser)
            } else {
                // A real account-check error ends startup without an automatic login.
                self.start(refreshImmediately: false)
            }
        }
        launchDecisionTask = task
        return task
    }

    /// Start once and keep polling even while the menu panel is closed.
    func start(refreshImmediately: Bool = true) {
        guard pollingTask == nil, initialLaunchBrowser == nil, !shouldTerminate,
              !isAuthenticating, !pollingSuspended, !isStopped else { return }
        pollingTask = Task { [weak self] in
            if !refreshImmediately {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
            }
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let delay = min(900, 60 * (1 << min(self.failureCount, 4)))
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
                catch { return }
            }
        }
    }

    /// Cancel background work when the application terminates.
    func stop() {
        isStopped = true
        initialLaunchBrowser = nil
        pausePolling()
        authOperationID = nil
        loginSession?.stop()
        loginSession = nil
        loginTask?.cancel()
        loginTask = nil
    }

    private func pausePolling() {
        launchDecisionTask?.cancel()
        launchDecisionTask = nil
        launchDecisionID = nil
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        isRefreshing = false
    }

    /// Suspend metric work independently of browser login; wake schedules one fresh read.
    func suspendPollingForInactivity() {
        pollingSuspended = true
        pausePolling()
    }

    func resumePollingAfterInactivity() {
        guard pollingSuspended else { return }
        pollingSuspended = false
        if initialLaunchBrowser != nil { _ = beginInitialLaunchDecision() }
        else { start() }
    }

    /// Replace the cache only after a successful account-level usage query.
    func refresh() async {
        guard !isRefreshing, !isAuthenticating, !shouldTerminate, !pollingSuspended, !isStopped else { return }
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
                refreshTask = nil
            }
        }
        let path = configuredPath
        let task = Task { [snapshotProvider] in
            try await snapshotProvider.fetchSnapshot(executablePath: path)
        }
        refreshTask = task
        do {
            let snapshot = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let currentAccount = snapshot.account
            if currentAccount != account { clearUsage() }
            account = currentAccount
            hasCheckedAccount = true
            guard let currentAccount else {
                clearUsage()
                errorMessage = nil
                failureCount = 0
                return
            }
            guard currentAccount.supportsUsage else { throw UsageProviderError.subscriptionLoginRequired }
            if let error = snapshot.usageError { throw error }
            guard let newReport = snapshot.report else { throw UsageProviderError.invalidResponse }
            report = newReport
            if !newReport.limits.windows.contains(where: { $0.id == selectedWindowID }), let first = newReport.limits.windows.first {
                selectedWindowID = first.id
            }
            lastUpdated = Date()
            errorMessage = nil
            failureCount = 0
            // Persist metrics only. Account labels and credentials are never cached.
            var cachedReport = newReport
            cachedReport.accountLabel = nil
            cachedReport.tokenNotice = nil
            if let data = try? JSONEncoder().encode(Cache(report: cachedReport, fetchedAt: lastUpdated!)) {
                defaults.set(data, forKey: "usageCache")
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            failureCount += 1
            errorMessage = error.localizedDescription
        }
    }

    private var configuredPath: String? {
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func clearUsage() {
        report = nil
        lastUpdated = nil
        defaults.removeObject(forKey: "usageCache")
    }

    /// The browser owns password entry; only a short-lived auth URL is held in memory.
    func login(openBrowser: @escaping (URL) -> Bool) {
        guard !isAuthenticating, !shouldTerminate, !isStopped else { return }
        initialLaunchBrowser = nil
        pausePolling()
        let operation = UUID()
        authOperationID = operation
        isAuthenticating = true
        isLoggingIn = true
        authError = nil
        let path = configuredPath
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await authentication.beginLogin(executablePath: path)
                guard authOperationID == operation, !Task.isCancelled else { session.stop(); return }
                loginSession = session
                loginURL = session.authURL
                guard openBrowser(session.authURL) else {
                    try? await session.cancel()
                    throw UsageProviderError.loginFailed
                }
                try await session.waitForCompletion()
                try Task.checkCancellation()
                guard authOperationID == operation else { return }
                clearUsage()
            } catch is CancellationError {
                // User cancellation is a normal transition, not an error banner.
            } catch {
                if authOperationID == operation { authError = error.localizedDescription }
            }
            guard authOperationID == operation else { return }
            finishAuthentication()
            start()
        }
    }

    func cancelLogin() async {
        guard isLoggingIn, !isCancellingLogin else { return }
        isCancellingLogin = true
        initialLaunchBrowser = nil
        authOperationID = nil
        if let session = loginSession { try? await session.cancel() }
        loginTask?.cancel()
        finishAuthentication()
        start()
    }

    /// Request app termination only after the official server confirms logout.
    func logout() async {
        guard !isAuthenticating, !shouldTerminate, !isStopped else { return }
        initialLaunchBrowser = nil
        pausePolling()
        isAuthenticating = true
        authError = nil
        do {
            try await authentication.logout(executablePath: configuredPath)
            account = nil
            hasCheckedAccount = true
            clearUsage()
            errorMessage = nil
            failureCount = 0
            finishAuthentication()
            shouldTerminate = true
        } catch {
            authError = error.localizedDescription
            finishAuthentication()
            start()
        }
    }

    private func finishAuthentication() {
        loginSession?.stop()
        loginSession = nil
        loginTask = nil
        loginURL = nil
        authOperationID = nil
        isAuthenticating = false
        isLoggingIn = false
        isCancellingLogin = false
    }
}

/// Compatibility for independently injected authentication and metrics providers.
/// The production provider implements UsageSnapshotProviding and bypasses this adapter.
private struct AuthenticatedUsageAdapter: UsageSnapshotProviding {
    let provider: any UsageProviding
    let authentication: any AccountAuthenticating

    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot {
        let account = try await authentication.readAccount(executablePath: executablePath)
        try Task.checkCancellation()
        guard let account, account.supportsUsage else { return UsageSnapshot(account: account) }
        do {
            return UsageSnapshot(account: account, report: try await provider.fetchUsage(executablePath: executablePath))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return UsageSnapshot(account: account, usageError: error as? UsageProviderError ?? .invalidResponse)
        }
    }
}
