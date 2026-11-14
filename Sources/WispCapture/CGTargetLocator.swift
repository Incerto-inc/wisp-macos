import CoreGraphics
import Foundation
import WispApplication
import WispDomain

/// Finds the on-screen rectangle (and the title) of a window or display ID this module issued.
/// Uses CGWindowList / CGDisplay only — cheap enough to poll ten times a second.
/// Tab ids are resolved to their window by the caller (`CaptureSource.previewID`, `VideoTarget`).
public struct CGTargetLocator: CaptureTargetLocating, WindowTitleReading {
    public init() {}

    public func frame(of id: CaptureSourceID) async -> CaptureTargetFrame? {
        switch CaptureTargetID(id) {
        case .window(let windowID):
            guard let info = Self.windowInfo(windowID),
                  (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 0, rect.height > 0
            else { return nil }
            return CaptureTargetFrame(rect: rect, isDisplay: false)
        case .screen(let displayID):
            let rect = CGDisplayBounds(displayID)
            guard rect.width > 0, rect.height > 0 else { return nil }
            return CaptureTargetFrame(rect: rect, isDisplay: true)
        case .tab, nil:
            return nil
        }
    }

    /// The window's current title ("" when it has none); `nil` when the window is gone.
    public func title(of id: CaptureSourceID) async -> String? {
        guard case .window(let windowID) = CaptureTargetID(id), let info = Self.windowInfo(windowID) else { return nil }
        return info[kCGWindowName as String] as? String ?? ""
    }

    private static func windowInfo(_ windowID: CGWindowID) -> [String: Any]? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] else { return nil }
        return list.first { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }
}
