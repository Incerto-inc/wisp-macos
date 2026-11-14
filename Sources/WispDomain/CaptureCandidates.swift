import Foundation

/// The windows, displays and browser tabs offered in the picker.
public struct CaptureCandidateSet: Sendable, Equatable {
    public var windows: [CaptureSource]
    public var screens: [CaptureSource]
    /// Tabs of browsers Wisp may read, ordered by `CaptureCandidates.tabs(from:)`.
    public var tabs: [CaptureSource]
    /// Every running browser Wisp could read tabs from, with Wisp's access to it.
    public var tabAccess: [BrowserTabStatus]

    public init(
        windows: [CaptureSource],
        screens: [CaptureSource],
        tabs: [CaptureSource] = [],
        tabAccess: [BrowserTabStatus] = []
    ) {
        self.windows = windows
        self.screens = screens
        self.tabs = tabs
        self.tabAccess = tabAccess
    }

    public static let empty = CaptureCandidateSet(windows: [], screens: [])

    /// The meeting that is in a call: a meeting tab first (it names the call precisely), else a window.
    public var inCallMeeting: CaptureSource? {
        tabs.first(where: CaptureCandidates.isInCall) ?? windows.first(where: CaptureCandidates.isInCall)
    }
}

/// Which of the ~170 windows ScreenCaptureKit reports are real, recordable work windows,
/// and in what order to offer them.
public enum CaptureCandidates {
    public static let minimumWindowSize = CaptureSize(width: 160, height: 100)

    public static func isRecordable(_ source: CaptureSource, ownBundleIdentifier: String?) -> Bool {
        if source.kind == .screen { return true }
        guard source.isNormalLayer, source.ownerIsRegularApp else { return false }
        if let size = source.size,
           size.width < minimumWindowSize.width || size.height < minimumWindowSize.height
        {
            return false
        }
        let untitled = source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if untitled, !source.isOnScreen { return false }
        if let ownBundleIdentifier, source.bundleIdentifier == ownBundleIdentifier { return false }
        return true
    }

    /// Recordable windows: in-call meetings, other meeting-app windows, on-screen windows
    /// front to back, then windows that are not on screen.
    public static func windows(from sources: [CaptureSource], ownBundleIdentifier: String?) -> [CaptureSource] {
        sources
            .filter { $0.kind == .window && isRecordable($0, ownBundleIdentifier: ownBundleIdentifier) }
            .sorted(by: precedes)
    }

    /// Browser tabs: in-call meeting tabs, other meeting tabs, tabs that are showing (front to
    /// back), then the rest in browser order. Blank pages (new tab, about:blank) are left out.
    public static func tabs(from sources: [CaptureSource]) -> [CaptureSource] {
        sources.enumerated()
            .filter { $0.element.kind == .tab && !isBlankPage($0.element) }
            .sorted { lhs, rhs in
                let (lg, rg) = (tabGroup(lhs.element), tabGroup(rhs.element))
                if lg != rg { return lg < rg }
                if lg == 2 {
                    let (lz, rz) = (lhs.element.zOrder ?? .max, rhs.element.zOrder ?? .max)
                    if lz != rz { return lz < rz }
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func isInCall(_ source: CaptureSource) -> Bool {
        MeetingDetector.signal(for: source)?.isInCall == true
    }

    private static func tabGroup(_ source: CaptureSource) -> Int {
        if let signal = MeetingDetector.signal(for: source) {
            return signal.isInCall ? 0 : 1
        }
        return source.tab?.isActive == true && source.isOnScreen ? 2 : 3
    }

    private static func isBlankPage(_ source: CaptureSource) -> Bool {
        let url = (source.tab?.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return url.isEmpty || url == "about:blank" || url.hasSuffix("://newtab/") || url.hasSuffix("://newtab")
            || url.hasPrefix("favorites://")
    }

    /// Displays in the order the adapter reports them (main display first).
    public static func screens(from sources: [CaptureSource]) -> [CaptureSource] {
        sources.filter { $0.kind == .screen }
    }

    private static func group(_ source: CaptureSource) -> Int {
        if let signal = MeetingDetector.signal(for: source) {
            return signal.isInCall ? 0 : 1
        }
        return source.isOnScreen ? 2 : 3
    }

    private static func precedes(_ lhs: CaptureSource, _ rhs: CaptureSource) -> Bool {
        let (lg, rg) = (group(lhs), group(rhs))
        if lg != rg { return lg < rg }
        let (lz, rz) = (lhs.zOrder ?? .max, rhs.zOrder ?? .max)
        if lz != rz { return lz < rz }
        let (la, ra) = (CaptureSourceLabel.appName(lhs), CaptureSourceLabel.appName(rhs))
        let byApp = la.localizedCaseInsensitiveCompare(ra)
        if byApp != .orderedSame { return byApp == .orderedAscending }
        return CaptureSourceLabel.title(lhs).localizedCaseInsensitiveCompare(CaptureSourceLabel.title(rhs)) == .orderedAscending
    }
}
