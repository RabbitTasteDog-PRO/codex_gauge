import XCTest
@testable import UsageCore

final class CatAnimationTests: XCTestCase {
    func testRemainingQuotaSelectsBodyAtEachBoundary() {
        for (percent, stage) in [(100.0, CatBodyStage.plump), (76, .plump), (75, .rounded), (51, .rounded), (50, .regular), (26, .regular), (25, .slender), (0, .slender)] {
            XCTAssertEqual(CatBodyStage.forRemainingPercent(percent), stage)
        }
    }

    func testUnavailableQuotaUsesNeutralBody() {
        XCTAssertEqual(CatBodyStage.forRemainingPercent(nil), .regular)
        XCTAssertEqual(CatBodyStage.forRemainingPercent(.nan), .regular)
    }

    func testCycleWrapsWithoutLosingValidFrame() {
        var cycle = CatRunCycle()
        var frames = [Int]()
        for _ in 0..<12 { frames.append(cycle.frameIndex); cycle.advance() }
        XCTAssertEqual(frames, [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3])
        XCTAssertEqual(cycle.frameIndex, 0)
    }
}
