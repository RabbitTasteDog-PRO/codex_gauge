import XCTest
@testable import CodexGauge

final class CatSpriteTests: XCTestCase {
    func testAllBodyStagesHaveReadableDistinctFramesAndTransparentPadding() async {
        await MainActor.run {
            let renderer = CatStatusRenderer()
            XCTAssertTrue(renderer.hasValidFrames)
            guard renderer.hasValidFrames else { return }
            for row in renderer.masks {
                XCTAssertGreaterThanOrEqual(Set(row.map(\.pixels)).count, 3)
                for frame in row {
                    XCTAssertGreaterThan(frame.visiblePixelCount, 30)
                    XCTAssertLessThan(frame.visiblePixelCount, frame.pixels.count / 2)
                    XCTAssertFalse(frame.pixels.first!)
                    XCTAssertFalse(frame.pixels.last!)
                }
            }
            let areas = renderer.masks.map { $0.reduce(0) { $0 + $1.visiblePixelCount } }
            XCTAssertGreaterThan(areas[0], areas[1])
            XCTAssertGreaterThan(areas[1], areas[2])
            XCTAssertGreaterThan(areas[2], areas[3])
            for percent in [100.0, 75, 50, 25] {
                for dark in [false, true] {
                    let images = renderer.menuFrames(remainingPercent: percent, isDark: dark)
                    XCTAssertEqual(images.count, 4)
                    XCTAssertEqual(images.first?.size.width, 70)
                    XCTAssertEqual(images.first?.size.height, 24)
                }
            }
        }
    }
}
