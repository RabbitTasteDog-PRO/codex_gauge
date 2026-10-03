import XCTest
@testable import UsageCore

final class CatAnimationTests: XCTestCase {
    func testRemainingQuotaSelectsFiveStagesAtEachBoundary() {
        for (percent, stage) in [(100.0, CatBodyStage.plump), (76, .plump), (75, .rounded), (51, .rounded), (50, .regular), (26, .regular), (25, .slender), (6, .slender), (5, .depleted), (0, .depleted)] {
            XCTAssertEqual(CatBodyStage.forRemainingPercent(percent), stage)
        }
    }

    func testUnavailableQuotaUsesNeutralBody() {
        let percents: [Double?] = [nil, .nan, .infinity]
        for percent in percents {
            XCTAssertEqual(CatBodyStage.forRemainingPercent(percent), .rounded)
        }
    }

    func testIdleCycleVisitsEveryFrameAndLoopsCalmly() {
        var cycle = CatIdleCycle()
        for frame in 0..<64 {
            XCTAssertEqual(cycle.frameIndex, frame % 32)
            cycle.advance()
        }
        XCTAssertEqual(cycle.frameIndex, 0)
        XCTAssertEqual(CatIdleCycle.frameInterval * Double(CatIdleCycle.frameCount), 6.4, accuracy: 0.001)
    }
}
