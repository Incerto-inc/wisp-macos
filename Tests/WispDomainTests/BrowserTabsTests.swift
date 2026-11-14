import Testing
import WispDomain

private let chrome = "com.google.Chrome"

private func chromeWindow(
    _ id: Int,
    _ title: String,
    frame: CaptureRect? = nil,
    onScreen: Bool = true,
    z: Int? = nil
) -> CaptureSource {
    CaptureSource(
        id: CaptureSourceID("window:\(id)"),
        kind: .window,
        title: title,
        applicationName: "Google Chrome",
        bundleIdentifier: chrome,
        isOnScreen: onScreen,
        size: frame.map { CaptureSize(width: $0.width, height: $0.height) } ?? CaptureSize(width: 1200, height: 800),
        zOrder: z,
        frame: frame
    )
}

private func tab(_ key: String, _ title: String, _ url: String) -> BrowserTabSnapshot {
    BrowserTabSnapshot(key: key, title: title, url: url)
}

private func browserWindow(
    _ key: String,
    index: Int,
    title: String,
    bounds: CaptureRect? = nil,
    isPrivate: Bool = false,
    active: String?,
    tabs: [BrowserTabSnapshot]
) -> BrowserWindowSnapshot {
    BrowserWindowSnapshot(key: key, index: index, title: title, bounds: bounds, isPrivate: isPrivate, activeTabKey: active, tabs: tabs)
}

private func snapshot(_ windows: [BrowserWindowSnapshot], bundle: String = chrome, name: String = "Google Chrome") -> BrowserSnapshot {
    BrowserSnapshot(bundleIdentifier: bundle, name: name, windows: windows)
}

@Suite("Browser windows → recordable windows")
struct BrowserWindowMatcherTests {
    @Test("a browser window that reports its frame matches the window with the same frame")
    func matchesByFrame() {
        let left = CaptureRect(x: 0, y: 25, width: 900, height: 700)
        let right = CaptureRect(x: 900, y: 25, width: 900, height: 700)
        let windows = [chromeWindow(1, "Docs", frame: left, z: 1), chromeWindow(2, "Docs", frame: right, z: 0)]
        let snap = snapshot([
            browserWindow("a", index: 1, title: "Docs", bounds: CaptureRect(x: 901, y: 26, width: 899, height: 700), active: "t1", tabs: [tab("t1", "Docs", "https://docs.example")]),
            browserWindow("b", index: 2, title: "Docs", bounds: left, active: "t2", tabs: [tab("t2", "Docs", "https://docs.example")]),
        ])
        let match = BrowserWindowMatcher.match(snap, windows: windows)
        #expect(match["a"]?.id == CaptureSourceID("window:2"))
        #expect(match["b"]?.id == CaptureSourceID("window:1"))
    }

    @Test("without frames, a unique title decides")
    func matchesByUniqueTitle() {
        let windows = [chromeWindow(1, "Inbox", z: 0), chromeWindow(2, "Meet – abc-defg-hij", z: 1)]
        let snap = snapshot([
            browserWindow("x", index: 1, title: "Meet – abc-defg-hij", active: "m", tabs: [tab("m", "Meet – abc-defg-hij", "https://meet.google.com/abc-defg-hij")]),
            browserWindow("y", index: 2, title: "Inbox", active: "i", tabs: [tab("i", "Inbox", "https://mail.example")]),
        ])
        let match = BrowserWindowMatcher.match(snap, windows: windows)
        #expect(match["x"]?.id == CaptureSourceID("window:2"))
        #expect(match["y"]?.id == CaptureSourceID("window:1"))
    }

    @Test("when titles do not line up, front-to-back order decides if the counts agree")
    func matchesByOrder() {
        // Some browsers keep a stale title on windows that are not on screen.
        let windows = [chromeWindow(7, "stale", onScreen: false), chromeWindow(8, "also stale", z: 0)]
        let snap = snapshot([
            browserWindow("front", index: 1, title: "Roadmap", active: "r", tabs: [tab("r", "Roadmap", "https://notion.example")]),
            browserWindow("back", index: 2, title: "Calendar", active: "c", tabs: [tab("c", "Calendar", "https://cal.example")]),
        ])
        let match = BrowserWindowMatcher.match(snap, windows: windows)
        #expect(match["front"]?.id == CaptureSourceID("window:8"))
        #expect(match["back"]?.id == CaptureSourceID("window:7"))
    }

