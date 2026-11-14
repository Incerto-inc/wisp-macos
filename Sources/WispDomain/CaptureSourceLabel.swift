import Foundation

public enum AppName {
    /// Human name for an app ("zoom.us" → "Zoom").
    public static func friendly(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "zoom.us" { return "Zoom" }
        return trimmed
    }
}

/// Picker / card text for a source.
public enum CaptureSourceLabel {
    public static func appName(_ source: CaptureSource) -> String {
        AppName.friendly(source.applicationName ?? source.bundleIdentifier ?? "")
    }

    /// Window or tab title; the app name for untitled windows, the host for untitled tabs;
    /// display name for screens.
    public static func title(_ source: CaptureSource) -> String {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if source.kind == .tab {
            let host = source.tab?.host ?? ""
            return host.isEmpty ? "Tab" : host
        }
        let app = appName(source)
        return app.isEmpty ? "Window" : app
    }

    /// App name, marked when the window is on another desktop (or minimized/hidden);
    /// the site's host for tabs.
    public static func subtitle(_ source: CaptureSource) -> String {
        switch source.kind {
        case .screen:
            return "Entire screen"
        case .tab:
            // The browser shows as the row's icon; the text names the site.
            let host = source.tab?.host ?? ""
            return host.isEmpty ? appName(source) : host
        case .window:
            let app = appName(source)
            return source.isOnScreen ? app : "\(app) · Other Desktop"
        }
    }
}
