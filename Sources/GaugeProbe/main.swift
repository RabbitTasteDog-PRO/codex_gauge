import Foundation
import UsageCore

@main
struct GaugeProbe {
    /// Verify real account metrics without printing credentials or account identity.
    static func main() async {
        do {
            let explicitPath = CommandLine.arguments.dropFirst().first
            let report = try await CodexUsageProvider().fetchUsage(executablePath: explicitPath)
            let windows = report.limits.windows.map {
                ["id": $0.id, "usedPercent": $0.quota.clampedPercent,
                 "windowDurationMins": $0.quota.windowDurationMins.map { $0 as Any } ?? NSNull(),
                 "resetsAt": $0.quota.resetsAt.map { $0 as Any } ?? NSNull()] as [String: Any]
            }
            var result: [String: Any] = ["connected": true, "windows": windows,
                                         "tokensAvailable": report.tokens != nil]
            if let total = report.tokens?.summary?.lifetimeTokens { result["lifetimeTokens"] = total }
            if let bucket = report.tokens?.latestBucket { result["latestDailyTokens"] = bucket.tokens; result["latestDailyDate"] = bucket.startDate }
            if let notice = report.tokenNotice { result["tokenNotice"] = notice }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