    @Test("an ambiguous leftover stays unmatched instead of guessing")
    func leavesAmbiguousUnmatched() {
        let windows = [chromeWindow(1, "A", z: 0), chromeWindow(2, "B", z: 1)]
        let snap = snapshot([browserWindow("only", index: 1, title: "C", active: "t", tabs: [tab("t", "C", "https://c.example")])])
        #expect(BrowserWindowMatcher.match(snap, windows: windows).isEmpty)
    }

    @Test("windows of other apps are never matched")
    func ignoresOtherApps() {
        let slack = CaptureSource(id: CaptureSourceID("window:9"), kind: .window, title: "Inbox", applicationName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")
        let snap = snapshot([browserWindow("w", index: 1, title: "Inbox", active: "t", tabs: [tab("t", "Inbox", "https://mail.example")])])
        #expect(BrowserWindowMatcher.match(snap, windows: [slack]).isEmpty)
    }
}

@Suite("Browser tabs as capture sources")
struct BrowserTabSourcesTests {
    @Test("each tab becomes a source tied to its window; only the shown tab is active")
    func buildsTabSources() throws {
        let host = chromeWindow(5, "Meet – abc-defg-hij", z: 0)
        let snap = snapshot([
            browserWindow("w1", index: 1, title: "Meet – abc-defg-hij", active: "11", tabs: [
                tab("10", "Inbox", "https://mail.example/"),
                tab("11", "Meet – abc-defg-hij", "https://meet.google.com/abc-defg-hij"),
            ]),
        ])
        let sources = BrowserTabs.sources(from: [snap], windows: [host])
        #expect(sources.map(\.id.raw) == ["tab:com.google.Chrome:10", "tab:com.google.Chrome:11"])
        let meet = try #require(sources.last)
        #expect(meet.kind == .tab)
        #expect(meet.title == "Meet – abc-defg-hij")
        #expect(meet.applicationName == "Google Chrome")
        #expect(meet.tab?.isActive == true)
        #expect(meet.tab?.windowID == host.id)
        #expect(meet.tab?.url == "https://meet.google.com/abc-defg-hij")
        #expect(sources.first?.tab?.isActive == false)
    }

    @Test("private windows and windows that could not be matched contribute no tabs")
    func skipsPrivateAndUnmatched() {
        let host = chromeWindow(5, "Work", z: 0)
        let snap = snapshot([
            browserWindow("p", index: 1, title: "Secret", isPrivate: true, active: "s", tabs: [tab("s", "Secret", "https://s.example")]),
            browserWindow("w", index: 2, title: "Work", active: "k", tabs: [tab("k", "Work", "https://work.example")]),
            browserWindow("lost", index: 3, title: "Nowhere", active: "n", tabs: [tab("n", "Nowhere", "https://n.example")]),
        ])
        let sources = BrowserTabs.sources(from: [snap], windows: [host])
        #expect(sources.map(\.id.raw) == ["tab:com.google.Chrome:k"])
    }

    @Test("a tab id round-trips through its source id")
    func tabKeyRoundTrip() throws {
        let key = BrowserTabKey(bundleIdentifier: "com.apple.Safari", tabKey: "https://meet.google.com/abc-defg-hij#2")
        let parsed = try #require(BrowserTabKey(sourceID: key.sourceID))
        #expect(parsed == key)
        #expect(BrowserTabKey(sourceID: CaptureSourceID("window:12")) == nil)
    }

