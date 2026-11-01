import Foundation

public enum ClaudeUsageError: Error, LocalizedError, Sendable, Equatable {
    case notLoggedIn
    case keychainTimedOut
    case tokenExpired
    case unauthorized
    case requestFailed(status: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Claude Code 로그인 정보를 찾지 못했어요. 터미널에서 claude를 실행해 로그인하세요."
        case .keychainTimedOut: return "키체인 접근 허용을 기다리다 시간이 초과됐어요. 허용 창에서 '항상 허용'을 누른 뒤 새로고침하세요."
        case .tokenExpired: return "Claude Code 로그인이 만료됐어요. claude를 한 번 실행하면 다시 갱신돼요."
        case .unauthorized: return "Claude 사용량 조회 권한이 없어요. Claude Code에 구독 계정으로 로그인하세요."
        case .requestFailed(let status): return "Claude 사용량을 가져오지 못했어요. (오류 \(status))"
        case .invalidResponse: return "Claude 사용량 응답 형식을 읽지 못했어요."
        }
    }
}

public protocol ClaudeUsageProviding: Sendable {
    func fetchWindows() async throws -> [UsageWindow]
}

/// Reads Claude subscription limits with the token Claude Code already stores on this Mac.
/// The token is kept in memory for one request only; it is never refreshed, logged or cached.
public struct ClaudeUsageProvider: ClaudeUsageProviding {
    public init() {}

    public func fetchWindows() async throws -> [UsageWindow] {
        let token = try await Self.readAccessToken()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ClaudeUsageError.unauthorized }
        guard status == 200 else { throw ClaudeUsageError.requestFailed(status: status) }
        return try Self.parseWindows(data)
    }

    /// Known limit keys, in display order.
    static let limits: [(key: String, id: String, name: String, minutes: Int, kind: UsageWindow.Kind)] = [
        ("five_hour", "claude/primary", "Claude", 300, .primary),
        ("seven_day", "claude/secondary", "Claude", 10080, .secondary),
        ("seven_day_opus", "claude_opus/secondary", "Claude Opus", 10080, .secondary),
        ("seven_day_sonnet", "claude_sonnet/secondary", "Claude Sonnet", 10080, .secondary)
    ]

    public static func parseWindows(_ data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.invalidResponse
        }
        var result: [UsageWindow] = []
        for limit in limits {
            guard let entry = root[limit.key] as? [String: Any],
                  let utilization = (entry["utilization"] as? NSNumber)?.doubleValue else { continue }
            let reset = (entry["resets_at"] as? String).flatMap(parseDate)?.timeIntervalSince1970
            result.append(UsageWindow(id: limit.id, bucketName: limit.name, kind: limit.kind,
                                      quota: RateWindow(usedPercent: utilization, windowDurationMins: limit.minutes, resetsAt: reset)))
        }
        guard !result.isEmpty else { throw ClaudeUsageError.invalidResponse }
        return result
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Extract only the access token from Claude Code's stored credential JSON.
    public static func accessToken(fromCredentialJSON data: Data, now: Date = Date()) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeUsageError.notLoggedIn
        }
        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           expiresAt / 1000 < now.timeIntervalSince1970 {
            throw ClaudeUsageError.tokenExpired
        }
        return token
    }

    /// Claude Code keeps credentials in the login keychain on macOS (a file on other systems).
    /// The Apple-signed `security` tool is used so an "Always Allow" choice survives app rebuilds.
    static func readAccessToken() async throws -> String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) {
            return try accessToken(fromCredentialJSON: data)
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    // An unanswered keychain prompt must not stall Claude refreshes forever.
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeout.cancel()
                    if process.terminationStatus == 0, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ClaudeUsageError.keychainTimedOut)
                    } else {
                        continuation.resume(throwing: ClaudeUsageError.notLoggedIn)
                    }
                } catch {
                    continuation.resume(throwing: ClaudeUsageError.notLoggedIn)
                }
            }
        }
        return try accessToken(fromCredentialJSON: data)
    }
}
