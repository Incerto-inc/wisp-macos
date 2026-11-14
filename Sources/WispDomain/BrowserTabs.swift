import Foundation

/// One tab as a browser's scripting interface reports it.
public struct BrowserTabSnapshot: Sendable, Equatable {
    /// Stable within the browser's session (Chrome's tab id, Arc's tab id, …).
    public var key: String
    public var title: String
    public var url: String

    public init(key: String, title: String, url: String) {
        self.key = key
        self.title = title
        self.url = url
    }
}

/// One browser window as its scripting interface reports it.
public struct BrowserWindowSnapshot: Sendable, Equatable {
    /// The browser's own window id (not a CoreGraphics window number).
    public var key: String
    /// Front-to-back order within the browser; 1 is frontmost.
    public var index: Int
    /// Window name — the shown tab's title in every supported browser.
    public var title: String
    /// Frame in global coordinates, when the browser reports one (Chrome family, Safari).
    public var bounds: CaptureRect?
    /// Incognito / private windows. Their tabs are never listed.
    public var isPrivate: Bool
    public var activeTabKey: String?
    public var tabs: [BrowserTabSnapshot]

    public init(
        key: String,
        index: Int,
        title: String,
        bounds: CaptureRect?,
        isPrivate: Bool,
        activeTabKey: String?,
        tabs: [BrowserTabSnapshot]
    ) {
        self.key = key
        self.index = index
        self.title = title
        self.bounds = bounds
        self.isPrivate = isPrivate
        self.activeTabKey = activeTabKey
        self.tabs = tabs
    }
}

/// Every window and tab of one running browser.
public struct BrowserSnapshot: Sendable, Equatable {
    public var bundleIdentifier: String
    /// The browser's display name ("Google Chrome", "Arc", …).
    public var name: String
    public var windows: [BrowserWindowSnapshot]

    public init(bundleIdentifier: String, name: String, windows: [BrowserWindowSnapshot]) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.windows = windows
    }
}

/// Whether macOS lets Wisp read a browser's tabs (Privacy & Security → Automation).
public enum BrowserTabAccess: Sendable, Equatable {
    case granted
    /// macOS has not asked yet; asking shows the system prompt once.
    case notDetermined
    /// The user said no; only System Settings can change it.
    case denied
}

/// A running browser whose tabs Wisp can read, and Wisp's access to it.
public struct BrowserTabStatus: Sendable, Equatable, Identifiable {
    public var bundleIdentifier: String
    public var name: String
    public var access: BrowserTabAccess

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String, access: BrowserTabAccess) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.access = access
    }
}

/// Finds which recordable window shows each browser window. Scripting interfaces and
/// ScreenCaptureKit number windows differently, so the match uses what both report.
public enum BrowserWindowMatcher {
    /// Points of slack when comparing frames (scripting and window-server frames can differ by a point).
    static let frameTolerance = 4.0

    /// Browser window key → recordable window. Windows that cannot be told apart stay unmatched.
    public static func match(_ snapshot: BrowserSnapshot, windows: [CaptureSource]) -> [String: CaptureSource] {
        let bundle = snapshot.bundleIdentifier.lowercased()
        var pool = windows.filter { $0.kind == .window && $0.bundleIdentifier?.lowercased() == bundle }
        var pending = snapshot.windows.sorted { $0.index < $1.index }
        var result: [String: CaptureSource] = [:]

        func take(_ source: CaptureSource, for key: String) {
            result[key] = source
            pool.removeAll { $0.id == source.id }
        }

        // 1. Same frame (Chrome family and Safari report one).
        for window in pending {
            guard let bounds = window.bounds else { continue }
            let hits = pool.filter { $0.frame?.isClose(to: bounds, tolerance: frameTolerance) ?? false }
            if let pick = closest(hits, title: window.title) { take(pick, for: window.key) }
        }
        pending.removeAll { result[$0.key] != nil }

        // 2. Same title, only when exactly one window has it.
        for window in pending {
            let title = normalized(window.title)
            guard !title.isEmpty else { continue }
            let hits = pool.filter { normalized($0.title) == title }
            if hits.count == 1 { take(hits[0], for: window.key) }
        }
        pending.removeAll { result[$0.key] != nil }

        // 3. Front-to-back order, only when every remaining window has exactly one partner.
        if !pending.isEmpty, pending.count == pool.count {
            let ordered = pool.sorted { frontToBack($0) < frontToBack($1) }
            for (window, source) in zip(pending, ordered) { result[window.key] = source }
        }
        return result
    }

    private static func closest(_ hits: [CaptureSource], title: String) -> CaptureSource? {
        guard hits.count > 1 else { return hits.first }
        let wanted = normalized(title)
        return hits.first { normalized($0.title) == wanted } ?? hits.min { frontToBack($0) < frontToBack($1) }
    }

    private static func frontToBack(_ source: CaptureSource) -> (Int, Int) {
        (source.isOnScreen ? 0 : 1, source.zOrder ?? .max)
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum BrowserTabs {
    /// A source for every tab whose window could be matched to a recordable window.
    /// Private windows are skipped. Order: browsers as given, windows front to back, tabs left to right.
    public static func sources(from snapshots: [BrowserSnapshot], windows: [CaptureSource]) -> [CaptureSource] {
        snapshots.flatMap { snapshot -> [CaptureSource] in
            let hosts = BrowserWindowMatcher.match(snapshot, windows: windows)
            return snapshot.windows.sorted { $0.index < $1.index }.flatMap { window -> [CaptureSource] in
                guard !window.isPrivate, let host = hosts[window.key] else { return [] }
                return window.tabs.map { tab in
                    let key = BrowserTabKey(bundleIdentifier: snapshot.bundleIdentifier, tabKey: tab.key)
                    return CaptureSource(
                        id: key.sourceID,
                        kind: .tab,
                        title: tab.title,
                        applicationName: snapshot.name,
                        bundleIdentifier: snapshot.bundleIdentifier,
                        isOnScreen: host.isOnScreen,
                        size: host.size,
                        zOrder: host.zOrder,
                        frame: host.frame,
                        tab: BrowserTabFacts(key: key, url: tab.url, isActive: tab.key == window.activeTabKey, windowID: host.id)
                    )
                }
            }
        }
    }
}

/// Where a recorded tab is right now.
public enum TabFollowState: Sendable, Equatable {
    /// The tab is the one `window` shows: record that window's frames.
    case showing(window: CaptureSourceID)
    /// The tab exists but another tab is showing (or its window cannot be found): hold the last frame.
    case hidden(window: CaptureSourceID?)
    /// The tab, or the whole browser, is gone: hold the last frame.
    case closed
}

public enum TabFollow {
    /// `snapshot` is the tab's browser; `nil` when it could not be read (quit, access revoked).
    public static func state(of key: BrowserTabKey, snapshot: BrowserSnapshot?, windows: [CaptureSource]) -> TabFollowState {
        guard let snapshot else { return .closed }
        let hosts = BrowserWindowMatcher.match(snapshot, windows: windows)
        for window in snapshot.windows where window.tabs.contains(where: { $0.key == key.tabKey }) {
            let host = hosts[window.key]?.id
            if window.activeTabKey == key.tabKey, let host { return .showing(window: host) }
            return .hidden(window: host)
        }
        return .closed
    }
}
