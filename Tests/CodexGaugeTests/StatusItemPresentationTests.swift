import AppKit
import XCTest
import UsageCore
@testable import CodexGauge

final class StatusItemPresentationTests: XCTestCase {
    @MainActor
    func testAppearanceStormDoesNotMutateUnchangedPresentationAndRealTransitionAppliesOnce() async {
        let coordinator = StatusItemUpdateCoordinator()
        let presenter = StatusItemPresenter()
        let target = RecordingStatusTarget()
        let lightImage = NSImage(size: NSSize(width: 82, height: 24))
        let darkImage = NSImage(size: NSSize(width: 82, height: 24))
        let metadata = StatusItemPresenter.Metadata(title: " 94%", toolTip: "주간 한도", accessibilityValue: "94%")

        XCTAssertTrue(coordinator.requestContent())
        XCTAssertTrue(coordinator.drain(isDark: false).updateContent)
        presenter.applyImage(lightImage, to: target)
        presenter.applyMetadata(metadata, to: target)

        for dark in [false, true, true, false, false] {
            var scheduledDrains = 0
            for _ in 0..<1_000 {
                if coordinator.requestAppearanceCheck() { scheduledDrains += 1 }
            }
            XCTAssertEqual(scheduledDrains, 1)
            let decision = coordinator.drain(isDark: dark)
            XCTAssertFalse(decision.resizePanel)
            if decision.updateContent {
                presenter.applyImage(dark ? darkImage : lightImage, to: target)
                presenter.applyMetadata(metadata, to: target)
            }
        }
        // Initial light frame, one dark transition, one light transition.
        XCTAssertEqual(target.imageWrites, 3)
        XCTAssertEqual(target.titleWrites, 1)
        XCTAssertEqual(target.toolTipWrites, 1)
        XCTAssertEqual(target.accessibilityWrites, 1)
    }

    @MainActor
    func testContentUpdateIsNotLostWhenCoalescedWithAnUnchangedAppearance() async {
        let coordinator = StatusItemUpdateCoordinator()
        XCTAssertTrue(coordinator.requestContent())
        _ = coordinator.drain(isDark: true)
        XCTAssertTrue(coordinator.requestAppearanceCheck())
        XCTAssertFalse(coordinator.requestContent(resizePanel: true))
        let decision = coordinator.drain(isDark: true)
        XCTAssertTrue(decision.updateContent)
        XCTAssertTrue(decision.resizePanel)
        XCTAssertFalse(coordinator.drain(isDark: true).updateContent)
    }

    @MainActor
    func testAnimationTicksOnlyWriteImagesAndNeverRequestPanelLayout() async {
        let presenter = StatusItemPresenter()
        let target = RecordingStatusTarget()
        let images = (0..<CatIdleCycle.frameCount).map { _ in NSImage(size: NSSize(width: 82, height: 24)) }
        let metadata = StatusItemPresenter.Metadata(title: " 50%", toolTip: "5시간 한도", accessibilityValue: "50%")
        presenter.applyMetadata(metadata, to: target)
        presenter.applyImage(images[0], to: target)
        var cycle = CatIdleCycle()
        for _ in 0..<CatIdleCycle.frameCount {
            cycle.advance()
            presenter.applyImage(images[cycle.frameIndex], to: target)
        }
        XCTAssertEqual(cycle.frameIndex, 0)
        XCTAssertEqual(target.imageWrites, CatIdleCycle.frameCount + 1)
        XCTAssertEqual(target.titleWrites, 1)
        XCTAssertEqual(target.toolTipWrites, 1)
        XCTAssertEqual(target.accessibilityWrites, 1)
        // Reapplying the current frame from a periodic status refresh is a no-op.
        presenter.applyImage(images[0], to: target)
        XCTAssertEqual(target.imageWrites, CatIdleCycle.frameCount + 1)
    }

    @MainActor
    func testSamePresentationReenteredFromSetterDoesNotWriteAgain() async {
        let presenter = StatusItemPresenter()
        let target = RecordingStatusTarget()
        let image = NSImage(size: NSSize(width: 82, height: 24))
        let metadata = StatusItemPresenter.Metadata(title: " 25%", toolTip: "주간 한도", accessibilityValue: "25%")
        target.onImageWrite = { presenter.applyImage(image, to: target) }
        target.onTitleWrite = { presenter.applyMetadata(metadata, to: target) }
        presenter.applyImage(image, to: target)
        presenter.applyMetadata(metadata, to: target)
        XCTAssertEqual(target.imageWrites, 1)
        XCTAssertEqual(target.titleWrites, 1)
        XCTAssertEqual(target.toolTipWrites, 1)
        XCTAssertEqual(target.accessibilityWrites, 1)
        target.onImageWrite = nil
        target.onTitleWrite = nil
    }

    @MainActor
    func testQuotaSelectionAndConnectionChangesUpdateOnlyRelevantMetadata() async {
        let presenter = StatusItemPresenter()
        let target = RecordingStatusTarget()
        presenter.applyMetadata(.init(title: " 50%", toolTip: "5시간 한도", accessibilityValue: "50%"), to: target)
        presenter.applyMetadata(.init(title: " 50%", toolTip: "주간 한도", accessibilityValue: "50%"), to: target)
        XCTAssertEqual(target.titleWrites, 1)
        XCTAssertEqual(target.toolTipWrites, 2)
        XCTAssertEqual(target.accessibilityWrites, 1)
        presenter.applyMetadata(.init(title: " 50% !", toolTip: "주간 한도 · 마지막 조회 값", accessibilityValue: "50% · 마지막 조회 값"), to: target)
        XCTAssertEqual(target.titleWrites, 2)
        XCTAssertEqual(target.toolTipWrites, 3)
        XCTAssertEqual(target.accessibilityWrites, 2)
    }
}

@MainActor
private final class RecordingStatusTarget: StatusItemPresentationTarget {
    private(set) var imageWrites = 0
    private(set) var titleWrites = 0
    private(set) var toolTipWrites = 0
    private(set) var accessibilityWrites = 0
    var onImageWrite: (() -> Void)?
    var onTitleWrite: (() -> Void)?

    func setStatusImage(_ image: NSImage) { imageWrites += 1; onImageWrite?() }
    func setStatusTitle(_ title: String) { titleWrites += 1; onTitleWrite?() }
    func setStatusToolTip(_ toolTip: String) { toolTipWrites += 1 }
    func setStatusAccessibilityValue(_ value: String) { accessibilityWrites += 1 }
}
