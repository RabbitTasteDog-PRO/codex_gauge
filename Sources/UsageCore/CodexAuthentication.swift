import Foundation

/// Only public account information; credentials remain managed by Codex.
public struct CodexAccount: Codable, Sendable, Equatable {
    public let type: String
    public let email: String?
    public let planType: String?

    public init(type: String, email: String? = nil, planType: String? = nil) {
        self.type = type
        self.email = email
        self.planType = planType
    }

    public var supportsUsage: Bool {
        ["chatgpt", "chatgptAuthTokens", "agentIdentity", "personalAccessToken"].contains(type)
    }
}

struct AccountResponse: Decodable { let account: CodexAccount? }
private struct EmptyResponse: Decodable {}

public protocol CodexLoginSession: Sendable {
    var authURL: URL { get }
    func waitForCompletion() async throws
    func cancel() async throws
    func stop()
}

public protocol AccountAuthenticating: Sendable {
    func readAccount(executablePath: String?) async throws -> CodexAccount?
    func beginLogin(executablePath: String?) async throws -> any CodexLoginSession
    func logout(executablePath: String?) async throws
}

public struct CodexAuthentication: AccountAuthenticating {
    public init() {}

    public func readAccount(executablePath: String?) async throws -> CodexAccount? {
        let client = try await CodexUsageProvider().makeClient(executablePath: executablePath)
        defer { client.stop() }
        let response: AccountResponse = try await client.request("account/read", params: ["refreshToken": false])
        return response.account
    }

    /// Keep the server alive until its local browser callback has completed.
    public func beginLogin(executablePath: String?) async throws -> any CodexLoginSession {
        let client = try await CodexUsageProvider().makeClient(executablePath: executablePath)
        do {
            let response: LoginStart = try await client.request("account/login/start", params: [
                "type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"
            ])
            guard response.type == "chatgpt", !response.loginId.isEmpty,
                  let url = URL(string: response.authUrl), url.scheme == "https",
                  let host = url.host?.lowercased(),
                  host == "openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com"),
                  url.user == nil, url.password == nil else { throw UsageProviderError.invalidResponse }
            return BrowserLoginSession(client: client, loginID: response.loginId, authURL: url)
        } catch {
            client.stop()
            throw error
        }
    }

    public func logout(executablePath: String?) async throws {
        let client = try await CodexUsageProvider().makeClient(executablePath: executablePath)
        defer { client.stop() }
        let _: EmptyResponse = try await client.request("account/logout")
    }

    private struct LoginStart: Decodable {
        let type: String
        let loginId: String
        let authUrl: String
    }
}

private final class BrowserLoginSession: CodexLoginSession, @unchecked Sendable {
    let authURL: URL
    private let client: AppServerClient
    private let loginID: String
    private struct Completion: Decodable {
        let loginId: String?
        let success: Bool
    }

    init(client: AppServerClient, loginID: String, authURL: URL) {
        self.client = client
        self.loginID = loginID
        self.authURL = authURL
    }

    func waitForCompletion() async throws {
        defer { client.stop() }
        try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    for try await notification in client.notifications {
                        guard notification.method == "account/login/completed" else { continue }
                        let result = try JSONDecoder().decode(Completion.self, from: notification.data)
                        guard result.loginId == loginID else { continue }
                        guard result.success else { throw UsageProviderError.loginFailed }
                        return
                    }
                    try Task.checkCancellation()
                    throw UsageProviderError.disconnected
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 600_000_000_000)
                    throw UsageProviderError.loginTimedOut
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }, onCancel: { self.client.stop(reason: CancellationError()) })
        try Task.checkCancellation()
    }

    func cancel() async throws {
        defer { client.stop(reason: CancellationError()) }
        let _: EmptyResponse = try await client.request("account/login/cancel", params: ["loginId": loginID])
    }

    func stop() { client.stop(reason: CancellationError()) }
    deinit { client.stop() }
}
