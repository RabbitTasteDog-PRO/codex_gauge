import Foundation

public enum CatBodyStage: Int, CaseIterable, Sendable {
    case plump, rounded, regular, slender, depleted

    /// Unknown quota uses the neutral stage; the final empty-bowl stage warns at 5%.
    public static func forRemainingPercent(_ percent: Double?) -> CatBodyStage {
        guard let percent, percent.isFinite else { return .rounded }
        if percent > 75 { return .plump }
        if percent > 50 { return .rounded }
        if percent > 25 { return .regular }
        if percent > 5 { return .slender }
        return .depleted
    }

    public var resourceName: String {
        switch self {
        case .plump: return "plump"
        case .rounded: return "rounded"
        case .regular: return "regular"
        case .slender: return "slender"
        case .depleted: return "depleted"
        }
    }

    public var label: String {
        switch self {
        case .plump: return "통통하고 만족한 고양이 · 사료 가득"
        case .rounded: return "조금 통통하고 불만스러운 고양이 · 사료 75%"
        case .regular: return "짜증 난 고양이 · 사료 50%"
        case .slender: return "날씬하고 화난 고양이 · 사료 25%"
        case .depleted: return "아주 홀쭉하고 화난 고양이 · 빈 밥그릇"
        }
    }
}

public struct CatIdleCycle: Sendable {
    public static let frameCount = 32
    public static let frameInterval: TimeInterval = 0.2
    public private(set) var frameIndex = 0

    public init() {}

    /// One calm idle loop lasts 6.4 seconds; ticks never trigger usage requests.
    public mutating func advance() {
        frameIndex = (frameIndex + 1) % Self.frameCount
    }
}
