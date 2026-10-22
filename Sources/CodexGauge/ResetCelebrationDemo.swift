import Foundation
import UsageCore

/// Opt-in UI preview: simulated snapshots never access a real account or consume reset credits.
actor ResetCelebrationDemoProvider: UsageProviding, UsageSnapshotProviding {
    private var reads = 0

    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot {
        reads += 1
        let used: Double = reads == 1 ? 40 : (reads == 3 ? 1 : 0)
        let report = UsageReport(limits: RateLimitsResponse(rateLimits: RateLimitSnapshot(
            limitId: "codex", primary: RateWindow(usedPercent: used, windowDurationMins: 10080,
                                                resetsAt: Date().addingTimeInterval(604800).timeIntervalSince1970))))
        return UsageSnapshot(account: CodexAccount(type: "chatgpt", planType: "demo"), report: report)
    }

    func fetchUsage(executablePath: String?) async throws -> UsageReport {
        try await fetchSnapshot(executablePath: executablePath).report!
    }
}
