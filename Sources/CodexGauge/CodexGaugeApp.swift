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
    private var catCycle = CatRunCycle()
    private var animationImages: [NSImage] = []
    private var animationTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var animationSuspended = false

    /// Native status item image and title remain visible independently of the panel.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
        }

        let host = NSHostingController(rootView: GaugePanel(store: store))
        hostingController = host
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        updateStatusItem()

        // ObservableObject publishes before changing properties, so render on the next turn.
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.store.shouldTerminate {
                    NSApplication.shared.terminate(nil)
                    return
                }
                self.updateStatusItem()
                self.resizePanel()
            }
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
            Task { @MainActor in self?.updateStatusItem() }
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
        host.preferredContentSize = size
        popover.contentSize = size
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let percent = store.selectedWindow?.quota.remainingPercent
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        animationImages = catRenderer.menuFrames(remainingPercent: percent, isDark: isDark)
        button.image = animationImages[catCycle.frameIndex % animationImages.count]
        let needsAttention = store.isStale || store.errorMessage != nil
        button.title = " " + (percent.map(GaugeStyle.percent) ?? "—") + (needsAttention ? " !" : "")
        let quotaTitle = store.selectedWindow?.title ?? "사용 가능한 한도 조회 중"
        let state = needsAttention ? " · 마지막 조회 값, 연결 상태 확인 필요" : ""
        let cat = CatBodyStage.forRemainingPercent(percent).label
        button.toolTip = "\(cat) · Codex 남은 한도 · \(quotaTitle)\(state)"
        button.setAccessibilityLabel("움직이는 고양이, 게이지, Codex 남은 한도")
        button.setAccessibilityValue((percent.map(GaugeStyle.percent) ?? "조회되지 않음") + state)
    }

    /// Animation swaps cached images only; it never triggers a network request.
    private func startAnimation() {
        guard animationTimer == nil, !animationSuspended,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: CatRunCycle.frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.animationImages.isEmpty else { return }
                self.catCycle.advance()
                self.statusItem?.button?.image = self.animationImages[self.catCycle.frameIndex % self.animationImages.count]
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// Respect sleep, inactive sessions and the user's Reduce Motion preference.
    private func configureAnimationLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.animationSuspended = true
                    self?.animationTimer?.invalidate()
                    self?.animationTimer = nil
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.animationSuspended = false
                    self?.startAnimation()
                }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.animationTimer?.invalidate()
                self?.animationTimer = nil
                self?.startAnimation()
            }
        })
    }
}
