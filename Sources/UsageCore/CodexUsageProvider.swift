import Foundation

public enum UsageProviderError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound
    case invalidExecutable
    case launchFailed
    case subscriptionLoginRequired
    case loginFailed
    case loginTimedOut
    case timedOut
    case disconnected
    case invalidResponse
    case rpcFailure(code: Int)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "Codex 실행 파일을 찾지 못했습니다. Codex CLI를 설치하거나 설정에서 실행 파일 경로를 지정하세요."
        case .invalidExecutable: return "지정한 경로에 실행 가능한 Codex 파일이 없습니다."
        case .launchFailed: return "Codex app-server를 시작하지 못했습니다. 실행 파일 경로를 확인하세요."
        case .subscriptionLoginRequired: return "Codex에서 ChatGPT 계정으로 로그인하세요. API 키 로그인으로는 구독 사용량을 조회할 수 없습니다."
        case .loginFailed: return "로그인을 완료하지 못했습니다. 다시 시도하세요."
        case .loginTimedOut: return "로그인 대기 시간이 초과되었습니다. 다시 로그인하세요."
        case .timedOut: return "Codex 사용량 조회 시간이 초과되었습니다. 잠시 후 다시 시도하세요."
        case .disconnected: return "Codex 사용량 조회 연결이 종료되었습니다. 다시 시도하세요."
        case .invalidResponse: return "Codex 사용량 응답 형식을 읽지 못했습니다. Codex CLI 버전을 확인하세요."
        case .rpcFailure(let code): return "Codex가 사용량 조회를 처리하지 못했습니다. (오류 \(code))"
        }
    }
}

/// Fetch quota and optional token activity without starting model inference or reading credentials.
public struct CodexUsageProvider: UsageProviding {
    public init() {}

    /// Keep quota data usable even when this server does not offer account token activity.
    public func fetchUsage(executablePath: String?) async throws -> UsageReport {
        try Task.checkCancellation()
        let client = try await makeClient(executablePath: executablePath)
        defer { client.stop() }
        let account: AccountResponse = try await client.request("account/read", params: ["refreshToken": false])
        guard let identity = account.account, identity.supportsUsage else {
            throw UsageProviderError.subscriptionLoginRequired
        }
        let limits: RateLimitsResponse = try await client.request("account/rateLimits/read")
        var report = UsageReport(limits: limits, accountLabel: identity.planType.map { "Codex · \($0)" } ?? "Codex")
        do {
            let tokens: AccountTokenUsage = try await client.request("account/usage/read", timeout: 8)
            if tokens.summary?.lifetimeTokens != nil || tokens.summary?.peakDailyTokens != nil || !(tokens.dailyUsageBuckets ?? []).isEmpty {
                report.tokens = tokens
            } else {
                report.tokenNotice = "계정이 토큰 활동 데이터를 아직 제공하지 않습니다."
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            report.tokenNotice = "토큰 활동을 조회할 수 없습니다. 사용 한도 정보는 정상적으로 조회했습니다."
        }
        return report
    }

    func makeClient(executablePath: String?) async throws -> AppServerClient {
        let client = try AppServerClient(executable: resolveExecutable(executablePath))
        do {
            let _: InitializationResult = try await client.request("initialize", params: [
                "clientInfo": ["name": "codex_usage_menubar", "title": "Codex Usage Menu", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try client.initialized()
            return client
        } catch {
            client.stop()
            throw error
        }
    }

    /// Find only executable candidates, without opening authentication or configuration files.
    private func resolveExecutable(_ configuredPath: String?) throws -> URL {
        let manager = FileManager.default
        if let path = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), isExecutableFile(expanded, manager: manager) else { throw UsageProviderError.invalidExecutable }
            return URL(fileURLWithPath: expanded)
        }
        let home = manager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/codex", "/opt/homebrew/bin/codex", home + "/.local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex", home + "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex", home + "/Applications/ChatGPT.app/Contents/Resources/codex"
        ]
        guard let path = candidates.first(where: { isExecutableFile($0, manager: manager) }) else {
            throw UsageProviderError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }

    /// Reject directories while permitting installed CLI symlinks.
    private func isExecutableFile(_ path: String, manager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return manager.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && manager.isExecutableFile(atPath: path)
    }

    private struct InitializationResult: Decodable {}
}
