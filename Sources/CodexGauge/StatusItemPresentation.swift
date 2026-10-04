import AppKit

/// Collapse notifications before reading the button's final, effective appearance.
/// AppKit can notify appearance while generating a status-item snapshot, even when
/// the dark/light choice that we actually render has not changed.
@MainActor
final class StatusItemUpdateCoordinator {
    struct Decision {
        let updateContent: Bool
        let resizePanel: Bool
    }

    private var queued = false
    private var contentRequested = false
    private var appearanceRequested = false
    private var panelResizeRequested = false
    private var appliedDarkAppearance: Bool?

    /// True means the caller should enqueue exactly one main-queue drain.
    func requestContent(resizePanel: Bool = false) -> Bool {
        contentRequested = true
        panelResizeRequested = panelResizeRequested || resizePanel
        return claimDrain()
    }

    func requestAppearanceCheck() -> Bool {
        appearanceRequested = true
        return claimDrain()
    }

    private func claimDrain() -> Bool {
        guard !queued else { return false }
        queued = true
        return true
    }

    /// Commit the appearance before any UI setter can notify us again.
    func drain(isDark: Bool) -> Decision {
        let shouldUpdate = contentRequested || (appearanceRequested && appliedDarkAppearance != isDark)
        let shouldResize = panelResizeRequested
        queued = false
        contentRequested = false
        appearanceRequested = false
        panelResizeRequested = false
        if shouldUpdate { appliedDarkAppearance = isDark }
        return Decision(updateContent: shouldUpdate, resizePanel: shouldResize)
    }
}

@MainActor
protocol StatusItemPresentationTarget: AnyObject {
    func setStatusImage(_ image: NSImage)
    func setStatusTitle(_ title: String)
    func setStatusToolTip(_ toolTip: String)
    func setStatusAccessibilityValue(_ value: String)
}

extension NSStatusBarButton: StatusItemPresentationTarget {
    func setStatusImage(_ image: NSImage) { self.image = image }
    func setStatusTitle(_ title: String) { self.title = title }
    func setStatusToolTip(_ toolTip: String) { self.toolTip = toolTip }
    func setStatusAccessibilityValue(_ value: String) { setAccessibilityValue(value) }
}

/// Both content updates and animation ticks use the same image identity check.
/// Metadata has a separate path, so animation cannot rewrite title or accessibility.
@MainActor
final class StatusItemPresenter {
    struct Metadata {
        let title: String
        let toolTip: String
        let accessibilityValue: String
    }

    private var appliedImage: NSImage?
    private var appliedMetadata: Metadata?

    func applyImage(_ image: NSImage, to target: any StatusItemPresentationTarget) {
        guard appliedImage !== image else { return }
        appliedImage = image
        target.setStatusImage(image)
    }

    func applyMetadata(_ metadata: Metadata, to target: any StatusItemPresentationTarget) {
        let previous = appliedMetadata
        appliedMetadata = metadata
        if previous?.title != metadata.title { target.setStatusTitle(metadata.title) }
        if previous?.toolTip != metadata.toolTip { target.setStatusToolTip(metadata.toolTip) }
        if previous?.accessibilityValue != metadata.accessibilityValue {
            target.setStatusAccessibilityValue(metadata.accessibilityValue)
        }
    }
}
