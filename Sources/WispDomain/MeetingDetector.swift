import Foundation

public enum MeetingApp: String, Sendable, Equatable {
    case zoom
    case teams
    case meet
    case webex
}

public struct MeetingSignal: Sendable, Equatable {
    public let app: MeetingApp
    public let isInCall: Bool

    public init(app: MeetingApp, isInCall: Bool) {
        self.app = app
        self.isInCall = isInCall
    }
}

/// Recognises meeting windows from bundle IDs and titles only — on this Mac, no network.
public enum MeetingDetector {
    /// `nil` when the source is not a meeting app's window or a meeting web page.
    public static func signal(for source: CaptureSource) -> MeetingSignal? {
        if source.kind == .tab { return tabSignal(source) }
        guard source.kind == .window else { return nil }
        let bundle = (source.bundleIdentifier ?? "").lowercased()
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if bundle.contains("zoom") {
            return MeetingSignal(app: .zoom, isInCall: zoomInCall(title))
        }
        if bundle.hasPrefix("com.microsoft.teams") {
            return MeetingSignal(app: .teams, isInCall: teamsInCall(title))
        }
        if bundle.contains("webex") {
            return MeetingSignal(app: .webex, isInCall: title.contains("meeting"))
        }
        if browsers.contains(bundle), isMeetCall(title) {
            return MeetingSignal(app: .meet, isInCall: true)
        }
        return nil
    }

    /// Browsers that host Google Meet. Other apps' titles never count as a Meet call.
    static let browsers: Set<String> = [
        "com.google.chrome", "com.google.chrome.canary", "com.google.chrome.beta",
        "company.thebrowser.browser", "company.thebrowser.dia",
        "com.apple.safari", "com.apple.safaritechnologypreview",
        "com.microsoft.edgemac", "com.brave.browser", "org.mozilla.firefox",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "app.zen-browser.zen",
    ]

    /// A tab is judged by its URL — far more reliable than its title.
    private static func tabSignal(_ source: CaptureSource) -> MeetingSignal? {
        guard let url = source.tab?.url, let components = URLComponents(string: url),
              let host = components.host?.lowercased()
        else { return nil }
        let path = components.path.lowercased()
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if host == "meet.google.com" {
            return MeetingSignal(app: .meet, isInCall: path.contains(#/^/[a-z]{3}-[a-z]{4}-[a-z]{3}(/|$)/#))
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            // The web client lives under /wc/<meeting id>/…; /j/<id> is only the launcher page.
            return MeetingSignal(app: .zoom, isInCall: path.hasPrefix("/wc/"))
        }
        if webTeamsHosts.contains(host) {
            return MeetingSignal(app: .teams, isInCall: teamsInCall(title))
        }
        if host == "webex.com" || host.hasSuffix(".webex.com") {
            return MeetingSignal(app: .webex, isInCall: title.contains("meeting"))
        }
        return nil
    }

    private static let webTeamsHosts: Set<String> = ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"]

    private static func zoomInCall(_ title: String) -> Bool {
        title.contains("meeting") || title.contains("webinar") || title.contains("floating video")
    }

    private static func teamsInCall(_ title: String) -> Bool {
        guard title != "microsoft teams" else { return false }
        // "Calls | Microsoft Teams" is the Calls tab, not a call.
        return title.contains("meeting") || title.contains("call with") || title.hasPrefix("call ") || title.contains("| call ")
    }

    /// Google Meet tabs are titled "Meet – <code or event>"; the landing page is "Google Meet: …".
    private static func isMeetCall(_ title: String) -> Bool {
        if title.hasPrefix("meet - ") || title.hasPrefix("meet – ") { return true }
        return title.contains("google meet") && title.contains(#/\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b/#)
    }
}
