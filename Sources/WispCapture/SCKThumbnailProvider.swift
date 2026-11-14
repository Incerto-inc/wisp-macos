import CoreGraphics
import Foundation
import ScreenCaptureKit
import WispApplication
import WispDomain

/// Picker thumbnails via `SCScreenshotManager` (macOS 14+). Reuses one shareable-content
/// snapshot for a couple of seconds so refreshing a grid does not re-enumerate every window.
public actor SCKThumbnailProvider: CaptureThumbnailProvider {
    private var snapshot: SCShareableContent?
    private var snapshotAt: Date = .distantPast
    /// Longer than the panel's refresh round (1.5 s), so a round reuses one listing; a window
    /// missing from it (opened since) triggers a fresh listing straight away.
    private let snapshotLifetime: TimeInterval = 10
    private var forcedAt: Date = .distantPast

    public init() {}

    public func thumbnail(for id: CaptureSourceID, maxPixelSize: Int) async -> CGImage? {
        guard var content = await shareableContent() else { return nil }
        // A window missing from the listing may be new; look again, but not every round for a
        // window that has simply closed.
        if !Self.contains(id, in: content), Date().timeIntervalSince(forcedAt) > 5,
           let fresh = await shareableContent(forceRefresh: true)
        {
            forcedAt = Date()
            content = fresh
        }
        let filter: SCContentFilter
        let pointSize: CGSize
        let target = CaptureTargetID(id)
        if case .window(let windowID) = target,
           let window = content.windows.first(where: { $0.windowID == windowID })
        {
            filter = SCContentFilter(desktopIndependentWindow: window)
            pointSize = window.frame.size
        } else if case .screen(let displayID) = target,
                  let display = content.displays.first(where: { $0.displayID == displayID })
        {
            // Same as recordings: keep Wisp's own panel out of the picture.
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            pointSize = CGSize(width: display.width, height: display.height)
        } else {
            return nil
        }

        let longEdge = max(pointSize.width, pointSize.height, 1)
        let scale = min(1, CGFloat(maxPixelSize) / longEdge)
        let config = SCStreamConfiguration()
        config.width = max(2, Int((pointSize.width * scale).rounded(.down)))
        config.height = max(2, Int((pointSize.height * scale).rounded(.down)))
        config.showsCursor = false
        config.capturesAudio = false
        return try? await ScreenCaptureKitCalls.screenshot(UncheckedSendable(value: (filter: filter, configuration: config))).value
    }

    private static func contains(_ id: CaptureSourceID, in content: SCShareableContent) -> Bool {
        switch CaptureTargetID(id) {
        case .window(let windowID): content.windows.contains { $0.windowID == windowID }
        case .screen(let displayID): content.displays.contains { $0.displayID == displayID }
        case .tab, nil: true
        }
    }

    private func shareableContent(forceRefresh: Bool = false) async -> SCShareableContent? {
        if !forceRefresh, let snapshot, Date().timeIntervalSince(snapshotAt) < snapshotLifetime {
            return snapshot
        }
        guard let fresh = try? await ScreenCaptureKitCalls.shareableContent().value else {
            return nil
        }
        snapshot = fresh
        snapshotAt = Date()
        return fresh
    }
}
