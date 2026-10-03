import XCTest
@testable import CodexGauge

final class CatSpriteTests: XCTestCase {
    func testAllFiveSheetsDecodeAndFoodDoesNotWobbleDuringIdle() async {
        await MainActor.run {
            let renderer = CatStatusRenderer()
            XCTAssertTrue(renderer.hasValidFrames)
            guard renderer.hasValidFrames else { return }
            XCTAssertEqual(renderer.masks.count, 5)
            for frames in renderer.masks {
                XCTAssertEqual(frames.count, 32)
                XCTAssertGreaterThan(Set(frames.map(\.pixels)).count, 1)
                let bowls = frames.map { mask in
                    mask.pixels.enumerated().filter { $0.offset % CatStatusRenderer.PixelMask.width >= CatStatusRenderer.PixelMask.catWidth }.map(\.element)
                }
                XCTAssertEqual(Set(bowls).count, 1)
                for frame in frames { XCTAssertGreaterThan(frame.catPixelCount, 60) }
            }
            let bodies = renderer.masks.map { $0.map(\.catPixelCount).reduce(0, +) }
            let bowls = renderer.masks.map { $0[0].bowlPixelCount }
            let food = renderer.masks.map { $0[0].foodPixelCount }
            for (stage, portion) in [1.0, 0.75, 0.5, 0.25, 0.0].enumerated() {
                XCTAssertEqual(food[stage], Int(ceil(Double(food[0]) * portion)))
            }
            for stage in 0..<4 {
                XCTAssertGreaterThan(bodies[stage], bodies[stage + 1], "Body area should shrink: \(bodies)")
                XCTAssertGreaterThan(bowls[stage], bowls[stage + 1], "Food should decrease: \(bowls)")
            }
        }
    }

    func testMenuFramesRenderBothAppearancesAndCacheUnchangedQuota() async {
        await MainActor.run {
            let renderer = CatStatusRenderer()
            for percent in [100.0, 75, 50, 25, 5, 0] {
                for dark in [false, true] {
                    let images = renderer.menuFrames(remainingPercent: percent, isDark: dark)
                    XCTAssertEqual(images.count, 32)
                    XCTAssertEqual(images.first?.size.width, 82)
                    XCTAssertEqual(images.first?.size.height, 24)
                    XCTAssertNotNil(images.first?.tiffRepresentation)
                    XCTAssertTrue(images[0] === renderer.menuFrames(remainingPercent: percent, isDark: dark)[0])
                }
            }
            XCTAssertEqual(renderer.menuFrames(remainingPercent: nil, isDark: true).count, 1)
            XCTAssertEqual(renderer.menuFrames(remainingPercent: .nan, isDark: false).count, 1)
        }
    }
}
