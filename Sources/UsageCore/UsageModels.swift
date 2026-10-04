import Foundation

public struct RateWindow: Codable, Sendable, Equatable {
    public var usedPercent: Double
    public var windowDurationMins: Int?
    public var resetsAt: TimeInterval?

    public init(usedPercent: Double, windowDurationMins: Int? = nil, resetsAt: TimeInterval? = nil) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var clampedPercent: Double { min(100, max(0, usedPercent.isFinite ? usedPercent : 0)) }
    /// Show the available quota shrinking from full to empty as usage increases.
    public var remainingPercent: Double { 100 - clampedPercent }
    public var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }
}

public struct RateLimitSnapshot: Codable, Sendable, Equatable {
    public var limitId: String?
    public var limitName: String?
    public var primary: RateWindow?
    public var secondary: RateWindow?

    public init(limitId: String? = nil, limitName: String? = nil, primary: RateWindow? = nil, secondary: RateWindow? = nil) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
    }
}

public struct RateLimitsResponse: Codable, Sendable, Equatable {
    public var rateLimits: RateLimitSnapshot?
    public var rateLimitsByLimitId: [String: RateLimitSnapshot]?

    public init(rateLimits: RateLimitSnapshot? = nil, rateLimitsByLimitId: [String: RateLimitSnapshot]? = nil) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }

    /// Prefer the named quota buckets and retain the legacy response as a fallback.
    public var windows: [UsageWindow] {
        var buckets = rateLimitsByLimitId ?? [:]
        if buckets.isEmpty, let legacy = rateLimits { buckets[legacy.limitId ?? "codex"] = legacy }
        let keys = buckets.keys.sorted {
            if $0 == "codex" { return $1 != "codex" }
            if $1 == "codex" { return false }
            return $0 < $1
        }
        var result: [UsageWindow] = []
        for key in keys {
            guard let snapshot = buckets[key] else { continue }
            let name = snapshot.limitName.flatMap { $0.isEmpty ? nil : $0 } ?? (key == "codex" ? "Codex" : key)
            if let primary = snapshot.primary { result.append(UsageWindow(id: key + "/primary", bucketName: name, kind: .primary, quota: primary)) }
            if let secondary = snapshot.secondary { result.append(UsageWindow(id: key + "/secondary", bucketName: name, kind: .secondary, quota: secondary)) }
        }
        return result
    }
}

public struct UsageWindow: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case primary, secondary }
    public let id: String
    public let bucketName: String
    public let kind: Kind
    public let quota: RateWindow

    public init(id: String, bucketName: String, kind: Kind, quota: RateWindow) {
        self.id = id
        self.bucketName = bucketName
        self.kind = kind
        self.quota = quota
    }

    public var title: String { bucketName + " · " + durationLabel }

    /// Use the server's window duration instead of assuming fixed subscription limits.
    public var durationLabel: String {
        guard let minutes = quota.windowDurationMins, minutes > 0 else { return kind == .primary ? "기본 한도" : "추가 한도" }
        if minutes % 10080 == 0 { return minutes == 10080 ? "주간 한도" : "\(minutes / 10080)주 한도" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)일 한도" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간 한도" }
        return "\(minutes)분 한도"
    }
}

public struct AccountTokenUsage: Codable, Sendable, Equatable {
    public struct Summary: Codable, Sendable, Equatable {
        public var lifetimeTokens: Int64?
        public var peakDailyTokens: Int64?
    }
    public struct DailyBucket: Codable, Sendable, Equatable {
        public var startDate: String
        public var tokens: Int64
    }
    public var summary: Summary?
    public var dailyUsageBuckets: [DailyBucket]?

    /// Keep the date returned by the service visible; its daily timezone is not assumed.
    public var latestBucket: DailyBucket? { dailyUsageBuckets?.max { $0.startDate < $1.startDate } }
}

public struct UsageReport: Codable, Sendable, Equatable {
    public var limits: RateLimitsResponse
    public var tokens: AccountTokenUsage?
    public var tokenNotice: String?
    public var accountLabel: String?

    public init(limits: RateLimitsResponse, tokens: AccountTokenUsage? = nil, tokenNotice: String? = nil, accountLabel: String? = nil) {
        self.limits = limits
        self.tokens = tokens
        self.tokenNotice = tokenNotice
        self.accountLabel = accountLabel
    }
}

public protocol UsageProviding: Sendable {
    func fetchUsage(executablePath: String?) async throws -> UsageReport
}

/// Preserve a successful account read even when its subsequent quota request fails.
public struct UsageSnapshot: Sendable {
    public let account: CodexAccount?
    public let report: UsageReport?
    public let usageError: UsageProviderError?

    public init(account: CodexAccount?, report: UsageReport? = nil, usageError: UsageProviderError? = nil) {
        self.account = account
        self.report = report
        self.usageError = usageError
    }
}

public protocol UsageSnapshotProviding: Sendable {
    /// Throw only when the account itself could not be checked, or the operation was cancelled.
    func fetchSnapshot(executablePath: String?) async throws -> UsageSnapshot
}
