import AppKit
import Combine
import SwiftUI
import WispApplication
import WispCapture
import WispDomain
import WispPersistence
import WispUI

/// Composition root — wires adapters; no business rules here.
@main
enum WispMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Borderless panels refuse key status by default; the search field and keyboard shortcuts need it.
private final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Reports SwiftUI size changes so the panel follows its content (instead of re-measuring on every model tick).
private final class PanelHostingView: NSHostingView<MenuBarPanel> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: PanelWindow?
    private var hosting: PanelHostingView?
    private var model: PanelModel?
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var resizeScheduled = false
    private let recordingFrame = RecordingFrameController(locator: CGTargetLocator())
    private var framedSourceID: CaptureSourceID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logLaunchIdentity()

        let files = LocalMeetingFileStore()
        let recording = RecordingService(
            sources: SCKCaptureSourceListing(includeOffScreenWindows: true),
            pipeline: SCKCapturePipeline(),
            ambient: MicOnlyAmbientPipeline(),
            meetings: FileMeetingRepository(root: files.root),
            files: files,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            tabs: AppleScriptBrowserTabs(),
            titles: CGTargetLocator()
        )
        let model = PanelModel(
            recording: recording,
            thumbnails: SCKThumbnailProvider(),
            permissions: LivePermissions(),
            mediaRoot: files.root
        )
        self.model = model

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarTemplateImage()
            button.imagePosition = .imageOnly
            button.action = #selector(togglePanel)
            button.target = self
            button.setAccessibilityLabel("Wisp")
        }
        self.statusItem = statusItem
        bindStatusItem(to: model)
        bindRecordingFrame(to: model)

        let hosting = PanelHostingView(rootView: MenuBarPanel(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onIntrinsicSizeChange = { [weak self] in self?.scheduleResize() }
        self.hosting = hosting

        let panel = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel

        installLocalKeyMonitor()
        installQAHooks()
        NSLog("[Wisp] media root: %@", files.root.path)

        Task { await model.startUp() }
    }

    /// Quitting (menu, ⌘Q, log out) while recording stops the recording first so the files
    /// are finished; without this every track is left without its index and won't play.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.surface == .recording || model.isBusy else { return .terminateNow }
        Task { @MainActor in
            await model.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Status item

    private func bindStatusItem(to model: PanelModel) {
        // Setting the title redraws the item on every display, so only when the text changes.
        Publishers.CombineLatest(model.$surface, model.$elapsed)
            .map { surface, elapsed in surface == .recording ? MenuBarStatus.timeText(elapsed) : nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let button = self?.statusItem?.button else { return }
                if let text {
                    button.attributedTitle = MenuBarStatus.title(text: text)
                    button.imagePosition = .imageLeading
                } else {
                    button.attributedTitle = NSAttributedString(string: "")
                    button.imagePosition = .imageOnly
                }
            }
            .store(in: &cancellables)
    }

    /// Outlines the recorded window or display while recording (like a screen-share border).
    /// Follows a recorded tab to the window that shows it, and hides while the tab is not showing.
    private func bindRecordingFrame(to model: PanelModel) {
        model.$videoTarget
            .receive(on: RunLoop.main)
            .sink { [weak self] videoTarget in
                guard let self else { return }
                let target = videoTarget?.isLive == true ? videoTarget?.source : nil
                guard target != self.framedSourceID else { return }
                self.framedSourceID = target
                if let target {
                    self.recordingFrame.show(for: target)
                } else {
                    self.recordingFrame.hide()
                }
            }
            .store(in: &cancellables)
    }

    /// Bundled swan template (black + alpha); SF Symbol fallback outside the .app.
    private static func menuBarTemplateImage() -> NSImage {
        if let image = NSImage(named: "wispTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let fallback = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Wisp")
        let image = fallback?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        guard let panel else { return }
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard let panel, let model else { return }
        resizePanel(animated: false)
        // Accessory apps are usually not active when the status item is clicked;
        // order front regardless, then take key so the search field and shortcuts work.
        panel.orderFrontRegardless()
        panel.makeKey()
        model.setPanelVisible(true)
        installOutsideClickMonitor()
        Task { await model.bootstrap() }
    }

    private func hidePanel() {
        model?.setPanelVisible(false)
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.resizeScheduled = false
            self?.resizePanel(animated: true)
        }
    }

    /// Keeps the panel's top edge under the status item; only touches the frame when the size changes.
    private func resizePanel(animated: Bool) {
        guard let panel, let hosting else { return }
        let fitting = hosting.fittingSize
        let anchor = statusItemScreenRect()
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: ceil(fitting.width), height: ceil(min(fitting.height, visible.height - 12)))

        var frame = panel.frame
        let top = anchor.map { $0.minY - 6 } ?? frame.maxY
        var x = anchor.map { $0.midX - size.width / 2 } ?? frame.minX
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let target = NSRect(x: round(x), y: round(top - size.height), width: size.width, height: size.height)
        guard target != frame else { return }
        frame = target
        let animate = animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func statusItemScreenRect() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.handleOutsideClick() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func handleOutsideClick() {
        guard let panel, panel.isVisible else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) { return }
        if let rect = statusItemScreenRect(), rect.contains(point) { return }
        hidePanel()
    }

    // MARK: - Keyboard

    private func installLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
    }

    /// Decodes the key and lets the panel's rules (`PanelModel.handle`) decide.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let model, let panel, panel.isVisible, event.window === panel else { return event }
        let textView = panel.firstResponder as? NSTextView
        // While an input method is composing (Japanese conversion), every key belongs to it.
        if let textView, textView.hasMarkedText() { return event }
        guard let key = Self.panelKey(for: event) else { return event }
        switch model.handle(key, editingText: textView != nil) {
        case .handled: return nil
        case .passThrough: return event
        case .hidePanel:
            hidePanel()
            return nil
        }
    }

    private static func panelKey(for event: NSEvent) -> PanelKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            return event.charactersIgnoringModifiers?.first.map(PanelKey.command)
        }
        switch event.keyCode {
        case 53: return .escape
        case 36: return .returnKey
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    // MARK: - QA hooks (DistributedNotification)

    /// Off unless asked for: any process on the Mac can post distributed notifications.
    /// Turn on with `WISP_QA=1` in the environment or
    /// `defaults write tech.incerto.wisp.mac WispQAHooks -bool true` (then relaunch).
    private static var qaHooksEnabled: Bool {
        ProcessInfo.processInfo.environment["WISP_QA"] == "1" || UserDefaults.standard.bool(forKey: "WispQAHooks")
    }

    private func installQAHooks() {
        guard Self.qaHooksEnabled else { return }
        NSLog("[Wisp] QA hooks are on")
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("tech.incerto.wisp.mac.qa.showPanel"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showPanel() }
        }
        center.addObserver(forName: Notification.Name("tech.incerto.wisp.mac.qa.hidePanel"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
        // Shows the recording frame around the selected source for 4 s without recording.
        center.addObserver(forName: Notification.Name("tech.incerto.wisp.mac.qa.previewFrame"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model else { return }
                await model.bootstrap()
                guard let id = model.selectedSource?.previewID else { return }
                self.recordingFrame.show(for: id)
                try? await Task.sleep(for: .seconds(4))
                if self.framedSourceID == nil { self.recordingFrame.hide() }
            }
        }
        // Opens the newest completed recording (playback path).
        center.addObserver(forName: Notification.Name("tech.incerto.wisp.mac.qa.openFirstMeeting"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model, model.surface != .recording else { return }
                self.showPanel()
                await model.bootstrap()
                if let meeting = model.meetings.first(where: { $0.status == .completed }) {
                    await model.openDetail(meeting)
                }
            }
        }
    }

    /// Logs the exact TCC target so Console and the permissions guide stay honest.
    private static func logLaunchIdentity() {
        let identity = WispPermissions.currentAppIdentity()
        NSLog(
            "[Wisp] TCC target display=%@ bundle=%@ path=%@ screen=%@ mic=%@",
            identity.displayName,
            identity.bundleIdentifier,
            identity.bundlePath,
            WispPermissions.screenRecordingGranted() ? "granted" : "missing",
            WispPermissions.microphoneGranted() ? "granted" : "missing"
        )
    }
}
