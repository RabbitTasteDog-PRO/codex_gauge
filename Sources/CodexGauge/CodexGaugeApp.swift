import AppKit
import Combine
import SwiftUI
import UsageCore

@main
@MainActor
struct CodexGaugeApp {
    /// Keep the delegate alive for the lifetime of this accessory application.
    static func main() {
        let app = NSApplication.shared
        if let option = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.indices.contains(option + 1) {
            do { try CatStatusRenderer().writePreview(to: URL(fileURLWithPath: CommandLine.arguments[option + 1])) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
            return
        }
        let delegate = GaugeAppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class GaugeAppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hostingController: NSHostingController<GaugePanel>?
    private var storeObservation: AnyCancellable?
    private var startupTask: Task<Void, Never>?
    private var appearanceObservation: NSKeyValueObservation?
    private var statusTimer: Timer?
    private let catRenderer = CatStatusRenderer()
    private var catCycle = CatIdleCycle()
    private var animationImages: [NSImage] = []
    private var animationTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var backgroundActivity = BackgroundActivity()
    private var pollingIsSuspended = false
    private var powerObserver: NSObjectProtocol?
    private let statusUpdates = StatusItemUpdateCoordinator()
    private let statusPresenter = StatusItemPresenter()

    /// Native status item image and title remain visible independently of the panel.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
            button.setAccessibilityLabel("앉아 있는 고양이, 밥그릇, 게이지, Codex 남은 한도")
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.requestAppearanceCheck() }
            }
        }

        let host = NSHostingController(rootView: GaugePanel(store: store))
        hostingController = host
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        requestStatusUpdate()

        // ObservableObject publishes before changing properties, so render on the next turn.
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            self?.requestStatusUpdate(resizePanelIfShown: true)
        }
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.store.launch { [weak self] url in
                self?.showPanel()
                return NSWorkspace.shared.open(url)
            }
            if self.store.errorMessage != nil || self.store.authError != nil {
                self.showPanel()
            }
        }
        configureAnimationLifecycle()
        startAnimation()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestStatusUpdate() }
        }

        let hasShownPanel = UserDefaults.standard.bool(forKey: "didShowInitialPanel")
        if !hasShownPanel || CommandLine.arguments.contains("--show-panel") {
            UserDefaults.standard.set(true, forKey: "didShowInitialPanel")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPanel()
            }
        }
    }

    /// Reopening the existing app from Finder reveals its menu panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    /// Stop background work when the application actually exits.
    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        startupTask = nil
        store.stop()
        popover.close()
        storeObservation?.cancel()
        appearanceObservation?.invalidate()
        statusTimer?.invalidate()
        animationTimer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        resizePanel()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Size the native popover from the SwiftUI panel's current content.
    private func resizePanel() {
        guard let host = hostingController else { return }
        host.view.layoutSubtreeIfNeeded()
        let fitted = host.view.fittingSize
        let size = NSSize(width: 340, height: fitted.height > 0 ? fitted.height : 460)
        if host.preferredContentSize != size { host.preferredContentSize = size }
        if popover.contentSize != size { popover.contentSize = size }
    }

    private func requestStatusUpdate(resizePanelIfShown: Bool = false) {
        guard statusUpdates.requestContent(resizePanel: resizePanelIfShown) else { return }
        enqueueStatusUpdate()
    }

    private func requestAppearanceCheck() {
        guard statusUpdates.requestAppearanceCheck() else { return }
        enqueueStatusUpdate()
    }

    private func enqueueStatusUpdate() {
        DispatchQueue.main.async { [weak self] in self?.drainStatusUpdate() }
    }

    private func drainStatusUpdate() {
        guard let button = statusItem?.button else { return }
        if store.shouldTerminate {
            NSApplication.shared.terminate(nil)
            return
        }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let decision = statusUpdates.drain(isDark: isDark)
        if decision.updateContent { updateStatusItem(isDark: isDark) }
        if decision.resizePanel && popover.isShown { resizePanel() }
    }

    private func updateStatusItem(isDark: Bool) {
        guard let button = statusItem?.button else { return }
        let percent = store.selectedWindow?.quota.remainingPercent
        animationImages = catRenderer.menuFrames(remainingPercent: percent, isDark: isDark)
        if !animationImages.isEmpty {
            statusPresenter.applyImage(animationImages[catCycle.frameIndex % animationImages.count], to: button)
        }
        let needsAttention = store.isStale || store.errorMessage != nil
        let title = " " + (percent.map(GaugeStyle.percent) ?? "—") + (needsAttention ? " !" : "")
        let quotaTitle = store.selectedWindow?.title ?? "사용 가능한 한도 조회 중"
        let state = needsAttention ? " · 마지막 조회 값, 연결 상태 확인 필요" : ""
        let cat = percent == nil ? "고양이 · 사료량 조회 중" : CatBodyStage.forRemainingPercent(percent).label
        statusPresenter.applyMetadata(.init(
            title: title,
            toolTip: "\(cat) · Codex 남은 한도 · \(quotaTitle)\(state)",
            accessibilityValue: (percent.map(GaugeStyle.percent) ?? "조회되지 않음") + state
        ), to: button)
        reconcileBackgroundActivity()
    }

    /// Animation swaps cached images only; it never triggers a network request.
    private func startAnimation() {
        guard animationTimer == nil, backgroundActivity.allowsAnimation,
              animationImages.count > 1 else { return }
        let timer = Timer(timeInterval: CatIdleCycle.frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.backgroundActivity.allowsAnimation,
                      let button = self.statusItem?.button, self.animationImages.count > 1 else { return }
                self.catCycle.advance()
                self.statusPresenter.applyImage(self.animationImages[self.catCycle.frameIndex % self.animationImages.count], to: button)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// Keep independent pause reasons so a session wake cannot override a sleeping screen.
    private func configureAnimationLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, BackgroundActivity.PauseReason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true),
            (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.screensDidSleepNotification, .screenSleep, true),
            (NSWorkspace.screensDidWakeNotification, .screenSleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false)
        ]
        for (name, reason, paused) in events {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.backgroundActivity.set(reason, paused: paused)
                    self.reconcileBackgroundActivity()
                }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconcileBackgroundActivity() }
        })
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconcileBackgroundActivity() }
        }
        reconcileBackgroundActivity()
    }

    private func reconcileBackgroundActivity() {
        backgroundActivity.set(.reduceMotion, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        backgroundActivity.set(.lowPowerMode, paused: ProcessInfo.processInfo.isLowPowerModeEnabled)
        let suspendPolling = !backgroundActivity.allowsPolling
        if suspendPolling != pollingIsSuspended {
            pollingIsSuspended = suspendPolling
            if suspendPolling { store.suspendPollingForInactivity() }
            else { store.resumePollingAfterInactivity() }
        }
        if backgroundActivity.allowsAnimation && animationImages.count > 1 {
            startAnimation()
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }
}
