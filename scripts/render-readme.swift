import AppKit
import Foundation
import SwiftUI
import UsageCore

/// Render the actual app views with fictional data, without querying an account or desktop.
@main
@MainActor
struct ReadmeImages {
    static func main() async throws {
        _ = NSApplication.shared
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Gauge-readme-preview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex/secondary", forKey: "selectedWindowID")

        let signedIn = UsageStore(defaults: defaults, provider: ExampleUsage(), authentication: ExampleAuthentication(signedIn: true))
        await signedIn.refresh()
        try await render(signedIn, to: directory.appendingPathComponent("usage-panel.png"))
        signedIn.stop()

        defaults.removeObject(forKey: "usageCache")
        let signingIn = UsageStore(defaults: defaults, provider: ExampleUsage(), authentication: ExampleAuthentication(signedIn: false))
        defer { signingIn.stop() }
        await signingIn.launch { _ in true }
        for _ in 0..<100 {
            if signingIn.loginURL != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard signingIn.loginURL != nil else { throw CocoaError(.coderInvalidValue) }
        try await render(signingIn, to: directory.appendingPathComponent("login-panel.png"))
        try CatStatusRenderer().writePreview(to: directory.appendingPathComponent("menu-preview.png"))
        print("README images rendered with example data.")
    }

    private static func render(_ store: UsageStore, to url: URL) async throws {
        let view = GaugePanel(store: store)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "ko_KR"))
        // AppKit-backed buttons and pickers require NSView rendering, not ImageRenderer.
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        window.close()
    }
}

private struct ExampleUsage: UsageProviding {
    func fetchUsage(executablePath: String?) async throws -> UsageReport {
        let tokens = try JSONDecoder().decode(AccountTokenUsage.self, from: Data(#"{"summary":{"lifetimeTokens":1234567},"dailyUsageBuckets":[{"startDate":"2026-10-01","tokens":42800}]}"#.utf8))
        return UsageReport(limits: RateLimitsResponse(rateLimitsByLimitId: ["codex": RateLimitSnapshot(
            primary: RateWindow(usedPercent: 12, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(7200).timeIntervalSince1970),
            secondary: RateWindow(usedPercent: 21, windowDurationMins: 10080, resetsAt: Date().addingTimeInterval(172800).timeIntervalSince1970)
        )]), tokens: tokens)
    }
}

private struct ExampleAuthentication: AccountAuthenticating {
    let signedIn: Bool
    func readAccount(executablePath: String?) async throws -> CodexAccount? {
        signedIn ? CodexAccount(type: "chatgpt", email: "demo@example.com", planType: "plus") : nil
    }
    func beginLogin(executablePath: String?) async throws -> any CodexLoginSession { ExampleLogin() }
    func logout(executablePath: String?) async throws {}
}

private final class ExampleLogin: CodexLoginSession, @unchecked Sendable {
    let authURL = URL(string: "https://auth.openai.com/authorize?state=readme-example")!
    private let events: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    init() {
        var sink: AsyncStream<Bool>.Continuation!
        events = AsyncStream { sink = $0 }
        continuation = sink
    }
    func waitForCompletion() async throws {
        for await _ in events { return }
        throw CancellationError()
    }
    func cancel() async throws { continuation.finish() }
    func stop() { continuation.finish() }
}
