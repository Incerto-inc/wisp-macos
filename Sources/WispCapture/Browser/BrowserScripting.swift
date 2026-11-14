import Foundation
import WispDomain

/// Browsers whose scripting dictionaries Wisp knows. Each family reads tabs a little differently.
enum BrowserFamily: CaseIterable, Sendable {
    /// Chrome, Brave, Edge, Vivaldi, Chromium: windows report bounds, `mode`, `active tab index`.
    case chromium
    /// Arc: no bounds; `incognito`; tabs are selected with `select`.
    case arc
    /// Dia: no bounds; tabs are brought forward with `focus`.
    case dia
    /// Safari: bounds and `current tab`, but tabs have no id.
    case safari
}

enum SupportedBrowsers {
    /// Order is the order browsers appear in the picker.
    static let all: [(bundleIdentifier: String, family: BrowserFamily)] = [
        ("com.google.Chrome", .chromium),
        ("com.google.Chrome.beta", .chromium),
        ("com.google.Chrome.dev", .chromium),
        ("com.google.Chrome.canary", .chromium),
        ("com.google.chrome.for.testing", .chromium),
        ("company.thebrowser.Browser", .arc),
        ("company.thebrowser.dia", .dia),
        ("com.apple.Safari", .safari),
        ("com.apple.SafariTechnologyPreview", .safari),
        ("com.microsoft.edgemac", .chromium),
        ("com.microsoft.edgemac.Beta", .chromium),
        ("com.microsoft.edgemac.Dev", .chromium),
        ("com.microsoft.edgemac.Canary", .chromium),
        ("com.brave.Browser", .chromium),
        ("com.vivaldi.Vivaldi", .chromium),
        ("org.chromium.Chromium", .chromium),
    ]

    static func family(for bundleIdentifier: String) -> BrowserFamily? {
        all.first { $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }?.family
    }
}

/// JavaScript for Automation run by `osascript`. `argv[0]` is the browser's bundle id and,
/// for `show`, `argv[1]` the tab key — passed as arguments, never pasted into the source.
///
/// Every script first checks `app.running()`: talking to a browser that has quit would launch it.
/// Tabs are read with one Apple Event per property per window (`w.tabs.url()`), never per tab.
enum BrowserScripts {
    static func snapshot(_ family: BrowserFamily) -> String {
        let window: String
        switch family {
        case .chromium:
            window = """
                const ids = w.tabs.id().map(String), titles = w.tabs.title(), urls = w.tabs.url();
                return { key: String(w.id()), index: i + 1, title: String(w.name() || ''), bounds: w.bounds(),
                         private: w.mode() === 'incognito', active: String(w.activeTab.id()),
                         tabs: ids.map((id, j) => ({ key: id, title: titles[j] || '', url: urls[j] || '' })) };
            """
        case .arc:
            window = """
                const ids = w.tabs.id().map(String), titles = w.tabs.title(), urls = w.tabs.url();
                let incognito = false; try { incognito = w.incognito() } catch (e) {}
                return { key: String(w.id()), index: i + 1, title: String(w.name() || ''), bounds: null,
                         private: incognito, active: String(w.activeTab.id()),
                         tabs: ids.map((id, j) => ({ key: id, title: titles[j] || '', url: urls[j] || '' })) };
            """
        case .dia:
            window = """
                const ids = w.tabs.id().map(String), titles = w.tabs.title(), urls = w.tabs.url();
                return { key: String(w.id()), index: i + 1, title: String(w.name() || ''), bounds: null,
                         private: false, active: String(w.activeTab.id()),
                         tabs: ids.map((id, j) => ({ key: id, title: titles[j] || '', url: urls[j] || '' })) };
            """
        case .safari:
            window = """
                const titles = w.tabs.name(), urls = w.tabs.url();
                return { key: String(w.id()), index: i + 1, title: String(w.name() || ''), bounds: w.bounds(),
                         private: false, activeIndex: w.currentTab.index(),
                         tabs: titles.map((t, j) => ({ title: t || '', url: urls[j] || '' })) };
            """
        }
        return """
        function readWindow(w, i) {
        \(window)
        }
        function run(argv) {
            const app = Application(argv[0]);
            if (!app.running()) return 'null';
            const windows = app.windows, out = [];
            const count = windows.length;
            for (let i = 0; i < count; i++) {
                try { out.push(readWindow(windows[i], i)); } catch (e) { /* a window without tabs (settings, a sheet) */ }
            }
            return JSON.stringify({ windows: out });
        }
        """
    }

