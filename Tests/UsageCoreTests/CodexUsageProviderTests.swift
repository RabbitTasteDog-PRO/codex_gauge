import Darwin
import Foundation
import XCTest
@testable import UsageCore

final class CodexUsageProviderTests: XCTestCase {
    func testSnapshotUsesOneServerAndOneAccountRead() async throws {
        let fixture = try MockServer()
        defer { fixture.remove() }
        let snapshot = try await CodexUsageProvider().fetchSnapshot(executablePath: fixture.executable.path)
        XCTAssertEqual(snapshot.account?.planType, "plus")
        XCTAssertNotNil(snapshot.report)
        XCTAssertNil(snapshot.usageError)
        let messages = try String(contentsOf: fixture.messages, encoding: .utf8).components(separatedBy: .newlines)
        XCTAssertEqual(messages.filter { $0 == "START" }.count, 1)
        XCTAssertEqual(messages.filter { $0.contains("account/read") }.count, 1)
        XCTAssertEqual(messages.filter { $0.contains("account/rateLimits/read") }.count, 1)
        try await assertProcessExited(fixture)
    }

    func testSnapshotRetainsAccountWhenQuotaCannotDecode() async throws {
        let fixture = try MockServer(malformedLimits: true)
        defer { fixture.remove() }
        let snapshot = try await CodexUsageProvider().fetchSnapshot(executablePath: fixture.executable.path)
        XCTAssertEqual(snapshot.account?.type, "chatgpt")
        XCTAssertNil(snapshot.report)
        XCTAssertEqual(snapshot.usageError, .invalidResponse)
        try await assertProcessExited(fixture)
    }

    func testSignedOutSnapshotDoesNotRequestQuota() async throws {
        let fixture = try MockServer(signedOut: true)
        defer { fixture.remove() }
        let snapshot = try await CodexUsageProvider().fetchSnapshot(executablePath: fixture.executable.path)
        XCTAssertNil(snapshot.account)
        XCTAssertNil(snapshot.report)
        XCTAssertNil(snapshot.usageError)
        let messages = try String(contentsOf: fixture.messages, encoding: .utf8)
        XCTAssertFalse(messages.contains("account/rateLimits/read"))
        try await assertProcessExited(fixture)
    }

    func testProviderReadsFragmentedProtocolNotificationsAndTokens() async throws {
        let fixture = try MockServer(accountType: "chatgpt", tokenBehavior: .success, fragmentLimits: true)
        defer { fixture.remove() }

        let report = try await CodexUsageProvider().fetchUsage(executablePath: fixture.executable.path)

        XCTAssertEqual(report.accountLabel, "Codex · plus")
        XCTAssertEqual(report.limits.windows.map(\.id), ["codex/primary", "codex/secondary"])
        XCTAssertEqual(report.limits.windows.map { $0.quota.usedPercent }, [32, 18])
        XCTAssertEqual(report.tokens?.summary?.lifetimeTokens, 123456)
        XCTAssertEqual(report.tokens?.latestBucket?.startDate, "2026-10-02")
        XCTAssertEqual(report.tokens?.latestBucket?.tokens, 456)
        XCTAssertNil(report.tokenNotice)
        try await assertProcessExited(fixture)
    }

    func testAPIKeyAccountRequiresSubscriptionLogin() async throws {
        let fixture = try MockServer(accountType: "apiKey")
        defer { fixture.remove() }

        do {
            _ = try await CodexUsageProvider().fetchUsage(executablePath: fixture.executable.path)
            XCTFail("An API-key account must not be shown as a subscription account")
        } catch {
            XCTAssertEqual(error as? UsageProviderError, .subscriptionLoginRequired)
        }
        try await assertProcessExited(fixture)
    }

    func testUnsupportedTokenMethodPreservesFetchedLimits() async throws {
        let fixture = try MockServer(tokenBehavior: .unsupported)
        defer { fixture.remove() }

        let report = try await CodexUsageProvider().fetchUsage(executablePath: fixture.executable.path)

        XCTAssertEqual(report.limits.windows.first?.quota.usedPercent, 32)
        XCTAssertNil(report.tokens)
        XCTAssertNotNil(report.tokenNotice)
        try await assertProcessExited(fixture)
    }

