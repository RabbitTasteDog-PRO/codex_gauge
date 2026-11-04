import Foundation
import XCTest
@testable import UsageCore

final class ClaudeUsageProviderTests: XCTestCase {
    func testRetryAfterAcceptsPositiveSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ClaudeUsageProvider.retryDelay(from: "120", now: now), 120)
        XCTAssertEqual(ClaudeUsageProvider.retryDelay(from: "Thu, 01 Jan 1970 00:05:00 GMT", now: now), 300)
        XCTAssertNil(ClaudeUsageProvider.retryDelay(from: "0", now: now))
        XCTAssertNil(ClaudeUsageProvider.retryDelay(from: "invalid", now: now))
        XCTAssertNil(ClaudeUsageProvider.retryDelay(from: "inf", now: now))
    }
    func testParsesKnownLimitsInOrderAndSkipsNulls() throws {
        let json = #"""
        {"five_hour":{"utilization":12.5,"resets_at":"2026-11-01T10:00:00.123+00:00"},
         "seven_day":{"utilization":40,"resets_at":"2026-11-06T05:51:00Z"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":3,"resets_at":null}}
        """#
        let windows = try ClaudeUsageProvider.parseWindows(Data(json.utf8))
        XCTAssertEqual(windows.map(\.id), ["claude/primary", "claude/secondary", "claude_sonnet/secondary"])
        XCTAssertEqual(windows.map(\.title), ["Claude · 5시간 한도", "Claude · 주간 한도", "Claude Sonnet · 주간 한도"])
        XCTAssertEqual(windows[0].quota.remainingPercent, 87.5)
        XCTAssertNotNil(windows[0].quota.resetDate)
        XCTAssertNotNil(windows[1].quota.resetDate)
        XCTAssertNil(windows[2].quota.resetDate)
    }

    func testUnknownShapeIsInvalid() {
        XCTAssertThrowsError(try ClaudeUsageProvider.parseWindows(Data(#"{"other":1}"#.utf8)))
        XCTAssertThrowsError(try ClaudeUsageProvider.parseWindows(Data("nope".utf8)))
    }

    func testCredentialTokenExtractionAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let valid = #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":2000000}}"#
        XCTAssertEqual(try ClaudeUsageProvider.accessToken(fromCredentialJSON: Data(valid.utf8), now: now), "abc")
        let expired = #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":500000}}"#
        XCTAssertThrowsError(try ClaudeUsageProvider.accessToken(fromCredentialJSON: Data(expired.utf8), now: now)) {
            XCTAssertEqual($0 as? ClaudeUsageError, .tokenExpired)
        }
        XCTAssertThrowsError(try ClaudeUsageProvider.accessToken(fromCredentialJSON: Data("{}".utf8), now: now)) {
            XCTAssertEqual($0 as? ClaudeUsageError, .notLoggedIn)
        }
    }
}
