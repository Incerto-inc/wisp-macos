import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import WispApplication
import WispDomain

/// ScreenCaptureKit adapter for listing. Reports every window with the facts
/// `CaptureCandidates` needs; the filtering itself is a domain rule.
public struct SCKCaptureSourceListing: CaptureSourceListing {
    public var includeOffScreenWindows: Bool

    public init(includeOffScreenWindows: Bool = true) {
        self.includeOffScreenWindows = includeOffScreenWindows
    }

    public func listShareableSources() async throws -> [CaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: !includeOffScreenWindows
        )
        let zOrder = Self.onScreenZOrder()
        let (regularPIDs, displayNames) = await MainActor.run {
            (Self.regularAppPIDs(), Self.displayNames())
        }

        let windows = content.windows.map { window -> CaptureSource in
            let app = window.owningApplication
            return CaptureSource(
                id: CaptureTargetID.window(window.windowID).sourceID,
                kind: .window,
                title: window.title ?? "",
                applicationName: app?.applicationName,
                bundleIdentifier: app?.bundleIdentifier,
                isOnScreen: window.isOnScreen,
                isNormalLayer: window.windowLayer == 0,
                ownerIsRegularApp: app.map { regularPIDs.contains($0.processID) } ?? false,
                size: CaptureSize(width: window.frame.width, height: window.frame.height),
                zOrder: zOrder[window.windowID],
                frame: CaptureRect(
                    x: window.frame.origin.x,
                    y: window.frame.origin.y,
                    width: window.frame.width,
                    height: window.frame.height
                )
            )
        }

        let mainID = CGMainDisplayID()
        let displays = content.displays
            .sorted { ($0.displayID == mainID ? 0 : 1) < ($1.displayID == mainID ? 0 : 1) }
            .map { display -> CaptureSource in
                CaptureSource(
                    id: CaptureTargetID.screen(display.displayID).sourceID,
                    kind: .screen,
                    title: displayNames[display.displayID] ?? "Display",
                    size: CaptureSize(width: Double(display.width), height: Double(display.height))
                )
            }

        return windows + displays
    }

    /// Front-to-back index of normal on-screen windows on the current Space.
    static func onScreenZOrder() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [:] }
        var order: [CGWindowID: Int] = [:]
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  (entry[kCGWindowLayer as String] as? Int) == 0
            else { continue }
            order[number] = order.count
        }
        return order
    }

    @MainActor
    static func regularAppPIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
    }

    /// "Built-in Retina Display", "LG UltraFine", … keyed by display ID.
    @MainActor
    static func displayNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
            }
        }
        return names
    }
}
