import Foundation

/// Domain view of a capturable window, screen or browser tab — never an SCWindow / CGWindowID leak.
public struct CaptureSourceID: Hashable, Sendable, Codable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }
}

public enum CaptureSourceKind: String, Sendable, Codable {
    case window
    case screen
    /// One tab of a browser window. Recording it records its window while the tab is the one shown.
    case tab
}

public struct CaptureSize: Sendable, Equatable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A rectangle in CoreGraphics global coordinates (origin at the top-left of the main display), in points.
public struct CaptureRect: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Every edge within `tolerance` points of the other rectangle's.
    public func isClose(to other: CaptureRect, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

/// Names one tab of one browser. Browsers that have no stable tab id get a key from the adapter.
public struct BrowserTabKey: Sendable, Hashable, Codable {
    public var bundleIdentifier: String
    public var tabKey: String

    public init(bundleIdentifier: String, tabKey: String) {
        self.bundleIdentifier = bundleIdentifier
        self.tabKey = tabKey
    }

    /// `tab:<bundle id>:<tab key>`. Bundle ids never contain a colon, so the first one after the prefix splits.
    public var sourceID: CaptureSourceID { CaptureSourceID("tab:\(bundleIdentifier):\(tabKey)") }

    public init?(sourceID: CaptureSourceID) {
        let raw = sourceID.raw
        guard raw.hasPrefix("tab:") else { return nil }
        let rest = raw.dropFirst("tab:".count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let bundle = String(rest[..<colon])
        let key = String(rest[rest.index(after: colon)...])
        guard !bundle.isEmpty, !key.isEmpty else { return nil }
        self.init(bundleIdentifier: bundle, tabKey: key)
    }
}

/// What a tab source knows about its tab. Set only when `kind == .tab`.
public struct BrowserTabFacts: Sendable, Equatable, Hashable {
    public var key: BrowserTabKey
    public var url: String
    /// True when this tab is the one its window shows right now.
    public var isActive: Bool
    /// The recordable window that holds the tab.
    public var windowID: CaptureSourceID?

    public init(key: BrowserTabKey, url: String, isActive: Bool, windowID: CaptureSourceID?) {
        self.key = key
        self.url = url
        self.isActive = isActive
        self.windowID = windowID
    }

    /// Lower-cased host of `url`, or "" when it has none.
    public var host: String {
        URLComponents(string: url)?.host?.lowercased() ?? ""
    }
}

/// A window, display or browser tab the user could record. The capture adapter fills the facts
/// that `CaptureCandidates` needs to decide whether a window is a real, recordable one.
public struct CaptureSource: Sendable, Equatable, Identifiable {
    public var id: CaptureSourceID
    public var kind: CaptureSourceKind
    /// Raw window title (may be empty) or the display's name.
    public var title: String
    public var applicationName: String?
    public var bundleIdentifier: String?
    /// False for windows on another Space, minimized, or hidden.
    public var isOnScreen: Bool
    /// True for ordinary app windows (window layer 0) — not the menu bar, Dock, or overlays.
    public var isNormalLayer: Bool
    /// True when the owning app shows in the Dock — not a helper or background agent.
    public var ownerIsRegularApp: Bool
    /// Window frame size in points; `nil` when unknown.
    public var size: CaptureSize?
    /// Front-to-back position among on-screen windows; 0 is frontmost.
    public var zOrder: Int?
    /// Window frame in global coordinates; `nil` when unknown. Used to match browser windows.
    public var frame: CaptureRect?
    /// Tab facts for `kind == .tab`; `nil` otherwise.
    public var tab: BrowserTabFacts?

    public init(
        id: CaptureSourceID,
        kind: CaptureSourceKind,
        title: String,
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        isOnScreen: Bool = true,
        isNormalLayer: Bool = true,
        ownerIsRegularApp: Bool = true,
        size: CaptureSize? = nil,
        zOrder: Int? = nil,
        frame: CaptureRect? = nil,
        tab: BrowserTabFacts? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.isOnScreen = isOnScreen
        self.isNormalLayer = isNormalLayer
        self.ownerIsRegularApp = ownerIsRegularApp
        self.size = size
        self.zOrder = zOrder
        self.frame = frame
        self.tab = tab
    }

    /// The source whose picture stands for this one: a tab shows its window's picture while it is
    /// the shown tab, and has none while hidden.
    public var previewID: CaptureSourceID? {
        guard kind == .tab else { return id }
        guard let tab, tab.isActive else { return nil }
        return tab.windowID
    }
}
