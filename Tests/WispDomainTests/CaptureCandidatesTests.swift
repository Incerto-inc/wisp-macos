import Testing
import WispDomain

func window(
    _ id: Int,
    _ title: String,
    app: String,
    bundle: String,
    onScreen: Bool = true,
    normalLayer: Bool = true,
    regularApp: Bool = true,
    size: CaptureSize? = CaptureSize(width: 800, height: 600),
    z: Int? = nil
) -> CaptureSource {
    CaptureSource(
        id: CaptureSourceID("window:\(id)"),
        kind: .window,
        title: title,
        applicationName: app,
        bundleIdentifier: bundle,
        isOnScreen: onScreen,
        isNormalLayer: normalLayer,
        ownerIsRegularApp: regularApp,
        size: size,
        zOrder: z
    )
}

func display(_ id: Int, _ name: String) -> CaptureSource {
    CaptureSource(id: CaptureSourceID("screen:\(id)"), kind: .screen, title: name)
}

@Suite("CaptureCandidates")
struct CaptureCandidatesTests {
    @Test("drops windows outside the normal window layer")
    func dropsNonNormalLayer() {
        let menubar = window(1, "Menubar", app: "Window Server", bundle: "com.apple.WindowServer", normalLayer: false)
        #expect(!CaptureCandidates.isRecordable(menubar, ownBundleIdentifier: nil))
    }

    @Test("drops windows owned by background agents and helpers")
    func dropsAgentApps() {
        let helper = window(2, "Teams WebView", app: "Microsoft Teams WebView", bundle: "com.microsoft.teams2.helper", regularApp: false)
        #expect(!CaptureCandidates.isRecordable(helper, ownBundleIdentifier: nil))
    }

    @Test("drops windows smaller than 160×100")
    func dropsSmallerThan160x100() {
        let narrow = window(3, "Tooltip", app: "Cursor", bundle: "com.todesktop.cursor", size: CaptureSize(width: 159, height: 100))
        let short = window(4, "Toolbar", app: "Cursor", bundle: "com.todesktop.cursor", size: CaptureSize(width: 160, height: 99))
        let exact = window(5, "Palette", app: "Cursor", bundle: "com.todesktop.cursor", size: CaptureSize(width: 160, height: 100))
        #expect(!CaptureCandidates.isRecordable(narrow, ownBundleIdentifier: nil))
        #expect(!CaptureCandidates.isRecordable(short, ownBundleIdentifier: nil))
        #expect(CaptureCandidates.isRecordable(exact, ownBundleIdentifier: nil))
    }

    @Test("drops untitled windows that are not on screen, keeps untitled on-screen ones")
    func dropsUntitledOffscreen() {
        let hiddenHelper = window(6, "", app: "Google Chrome", bundle: "com.google.Chrome", onScreen: false)
        let visibleUntitled = window(7, "  ", app: "Google Chrome", bundle: "com.google.Chrome", onScreen: true)
        let titledOtherDesktop = window(8, "Roadmap", app: "Notion", bundle: "notion.id", onScreen: false)
        #expect(!CaptureCandidates.isRecordable(hiddenHelper, ownBundleIdentifier: nil))
        #expect(CaptureCandidates.isRecordable(visibleUntitled, ownBundleIdentifier: nil))
        #expect(CaptureCandidates.isRecordable(titledOtherDesktop, ownBundleIdentifier: nil))
    }

    @Test("drops Wisp's own windows")
    func dropsOwnWindows() {
        let own = window(9, "Wisp", app: "Wisp", bundle: "tech.incerto.wisp.mac")
        #expect(!CaptureCandidates.isRecordable(own, ownBundleIdentifier: "tech.incerto.wisp.mac"))
        #expect(CaptureCandidates.isRecordable(own, ownBundleIdentifier: nil))
    }

    @Test("keeps windows whose size is unknown")
    func unknownSizeIsKept() {
        let unknown = window(10, "Doc", app: "Pages", bundle: "com.apple.iWork.Pages", size: nil)
        #expect(CaptureCandidates.isRecordable(unknown, ownBundleIdentifier: nil))
    }

    @Test("orders in-call meeting, other meeting windows, on-screen by z-order, then off-screen")
    func ordersInCallThenMeetingThenOnScreenByZThenOffscreen() {
        let notion = window(20, "Roadmap", app: "Notion", bundle: "notion.id", onScreen: false)
        let cursor = window(21, "main.swift", app: "Cursor", bundle: "com.todesktop.cursor", z: 1)
        let slack = window(22, "#product", app: "Slack", bundle: "com.tinyspeck.slackmacgap", z: 0)
        let workplace = window(23, "Zoom Workplace", app: "zoom.us", bundle: "us.zoom.xos", z: 3)
        let meeting = window(24, "Zoom Meeting", app: "zoom.us", bundle: "us.zoom.xos", z: 2)
        let ordered = CaptureCandidates.windows(
            from: [notion, cursor, slack, workplace, meeting],
            ownBundleIdentifier: nil
        )
        #expect(ordered.map(\.id) == [meeting.id, workplace.id, slack.id, cursor.id, notion.id])
    }

    @Test("windows(from:) excludes screens and screens(from:) keeps input order")
    func screensKeepInputOrder() {
        let main = display(1, "Built-in Retina Display")
        let external = display(2, "LG UltraFine")
        let doc = window(30, "Doc", app: "Pages", bundle: "com.apple.iWork.Pages")
        #expect(CaptureCandidates.screens(from: [main, doc, external]).map(\.id) == [main.id, external.id])
        #expect(CaptureCandidates.windows(from: [main, doc, external], ownBundleIdentifier: nil).map(\.id) == [doc.id])
    }

    @Test("a list shaped like the user's Mac (170 windows) keeps the 13 real ones")
    func fixtureLikeTheUsersMacKeeps13of170() {
        var sources: [CaptureSource] = []
        var next = 100
        func add(_ count: Int, _ make: (Int) -> CaptureSource) {
            for _ in 0..<count {
                sources.append(make(next))
                next += 1
            }
        }
        add(88) { window($0, "Item-0", app: "Control Center", bundle: "com.apple.controlcenter", normalLayer: false) }
        add(34) { window($0, "Popover", app: "Cursor", bundle: "com.todesktop.cursor", size: CaptureSize(width: 120, height: 40)) }
        add(30) { window($0, "Helper", app: "Teams WebView", bundle: "com.microsoft.teams2.helper", regularApp: false) }
        add(5) { window($0, "", app: "Google Chrome", bundle: "com.google.Chrome", onScreen: false) }
        add(4) { window($0, "On screen \($0)", app: "Ghostty", bundle: "com.mitchellh.ghostty", z: $0) }
        add(9) { window($0, "Elsewhere \($0)", app: "Obsidian", bundle: "md.obsidian", onScreen: false) }
        #expect(sources.count == 170)
        #expect(CaptureCandidates.windows(from: sources, ownBundleIdentifier: "tech.incerto.wisp.mac").count == 13)
    }
}