    @Test("the preview of a tab is its window while it is showing, nothing while it is hidden")
    func previewID() {
        let host = chromeWindow(5, "Docs", z: 0)
        let sources = BrowserTabs.sources(from: [snapshot([
            browserWindow("w", index: 1, title: "Docs", active: "a", tabs: [tab("a", "Docs", "https://d.example"), tab("b", "Other", "https://o.example")]),
        ])], windows: [host])
        #expect(sources[0].previewID == host.id)
        #expect(sources[1].previewID == nil)
        #expect(host.previewID == host.id)
    }
}

@Suite("Tab candidates")
struct TabCandidatesTests {
    @Test("orders in-call tabs, other meeting tabs, shown tabs front to back, then the rest in browser order; drops blank pages")
    func ordering() {
        let front = chromeWindow(1, "Docs", frame: CaptureRect(x: 0, y: 0, width: 800, height: 600), z: 0)
        let back = chromeWindow(2, "Mail", frame: CaptureRect(x: 50, y: 50, width: 800, height: 600), z: 1)
        let snap = snapshot([
            browserWindow("f", index: 1, title: "Docs", bounds: CaptureRect(x: 0, y: 0, width: 800, height: 600), active: "docs", tabs: [
                tab("blank", "New Tab", "chrome://newtab/"),
                tab("docs", "Docs", "https://docs.example"),
                tab("landing", "Google Meet", "https://meet.google.com/landing"),
                tab("news", "News", "https://news.example"),
            ]),
            browserWindow("b", index: 2, title: "Mail", bounds: CaptureRect(x: 50, y: 50, width: 800, height: 600), active: "mail", tabs: [
                tab("mail", "Mail", "https://mail.example"),
                tab("call", "Meet – abc-defg-hij", "https://meet.google.com/abc-defg-hij?authuser=0"),
            ]),
        ])
        let ordered = CaptureCandidates.tabs(from: BrowserTabs.sources(from: [snap], windows: [front, back]))
        #expect(ordered.map { $0.tab?.key.tabKey } == ["call", "landing", "docs", "mail", "news"])
    }
}

@Suite("Meetings in browser tabs")
struct TabMeetingDetectorTests {
    private func source(_ url: String, title: String = "") -> CaptureSource {
        let key = BrowserTabKey(bundleIdentifier: chrome, tabKey: "1")
        return CaptureSource(
            id: key.sourceID,
            kind: .tab,
            title: title,
            applicationName: "Google Chrome",
            bundleIdentifier: chrome,
            tab: BrowserTabFacts(key: key, url: url, isActive: false, windowID: CaptureSourceID("window:1"))
        )
    }

    @Test("a Meet room URL is a call even when the tab title says nothing")
    func meetByURL() {
        #expect(MeetingDetector.signal(for: source("https://meet.google.com/abc-defg-hij?authuser=1")) == MeetingSignal(app: .meet, isInCall: true))
        #expect(MeetingDetector.signal(for: source("https://meet.google.com/")) == MeetingSignal(app: .meet, isInCall: false))
    }

    @Test("Zoom's web client, Teams and Webex on the web")
    func otherWebClients() {
        #expect(MeetingDetector.signal(for: source("https://app.zoom.us/wc/81234567890/join?fromPWA=1")) == MeetingSignal(app: .zoom, isInCall: true))
        #expect(MeetingDetector.signal(for: source("https://us02web.zoom.us/j/81234567890")) == MeetingSignal(app: .zoom, isInCall: false))
        #expect(MeetingDetector.signal(for: source("https://teams.microsoft.com/v2/", title: "Meeting with Aki | Microsoft Teams")) == MeetingSignal(app: .teams, isInCall: true))
        #expect(MeetingDetector.signal(for: source("https://teams.microsoft.com/v2/", title: "Chat | Microsoft Teams")) == MeetingSignal(app: .teams, isInCall: false))
        #expect(MeetingDetector.signal(for: source("https://acme.webex.com/meet/aki", title: "Webex Meeting")) == MeetingSignal(app: .webex, isInCall: true))
    }

    @Test("ordinary pages are not meetings, whatever their title says")
    func ordinaryPages() {
        #expect(MeetingDetector.signal(for: source("https://docs.example/notes", title: "Meet – abc-defg-hij notes")) == nil)
    }

    @Test("a meeting in a tab records every app's sound (browsers play audio from helper processes)")
    func tabAudio() {
        let zoomWeb = source("https://app.zoom.us/wc/81234567890/join")
        #expect(AudioSourcePolicy.automatic(inCallMeeting: zoomWeb) == .allApplications)
    }

