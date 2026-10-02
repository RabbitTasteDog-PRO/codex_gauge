import Foundation
import XCTest
@testable import UsageCore

final class UsageModelsTests: XCTestCase {
    func testNamedBucketsTakePrecedenceOverLegacyAndKeepStableOrdering() throws {
        let response = try decodeLimits(#"""
        {
          "rateLimits": {"limitId":"legacy", "primary":{"usedPercent":99}},
          "rateLimitsByLimitId": {
            "zeta": {"limitName":"Extra", "primary":{"usedPercent":20}},
            "alpha": {"primary":{"usedPercent":10}},
            "codex": {"primary":{"usedPercent":30}, "secondary":{"usedPercent":40}}
          }
        }
        """#)

        XCTAssertEqual(response.windows.map(\.id), ["codex/primary", "codex/secondary", "alpha/primary", "zeta/primary"])
        XCTAssertEqual(response.windows.map(\.bucketName), ["Codex", "Codex", "alpha", "Extra"])
        XCTAssertEqual(response.windows.map { $0.quota.usedPercent }, [30, 40, 10, 20])
    }

    func testLegacyFallbackWorksForMissingNullAndEmptyNamedBuckets() throws {
        for namedField in ["", #", "rateLimitsByLimitId":null"#, #", "rateLimitsByLimitId":{}"#] {
            let response = try decodeLimits("""
            {"rateLimits":{"limitId":"custom", "primary":{"usedPercent":12}}\(namedField)}
            """)
            XCTAssertEqual(response.windows.map(\.id), ["custom/primary"])
            XCTAssertEqual(response.windows.first?.quota.usedPercent, 12)
        }
    }

    func testLegacyWithoutIdUsesCodexAndNullLimitsYieldNoWindows() throws {
        let legacy = try decodeLimits(#"{"rateLimits":{"primary":{"usedPercent":25}}}"#)
        XCTAssertEqual(legacy.windows.first?.id, "codex/primary")
        XCTAssertEqual(legacy.windows.first?.bucketName, "Codex")

        XCTAssertTrue(try decodeLimits(#"{"rateLimits":null,"rateLimitsByLimitId":null}"#).windows.isEmpty)
        XCTAssertTrue(try decodeLimits(#"{}"#).windows.isEmpty)
    }

    func testPrimaryAndSecondarySelectionIdsAreUniqueAcrossBuckets() throws {
        let response = try decodeLimits(#"""
        {"rateLimitsByLimitId":{
          "codex":{"limitName":"Same", "primary":{"usedPercent":1}, "secondary":{"usedPercent":2}},
          "other":{"limitName":"Same", "primary":{"usedPercent":3}, "secondary":{"usedPercent":4}}
        }}
        """#)
        let ids = response.windows.map(\.id)
        XCTAssertEqual(Set(ids).count, 4)
        XCTAssertEqual(response.windows.map(\.kind), [.primary, .secondary, .primary, .secondary])
        XCTAssertEqual(ids, ["codex/primary", "codex/secondary", "other/primary", "other/secondary"])
    }

    func testDurationLabelsUseReturnedDurationRatherThanWindowKind() {
        let cases: [(Int?, String)] = [
            (15, "15분 한도"), (90, "90분 한도"), (300, "5시간 한도"),
            (1440, "1일 한도"), (2880, "2일 한도"),
            (10080, "주간 한도"), (20160, "2주 한도")
        ]
        for (duration, expected) in cases {
            for kind in [UsageWindow.Kind.primary, .secondary] {
                let window = makeWindow(duration: duration, kind: kind)
                XCTAssertEqual(window.durationLabel, expected, "duration=\(String(describing: duration)), kind=\(kind)")
                XCTAssertEqual(window.title, "Codex · \(expected)")
            }
        }
    }

    func testUnknownOrInvalidDurationHasExplicitFallback() {
        for duration in [nil, 0, -1] as [Int?] {
            XCTAssertEqual(makeWindow(duration: duration, kind: .primary).durationLabel, "기본 한도")
            XCTAssertEqual(makeWindow(duration: duration, kind: .secondary).durationLabel, "추가 한도")
        }
    }

    func testPercentClampingAndMissingResetDoNotInventQuota() {
        XCTAssertEqual(RateWindow(usedPercent: 0).remainingPercent, 100)
        XCTAssertEqual(RateWindow(usedPercent: 19).remainingPercent, 81)
        XCTAssertEqual(RateWindow(usedPercent: 100).remainingPercent, 0)
        XCTAssertEqual(RateWindow(usedPercent: 150).remainingPercent, 0)
        XCTAssertEqual(RateWindow(usedPercent: -2).remainingPercent, 100)
        for (input, expected) in [(Double(-2), Double(0)), (0, 0), (23.5, 23.5), (100, 100), (150, 100)] {
            XCTAssertEqual(RateWindow(usedPercent: input).clampedPercent, expected)
        }
        for nonFinite in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(RateWindow(usedPercent: nonFinite).clampedPercent, 0)
        }
        XCTAssertNil(RateWindow(usedPercent: 0).resetDate)
        XCTAssertEqual(RateWindow(usedPercent: 25, resetsAt: 1_730_947_200).resetDate?.timeIntervalSince1970, 1_730_947_200)
    }

    func testNullAndMissingTokenMetricsRemainUnknown() throws {
        let nullUsage = try decodeTokens(#"{"summary":null,"dailyUsageBuckets":null}"#)
        XCTAssertNil(nullUsage.summary)
        XCTAssertNil(nullUsage.latestBucket)

        let missingMetrics = try decodeTokens(#"{"summary":{"lifetimeTokens":null},"dailyUsageBuckets":[]}"#)
        XCTAssertNil(missingMetrics.summary?.lifetimeTokens)
        XCTAssertNil(missingMetrics.summary?.peakDailyTokens)
        XCTAssertNil(missingMetrics.latestBucket)

        let missingUsage = try decodeTokens(#"{}"#)
        XCTAssertNil(missingUsage.summary)
        XCTAssertNil(missingUsage.dailyUsageBuckets)
    }

    func testLatestDailyBucketUsesDateAndPreservesServerDate() throws {
        let usage = try decodeTokens(#"""
        {"summary":{"lifetimeTokens":5000000000,"peakDailyTokens":0},
         "dailyUsageBuckets":[
           {"startDate":"2026-10-01","tokens":999999},
           {"startDate":"2026-10-02","tokens":0},
           {"startDate":"2026-09-30","tokens":123}
         ]}
        """#)
        XCTAssertEqual(usage.summary?.lifetimeTokens, 5_000_000_000)
        XCTAssertEqual(usage.summary?.peakDailyTokens, 0)
        XCTAssertEqual(usage.latestBucket?.startDate, "2026-10-02")
        XCTAssertEqual(usage.latestBucket?.tokens, 0)
    }

    func testUnknownMetadataIsIgnoredWithoutLosingKnownValues() throws {
        let limits = try decodeLimits(#"""
        {"futureMetadata":{"enabled":true},"rateLimitResetCredits":{"availableCount":4},
         "rateLimitsByLimitId":{"codex":{
           "limitId":"codex","planType":"future-plan","credits":{"remaining":12},
           "primary":{"usedPercent":18.5,"windowDurationMins":15,"resetsAt":1730947200,"futureFlag":true},
           "secondary":null}}}
        """#)
        XCTAssertEqual(limits.windows.count, 1)
        XCTAssertEqual(limits.windows.first?.quota.usedPercent, 18.5)
        XCTAssertEqual(limits.windows.first?.quota.windowDurationMins, 15)

        let tokens = try decodeTokens(#"""
        {"summary":{"lifetimeTokens":123,"longestStreakDays":7,"futureMetric":[1,2]},
         "dailyUsageBuckets":[{"startDate":"2026-10-02","tokens":12,"timezone":"UTC"}],
         "futureMetadata":"ignored"}
        """#)
        XCTAssertEqual(tokens.summary?.lifetimeTokens, 123)
        XCTAssertNil(tokens.summary?.peakDailyTokens)
        XCTAssertEqual(tokens.latestBucket?.tokens, 12)
    }

    func testUnavailableTokenMethodCanBeRepresentedWithoutDiscardingLimits() throws {
        let report = try JSONDecoder().decode(UsageReport.self, from: Data(#"""
        {"limits":{"rateLimits":{"primary":{"usedPercent":42}}},
         "tokens":null,"tokenNotice":"account/usage/read: method not found",
         "futureMetadata":{"retryable":false}}
        """#.utf8))
        XCTAssertEqual(report.limits.windows.first?.quota.usedPercent, 42)
        XCTAssertNil(report.tokens)
        XCTAssertEqual(report.tokenNotice, "account/usage/read: method not found")
    }

    private func decodeLimits(_ json: String) throws -> RateLimitsResponse {
        try JSONDecoder().decode(RateLimitsResponse.self, from: Data(json.utf8))
    }

    private func decodeTokens(_ json: String) throws -> AccountTokenUsage {
        try JSONDecoder().decode(AccountTokenUsage.self, from: Data(json.utf8))
    }

    private func makeWindow(duration: Int?, kind: UsageWindow.Kind) -> UsageWindow {
        UsageWindow(id: "codex/\(kind.rawValue)", bucketName: "Codex", kind: kind,
                    quota: RateWindow(usedPercent: 12, windowDurationMins: duration))
    }
}
