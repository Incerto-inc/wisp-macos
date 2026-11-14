import CoreGraphics
import WispDomain

/// The source ids this module issues, parsed in one place:
/// `window:<CGWindowID>`, `screen:<CGDirectDisplayID>` and `tab:<bundle id>:<tab key>`.
enum CaptureTargetID: Equatable, Sendable {
    case window(CGWindowID)
    case screen(CGDirectDisplayID)
    case tab(BrowserTabKey)

    init?(_ id: CaptureSourceID) {
        let raw = id.raw
        if raw.hasPrefix("window:"), let number = UInt32(raw.dropFirst("window:".count)) {
            self = .window(number)
        } else if raw.hasPrefix("screen:"), let number = UInt32(raw.dropFirst("screen:".count)) {
            self = .screen(number)
        } else if let key = BrowserTabKey(sourceID: id) {
            self = .tab(key)
        } else {
            return nil
        }
    }

    /// Windows and displays can be captured directly; a tab only through its window.
    var isCapturable: Bool {
        if case .tab = self { return false }
        return true
    }

    var sourceID: CaptureSourceID {
        switch self {
        case .window(let number): CaptureSourceID("window:\(number)")
        case .screen(let number): CaptureSourceID("screen:\(number)")
        case .tab(let key): key.sourceID
        }
    }
}