    @Test("tab labels: title, then the site")
    func labels() {
        let meet = source("https://meet.google.com/abc-defg-hij", title: "Meet – abc-defg-hij")
        #expect(CaptureSourceLabel.title(meet) == "Meet – abc-defg-hij")
        // The row's icon already names the browser; the text gives the site.
        #expect(CaptureSourceLabel.subtitle(meet) == "meet.google.com")
        #expect(CaptureSourceLabel.title(source("https://docs.example/a")) == "docs.example")
    }
}

@Suite("Record choices with tabs")
struct RecordChoicesWithTabsTests {
    @Test("an in-call tab is offered first, ahead of the browser window that shows it")
    func inCallTabFirst() throws {
        let host = chromeWindow(5, "Meet – abc-defg-hij", z: 0)
        let screen = CaptureSource(id: CaptureSourceID("screen:1"), kind: .screen, title: "Built-in Retina Display")
        let tabs = CaptureCandidates.tabs(from: BrowserTabs.sources(from: [snapshot([
            browserWindow("w", index: 1, title: "Meet – abc-defg-hij", active: "m", tabs: [tab("m", "Meet – abc-defg-hij", "https://meet.google.com/abc-defg-hij")]),
        ])], windows: [host]))
        let set = CaptureCandidateSet(windows: [host], screens: [screen], tabs: tabs)
        let choices = try #require(RecordChoices.make(candidates: set, pinned: nil))
        #expect(choices.primary.kind == .tab)
        #expect(choices.inCallMeeting?.kind == .tab)
        #expect(choices.secondary?.id == screen.id)
        #expect(set.inCallMeeting?.id == choices.primary.id)
    }

    @Test("a Meet call in a background tab is found too")
    func backgroundCall() throws {
        let host = chromeWindow(5, "Docs", z: 0)
        let screen = CaptureSource(id: CaptureSourceID("screen:1"), kind: .screen, title: "Display")
        let tabs = CaptureCandidates.tabs(from: BrowserTabs.sources(from: [snapshot([
            browserWindow("w", index: 1, title: "Docs", active: "d", tabs: [tab("d", "Docs", "https://docs.example"), tab("m", "Meet", "https://meet.google.com/abc-defg-hij")]),
        ])], windows: [host]))
        let choices = try #require(RecordChoices.make(candidates: CaptureCandidateSet(windows: [host], screens: [screen], tabs: tabs), pinned: nil))
        #expect(choices.primary.tab?.key.tabKey == "m")
    }
}

@Suite("Following a tab while recording")
struct TabFollowTests {
    private let key = BrowserTabKey(bundleIdentifier: chrome, tabKey: "m")

    @Test("showing in its window, hidden behind another tab, then closed")
    func states() {
        let host = chromeWindow(5, "Meet", z: 0)
        let shown = snapshot([browserWindow("w", index: 1, title: "Meet", active: "m", tabs: [tab("m", "Meet", "u"), tab("d", "Docs", "v")])])
        let hidden = snapshot([browserWindow("w", index: 1, title: "Meet", active: "d", tabs: [tab("m", "Meet", "u"), tab("d", "Docs", "v")])])
        let closed = snapshot([browserWindow("w", index: 1, title: "Docs", active: "d", tabs: [tab("d", "Docs", "v")])])
        #expect(TabFollow.state(of: key, snapshot: shown, windows: [host]) == .showing(window: host.id))
        #expect(TabFollow.state(of: key, snapshot: hidden, windows: [host]) == .hidden(window: host.id))
        #expect(TabFollow.state(of: key, snapshot: closed, windows: [host]) == .closed)
        #expect(TabFollow.state(of: key, snapshot: nil, windows: [host]) == .closed)
    }

    @Test("a tab dragged into its own window is followed to that window")
    func followsMove() {
        let old = chromeWindow(5, "Docs", frame: CaptureRect(x: 0, y: 0, width: 1000, height: 700), z: 1)
        let new = chromeWindow(6, "Meet", frame: CaptureRect(x: 300, y: 200, width: 640, height: 480), z: 0)
        let moved = snapshot([
            browserWindow("w", index: 2, title: "Docs", bounds: CaptureRect(x: 0, y: 0, width: 1000, height: 700), active: "d", tabs: [tab("d", "Docs", "v")]),
            browserWindow("n", index: 1, title: "Meet", bounds: CaptureRect(x: 300, y: 200, width: 640, height: 480), active: "m", tabs: [tab("m", "Meet", "u")]),
        ])
        #expect(TabFollow.state(of: key, snapshot: moved, windows: [old, new]) == .showing(window: new.id))
    }
}
