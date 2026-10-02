import Foundation
import XCTest
@testable import UsageCore

final class CodexAuthenticationTests: XCTestCase {
    func testAccountCanBeSignedOut() async throws {
        let fixture = try AuthFixture(mode: "signedOut")
        defer { fixture.remove() }
        let account = try await CodexAuthentication().readAccount(executablePath: fixture.executable.path)
        XCTAssertNil(account)
    }

    func testAccountReadsPublicIdentityOnly() async throws {
        let fixture = try AuthFixture()
        defer { fixture.remove() }
        let account = try await CodexAuthentication().readAccount(executablePath: fixture.executable.path)
        XCTAssertEqual(account?.email, "test@example.com")
        XCTAssertEqual(account?.planType, "plus")
    }

    func testEarlyCompletionIsBufferedAndWrongLoginIDIsIgnored() async throws {
        let fixture = try AuthFixture(mode: "success")
        defer { fixture.remove() }
        let session = try await CodexAuthentication().beginLogin(executablePath: fixture.executable.path)
        defer { session.stop() }
        XCTAssertEqual(session.authURL.host, "auth.openai.com")
        try await session.waitForCompletion()
    }

    func testFailureDoesNotExposeServerError() async throws {
        let fixture = try AuthFixture(mode: "failure")
        defer { fixture.remove() }
        let session = try await CodexAuthentication().beginLogin(executablePath: fixture.executable.path)
        defer { session.stop() }
        do {
            try await session.waitForCompletion()
            XCTFail("Failed login should reject")
        } catch {
            XCTAssertEqual(error as? UsageProviderError, .loginFailed)
            XCTAssertFalse(error.localizedDescription.contains("private-server-detail"))
        }
    }

    func testCancelUsesMatchingLoginIDAndEndsWait() async throws {
        let fixture = try AuthFixture(mode: "pending")
        defer { fixture.remove() }
        let session = try await CodexAuthentication().beginLogin(executablePath: fixture.executable.path)
        defer { session.stop() }
        let wait = Task { try await session.waitForCompletion() }
        try await session.cancel()
        do { try await wait.value; XCTFail("Cancelled login should not succeed") }
        catch { /* Either cancellation or server failure can arrive first. */ }
        let messages = try String(contentsOf: fixture.messages, encoding: .utf8)
        XCTAssertTrue(messages.contains("account/login/cancel"))
        XCTAssertTrue(messages.contains("fixture-login"))
    }

    func testLogoutCallsOfficialMethod() async throws {
        let fixture = try AuthFixture()
        defer { fixture.remove() }
        try await CodexAuthentication().logout(executablePath: fixture.executable.path)
        let messages = try String(contentsOf: fixture.messages, encoding: .utf8)
        XCTAssertTrue(messages.contains("account/logout"))
    }

    func testRejectsUnexpectedLoginURL() async throws {
        let fixture = try AuthFixture(mode: "badURL")
        defer { fixture.remove() }
        do {
            _ = try await CodexAuthentication().beginLogin(executablePath: fixture.executable.path)
            XCTFail("Unexpected website must not be opened")
        } catch { XCTAssertEqual(error as? UsageProviderError, .invalidResponse) }
    }
}

private struct AuthFixture {
    let directory: URL
    let executable: URL
    let messages: URL

    init(mode: String = "default") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Gauge-auth-test-\(UUID().uuidString)")
        executable = directory.appendingPathComponent("mock-codex")
        messages = directory.appendingPathComponent("requests.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/bash
        while IFS= read -r line; do
          printf '%s\n' "$line" >> 'MESSAGES'
          [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*([0-9]+) ]] || continue
          request_id="${BASH_REMATCH[1]}"
          case "$line" in
            *'"initialize"'*) printf '{"id":%s,"result":{}}\n' "$request_id" ;;
            *'account/login/start'*)
              printf '{"method":"account/login/completed","params":{"loginId":"other-login","success":false}}\n'
              if [ 'MODE' = success ] || [ 'MODE' = failure ]; then
                result=true
                [ 'MODE' = failure ] && result=false
                printf '{"method":"account/login/completed","params":{"loginId":"fixture-login","success":%s,"error":"private-server-detail"}}\n' "$result"
              fi
              url='https://auth.openai.com/authorize?state=fixture'
              [ 'MODE' = badURL ] && url='https://openai.com.example.org/authorize'
              printf '{"id":%s,"result":{"type":"chatgpt","loginId":"fixture-login","authUrl":"%s"}}\n' "$request_id" "$url"
              ;;
            *'account/login/cancel'*) printf '{"id":%s,"result":{"status":"canceled"}}\n' "$request_id" ;;
            *'account/logout'*) printf '{"id":%s,"result":{}}\n' "$request_id" ;;
            *'account/read'*)
              account='{"type":"chatgpt","email":"test@example.com","planType":"plus"}'
              [ 'MODE' = signedOut ] && account=null
              printf '{"id":%s,"result":{"account":%s}}\n' "$request_id" "$account"
              ;;
          esac
        done
        """#
            .replacingOccurrences(of: "MESSAGES", with: messages.path.replacingOccurrences(of: "'", with: "'\\''"))
            .replacingOccurrences(of: "MODE", with: mode)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