    func testServerEOFRejectsWithoutWaitingForProviderDeadline() async throws {
        let fixture = try MockServer(accountBehavior: .disconnect)
        defer { fixture.remove() }
        let start = Date()

        do {
            _ = try await CodexUsageProvider().fetchUsage(executablePath: fixture.executable.path)
            XCTFail("A server EOF must fail the pending account request")
        } catch {
            XCTAssertEqual(error as? UsageProviderError, .disconnected)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try await assertProcessExited(fixture)
    }

    func testMalformedQuotaResultRejectsWithoutWaitingForProviderDeadline() async throws {
        let fixture = try MockServer(malformedLimits: true)
        defer { fixture.remove() }
        let start = Date()

        do {
            _ = try await CodexUsageProvider().fetchUsage(executablePath: fixture.executable.path)
            XCTFail("A string percentage must not decode as a quota")
        } catch {
            XCTAssertEqual(error as? UsageProviderError, .invalidResponse)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try await assertProcessExited(fixture)
    }

    func testRequestTimeoutClosesSessionAndChildProcess() async throws {
        let fixture = try MockServer(silent: true)
        defer { fixture.remove() }
        let client = try AppServerClient(executable: fixture.executable)
        defer { client.stop() }

        // Establish child startup before starting the short response deadline.
        _ = try await fixture.processID()

        do {
            let _: EmptyResult = try await client.request("initialize", timeout: 0.05)
            XCTFail("An unresponsive server must reach the request deadline")
        } catch {
            XCTAssertEqual(error as? UsageProviderError, .timedOut)
        }
        do {
            let _: EmptyResult = try await client.request("account/read", timeout: 0.05)
            XCTFail("A timed-out session must not send more requests")
        } catch {
            XCTAssertEqual(error as? UsageProviderError, .timedOut)
        }
        try await assertProcessExited(fixture)
    }

    func testCancellingPendingRequestClosesSessionAndChildProcess() async throws {
        let fixture = try MockServer(silent: true)
        defer { fixture.remove() }
        let client = try AppServerClient(executable: fixture.executable)
        defer { client.stop() }
        let request = Task {
            let _: EmptyResult = try await client.request("initialize", timeout: 2)
        }

        // Wait for the launched child before cancelling, so this checks active-session cleanup.
        _ = try await fixture.processID()
        try await Task.sleep(nanoseconds: 30_000_000)
        request.cancel()
        do {
            try await request.value
            XCTFail("Cancellation must propagate to the pending caller")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            let _: EmptyResult = try await client.request("account/read", timeout: 0.05)
            XCTFail("A cancelled session must stay closed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await assertProcessExited(fixture)
    }

    private struct EmptyResult: Decodable {}

    private func assertProcessExited(_ fixture: MockServer, file: StaticString = #filePath, line: UInt = #line) async throws {
        let pid = try await fixture.processID()
        for _ in 0..<100 {
            if kill(pid, 0) == -1, errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The mock app-server process was left running", file: file, line: line)
    }

    private struct MockServer {
        enum TokenBehavior { case success, unsupported }
        enum AccountBehavior { case success, disconnect }
        let directory: URL
        let executable: URL
        let pidFile: URL
        let messages: URL

        init(accountType: String = "chatgpt", tokenBehavior: TokenBehavior = .success,
             accountBehavior: AccountBehavior = .success, fragmentLimits: Bool = false,
             malformedLimits: Bool = false, silent: Bool = false, signedOut: Bool = false) throws {
            let manager = FileManager.default
            directory = manager.temporaryDirectory.appendingPathComponent("CodexGauge-mock-\(UUID().uuidString)", isDirectory: true)
            executable = directory.appendingPathComponent("mock-codex")
            pidFile = directory.appendingPathComponent("server.pid")
            messages = directory.appendingPathComponent("messages.txt")
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)

            let accountReply = accountBehavior == .disconnect ? "exit 0" : signedOut
                ? #"printf '{"id":%s,"result":{"account":null}}\n' "$request_id""#
                : #"printf '{"id":%s,"result":{"account":{"type":"ACCOUNT_TYPE","planType":"plus"}}}\n' "$request_id""#.replacingOccurrences(of: "ACCOUNT_TYPE", with: accountType)
            let limitsReply: String
            if malformedLimits {
                limitsReply = #"printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":"bad"}}}}\n' "$request_id""#
            } else {
                let start = #"printf '{"id":%s,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":32,"windowDurationMins":300},' "$request_id""#
                let end = #"printf '"secondary":{"usedPercent":18,"windowDurationMins":10080}}}}}\n'"#
                limitsReply = [start, fragmentLimits ? "/bin/sleep 0.02" : ":", end].joined(separator: "\n")
            }
            let tokenReply: String
            switch tokenBehavior {
            case .success:
                tokenReply = #"printf '{"id":%s,"result":{"summary":{"lifetimeTokens":123456,"peakDailyTokens":789},"dailyUsageBuckets":[{"startDate":"2026-10-02","tokens":456}]}}\n' "$request_id""#
            case .unsupported:
                tokenReply = #"printf '{"id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$request_id""#
            }
            // Match quoted method names instead of property order, and obtain IDs from each request.
            let script = #"""
            #!/bin/bash
            printf '%s\n' "$$" > 'PID_PATH'
            printf 'START\n' >> 'MESSAGES_PATH'
            while IFS= read -r line; do
              printf '%s\n' "$line" >> 'MESSAGES_PATH'
              case "$line" in
                *'"initialized"'*) continue ;;
              esac
              if [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                request_id="${BASH_REMATCH[1]}"
              else
                continue
              fi
              SILENT
              case "$line" in
                *'"initialize"'*)
                  printf '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":99}}}}\n'
                  printf '{"id":%s,"result":{"userAgent":"fixture"}}\n' "$request_id"
                  ;;
                *rateLimits*)
                  LIMITS_REPLY
                  ;;
                *usage*)
                  TOKEN_REPLY
                  ;;
                *account*)
                  ACCOUNT_REPLY
                  ;;
                *) exit 7 ;;
              esac
            done
            """#
                .replacingOccurrences(of: "PID_PATH", with: pidFile.path.replacingOccurrences(of: "'", with: "'\\''"))
                .replacingOccurrences(of: "MESSAGES_PATH", with: messages.path.replacingOccurrences(of: "'", with: "'\\''"))
                .replacingOccurrences(of: "SILENT", with: silent ? "continue" : ":")
                .replacingOccurrences(of: "LIMITS_REPLY", with: limitsReply)
                .replacingOccurrences(of: "TOKEN_REPLY", with: tokenReply)
                .replacingOccurrences(of: "ACCOUNT_REPLY", with: accountReply)
            do {
                try Data(script.utf8).write(to: executable)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
        }

        func processID() async throws -> pid_t {
            for _ in 0..<100 {
                if let content = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return pid
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "MockServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock server did not record its process ID"])
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
