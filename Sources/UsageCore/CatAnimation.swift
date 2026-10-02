import Foundation

public enum CatBodyStage: Int, CaseIterable, Sendable {
    case plump, rounded, regular, slender

    /// Select a sprite row from available quota; unknown values use a neutral shape.
    public static func forRemainingPercent(_ percent: Double?) -> CatBodyStage {
        guard let percent, percent.isFinite else { return .regular }
        if percent > 75 { return .plump }
        if percent > 50 { return .rounded }
        if percent > 25 { return .regular }
        return .slender
    }

    public var label: String {
        switch self {
        case .plump: return "통통한 고양이"
        case .rounded: return "조금 통통한 고양이"
        case .regular: return "보통 고양이"
        case .slender: return "날씬한 고양이"
        }
    }
}

public struct CatRunCycle: Sendable {
    public static let frameCount = 4
    public static let frameInterval: TimeInterval = 0.12
    public private(set) var frameIndex = 0

    public init() {}

    /// Advance a fixed-size run cycle without allocating or changing usage polling.
    public mutating func advance() {
        frameIndex = (frameIndex + 1) % Self.frameCount
    }
}
