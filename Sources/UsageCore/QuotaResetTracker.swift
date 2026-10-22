import Foundation

/// Only fresh snapshots establish a baseline; cached values and account changes must not celebrate.
public struct QuotaResetTracker: Sendable {
    private var previous: [String: RateWindow] = [:]
    public private(set) var pendingWindowIDs: Set<String> = []

    public init() {}

    public mutating func observe(_ windows: [UsageWindow], at now: Date = Date()) {
        let ids = Set(windows.map(\.id))
        previous = previous.filter { ids.contains($0.key) }
        pendingWindowIDs.formIntersection(ids)
        for window in windows {
            let current = window.quota
            guard current.usedPercent.isFinite, (0...100).contains(current.usedPercent) else { continue }
            defer { previous[window.id] = current }
            // Even the first actual use after a reset ends the tapping animation.
            guard current.usedPercent == 0 else {
                pendingWindowIDs.remove(window.id)
                continue
            }
            guard let old = previous[window.id], old.windowDurationMins == current.windowDurationMins else {
                pendingWindowIDs.remove(window.id)
                continue
            }
            let replenished = old.usedPercent > 0
            let rolledOver: Bool
            if let end = old.resetsAt, let next = current.resetsAt, end.isFinite, next.isFinite {
                rolledOver = end <= now.timeIntervalSince1970 && next > end
            } else {
                rolledOver = false
            }
            if replenished || rolledOver { pendingWindowIDs.insert(window.id) }
        }
    }

    public mutating func acknowledge(_ windowID: String) {
        pendingWindowIDs.remove(windowID)
    }
}

public enum QuotaResetTap {
    public static let frameCount = 8

    /// Contact and recoil align with the fifth and sixth sprite cells.
    public static func gaugeOffset(frame: Int) -> (x: Int, y: Int) {
        switch frame % frameCount {
        case 4: return (1, 1)
        case 5: return (-1, 0)
        default: return (0, 0)
        }
    }
}