    static func show(_ family: BrowserFamily) -> String {
        let reveal: String
        switch family {
        case .chromium:
            reveal = "w.activeTabIndex = j + 1;"
        case .arc:
            reveal = "try { w.tabs[j].select(); } catch (e) { app.select(w.tabs[j]); }"
        case .dia:
            reveal = "try { w.tabs[j].focus(); } catch (e) { app.focus(w.tabs[j]); }"
        case .safari:
            reveal = "w.currentTab = w.tabs[j];"
        }
        let keys = family == .safari
            ? "w.tabs.url().map((u, j) => String(w.id()) + '/' + (j + 1))"
            : "w.tabs.id().map(String)"
        return """
        function run(argv) {
            const app = Application(argv[0]);
            if (!app.running()) return 'false';
            const windows = app.windows;
            const count = windows.length;
            for (let i = 0; i < count; i++) {
                const w = windows[i];
                let keys = [];
                try { keys = \(keys); } catch (e) { continue; }
                const j = keys.indexOf(argv[1]);
                if (j >= 0) { \(reveal) return 'true'; }
            }
            return 'false';
        }
        """
    }
}

/// Turns a snapshot script's JSON into the domain snapshot.
enum BrowserSnapshotParser {
    private struct Output: Decodable {
        var windows: [Window]
    }

    private struct Window: Decodable {
        var key: String
        var index: Int
        var title: String
        var bounds: Bounds?
        var `private`: Bool?
        var active: String?
        var activeIndex: Int?
        var tabs: [Tab]
    }

    private struct Bounds: Decodable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    private struct Tab: Decodable {
        var key: String?
        var title: String
        var url: String
    }

    /// `nil` when the browser quit while being read (the script printed `null`).
    static func parse(_ data: Data, bundleIdentifier: String, name: String) throws -> BrowserSnapshot? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "null" { return nil }
        let output = try JSONDecoder().decode(Output.self, from: Data(text.utf8))
        // Safari tabs have no id: a tab is "<window id>/<position>". Its address can change
        // (meeting pages rewrite theirs) without losing it; reordering tabs in front of it or
        // moving it to another window does lose it, and Wisp then holds the last frame.
        let windows = output.windows.map { window -> BrowserWindowSnapshot in
            let tabs = window.tabs.enumerated().map { position, tab -> BrowserTabSnapshot in
                let key = tab.key ?? "\(window.key)/\(position + 1)"
                return BrowserTabSnapshot(key: key, title: tab.title, url: tab.url)
            }
            let active = window.active ?? window.activeIndex.flatMap { index in
                tabs.indices.contains(index - 1) ? tabs[index - 1].key : nil
            }
            return BrowserWindowSnapshot(
                key: window.key,
                index: window.index,
                title: window.title,
                bounds: window.bounds.map { CaptureRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                isPrivate: window.private ?? false,
                activeTabKey: active,
                tabs: tabs
            )
        }
        return BrowserSnapshot(bundleIdentifier: bundleIdentifier, name: name, windows: windows)
    }
}

/// `AEDeterminePermissionToAutomateTarget` answers, as tab access.
enum BrowserAccessStatus {
    /// `nil` when the browser is not running (procNotFound) — it is then not offered at all.
    static func access(from status: OSStatus) -> BrowserTabAccess? {
        switch status {
        case noErr: return .granted
        case -1743: return .denied // errAEEventNotPermitted
        case -600: return nil // procNotFound
        default: return .notDetermined // -1744 errAEEventWouldRequireUserConsent, or not answerable yet
        }
    }
}

enum BrowserScriptError: Error, Equatable, Sendable {
    case timedOut
    case notAuthorized
    case failed(status: Int32)
    case browserNotRunning
}
