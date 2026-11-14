import CoreGraphics
import Foundation
import Testing
@testable import WispUI
import WispApplication
import WispDomain

// MARK: - Fixtures

private let chrome = "com.google.Chrome"
private let safari = "com.apple.Safari"
private let chromeFrame = CaptureRect(x: 0, y: 25, width: 1200, height: 800)
private let safariFrame = CaptureRect(x: 300, y: 60, width: 1000, height: 700)

private let chromeWindowID = CaptureSourceID("window:10")
private let keynote = CaptureSource(
    id: CaptureSourceID("window:11"), kind: .window, title: "Q4 Roadmap.key",
    applicationName: "Keynote", bundleIdentifier: "com.apple.iWork.Keynote", zOrder: 1
)
private let notes = CaptureSource(
    id: CaptureSourceID("window:13"), kind: .window, title: "Shopping",
    applicationName: "Notes", bundleIdentifier: "com.apple.Notes", zOrder: 2
)
private let display = CaptureSource(id: CaptureSourceID("screen:1"), kind: .screen, title: "Built-in Retina Display")

private let docsTab = BrowserTabSnapshot(key: "7", title: "Roadmap – Docs", url: "https://docs.example.com/roadmap")
private let meetTab = BrowserTabSnapshot(key: "42", title: "Meet – abc-defg-hij", url: "https://meet.google.com/abc-defg-hij")
private let docsID = BrowserTabKey(bundleIdentifier: chrome, tabKey: "7").sourceID
private let meetID = BrowserTabKey(bundleIdentifier: chrome, tabKey: "42").sourceID
private let safariTabID = BrowserTabKey(bundleIdentifier: safari, tabKey: "s1").sourceID

private func chromeWindow(title: String) -> CaptureSource {
    CaptureSource(
        id: chromeWindowID, kind: .window, title: title, applicationName: "Google Chrome", bundleIdentifier: chrome,
        size: CaptureSize(width: chromeFrame.width, height: chromeFrame.height), zOrder: 0, frame: chromeFrame
    )
}

private let safariWindow = CaptureSource(
    id: CaptureSourceID("window:12"), kind: .window, title: "Wikipedia", applicationName: "Safari", bundleIdentifier: safari,
    size: CaptureSize(width: safariFrame.width, height: safariFrame.height), zOrder: 3, frame: safariFrame
)

private func chromeSnapshot(active: String) -> BrowserSnapshot {
    let title = active == meetTab.key ? meetTab.title : docsTab.title
    return BrowserSnapshot(bundleIdentifier: chrome, name: "Google Chrome", windows: [
        BrowserWindowSnapshot(key: "1", index: 1, title: title, bounds: chromeFrame, isPrivate: false, activeTabKey: active, tabs: [docsTab, meetTab]),
    ])
}

private let safariSnapshot = BrowserSnapshot(bundleIdentifier: safari, name: "Safari", windows: [
    BrowserWindowSnapshot(
        key: "s", index: 1, title: "Wikipedia", bounds: safariFrame, isPrivate: false, activeTabKey: "s1",
        tabs: [BrowserTabSnapshot(key: "s1", title: "Wikipedia", url: "https://en.wikipedia.org/")]
    ),
])

// MARK: - Fake world

/// Windows, browsers and tabs as the fakes report them. Browser reads can be held at a gate.
private actor TabWorld {
    var extraWindows: [CaptureSource] = [keynote]
    var chromeActive = docsTab.key
    var browsers: [BrowserTabStatus] = [
        BrowserTabStatus(bundleIdentifier: chrome, name: "Google Chrome", access: .granted),
        BrowserTabStatus(bundleIdentifier: safari, name: "Safari", access: .notDetermined),
    ]
    var safariGrantedOnRequest = true
    var accessRequests: [String] = []
    var started: CaptureSourceID?
    var gated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var sources: [CaptureSource] {
        let chromeTitle = chromeActive == meetTab.key ? meetTab.title : docsTab.title
        var all = [chromeWindow(title: chromeTitle)] + extraWindows
        if browsers.contains(where: { $0.bundleIdentifier == safari }) { all.append(safariWindow) }
        return all + [display]
    }

    func set(extraWindows: [CaptureSource]) { self.extraWindows = extraWindows }
    func set(chromeActive: String) { self.chromeActive = chromeActive }
    func set(browsers: [BrowserTabStatus]) { self.browsers = browsers }
    func set(gated: Bool) { self.gated = gated }
    func recordStart(_ id: CaptureSourceID) { started = id }

    func requestAccess(_ bundle: String) -> BrowserTabAccess {
        accessRequests.append(bundle)
        guard let index = browsers.firstIndex(where: { $0.bundleIdentifier == bundle }) else { return .denied }
        if browsers[index].access == .notDetermined {
            browsers[index].access = safariGrantedOnRequest ? .granted : .denied
        }
        return browsers[index].access
    }

    func snapshot(_ bundle: String) async throws -> BrowserSnapshot {
        if gated { await withCheckedContinuation { waiters.append($0) } }
        switch bundle {
        case chrome: return chromeSnapshot(active: chromeActive)
        case safari: return safariSnapshot
        default: throw CocoaError(.featureUnsupported)
        }
    }

    var waiting: Int { waiters.count }

    /// Lets the oldest held browser read finish.
    func releaseOldest() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func releaseAll() {
        gated = false
        let held = waiters
        waiters = []
        held.forEach { $0.resume() }
    }

    func title(of id: CaptureSourceID) -> String? {
        sources.first { $0.id == id }?.title
    }
}

private struct WorldListing: CaptureSourceListing {
    let world: TabWorld
    func listShareableSources() async throws -> [CaptureSource] { await world.sources }
}

private struct WorldTabs: BrowserTabReading {
    let world: TabWorld
    func runningBrowsers() async -> [BrowserTabStatus] { await world.browsers }
    func requestAccess(bundleIdentifier: String) async -> BrowserTabAccess { await world.requestAccess(bundleIdentifier) }
    func snapshot(bundleIdentifier: String) async throws -> BrowserSnapshot { try await world.snapshot(bundleIdentifier) }
    func show(_ tab: BrowserTabKey) async throws {
        if tab.bundleIdentifier == chrome { await world.set(chromeActive: tab.tabKey) }
    }
}

private struct WorldTitles: WindowTitleReading {
    let world: TabWorld
    func title(of id: CaptureSourceID) async -> String? { await world.title(of: id) }
}

private struct WorldPipeline: CapturePipeline {
    let world: TabWorld
    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {
        await world.recordStart(video)
    }
    func updateVideo(target: CaptureSourceID, live: Bool) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 10, mic: 10, system: 10) }
    func currentLevels() async -> CaptureLevels { CaptureLevels(mic: 0.3, system: 0.3) }
}

private struct NoAmbient: AmbientMicPipeline {
    func start(meetingID: MeetingID, directory: URL) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 0, mic: 10, system: 0) }
    func currentLevels() async -> CaptureLevels { .silent }
}

private actor Repo: MeetingRepository {
    var rows: [MeetingID: Meeting] = [:]
    func insert(_ meeting: Meeting) async throws { rows[meeting.id] = meeting }
    func update(_ meeting: Meeting) async throws { rows[meeting.id] = meeting }
    func fetch(id: MeetingID) async throws -> Meeting? { rows[id] }
    func listRecent(limit: Int) async throws -> [Meeting] { Array(rows.values.prefix(limit)) }
    func delete(id: MeetingID) async throws { rows[id] = nil }
}

private struct Files: MeetingFileStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-ui-tab-tests-\(UUID().uuidString)")
    func meetingDirectory(for id: MeetingID) throws -> URL { try directory(for: id, mode: .meeting) }
    func ensureMeetingDirectory(for id: MeetingID) throws -> URL { try ensureDirectory(for: id, mode: .meeting) }
    func removeMeetingDirectory(for id: MeetingID) throws {}
    func directory(for id: MeetingID, mode: CaptureMode) throws -> URL { root.appendingPathComponent(id.folderName) }
    func ensureDirectory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        let dir = try directory(for: id, mode: mode)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private struct Granted: PermissionChecking {
    var screenGranted: Bool { true }
    var microphoneGranted: Bool { true }
}

@MainActor
private final class OpenedURLs {
    var urls: [URL] = []
}

@MainActor
private final class TabHarness {
    let world: TabWorld
    let opened = OpenedURLs()
    let model: PanelModel

    init(world: TabWorld = TabWorld()) {
        self.world = world
        let service = RecordingService(
            sources: WorldListing(world: world),
            pipeline: WorldPipeline(world: world),
            ambient: NoAmbient(),
            meetings: Repo(),
            files: Files(),
            tabs: WorldTabs(world: world),
            titles: WorldTitles(world: world),
            tabFollowInterval: .milliseconds(5),
            tabRecheckInterval: .milliseconds(40)
        )
        let opened = opened
        model = PanelModel(
            recording: service,
            thumbnails: nil,
            permissions: Granted(),
            mediaRoot: FileManager.default.temporaryDirectory,
            startsTicks: false,
            openURL: { opened.urls.append($0) }
        )
    }
}

/// Polls `condition` until it holds or two seconds pass.
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

// MARK: - Tests

@MainActor
@Suite("PanelModel with browser tabs")
struct PanelModelTabTests {
    @Test("the Tabs segment sits between Windows and Screens only while a supported browser runs")
    func tabsSegmentFollowsRunningBrowsers() async {
        let h = TabHarness()
        await h.model.bootstrap()
        #expect(h.model.pickerTabs == [.windows, .tabs, .screens])

        h.model.showPicker()
        h.model.pickerTab = .tabs
        await h.world.set(browsers: [])
        await h.model.refreshCandidates()
        #expect(h.model.pickerTabs == [.windows, .screens])
        #expect(h.model.pickerTab == .windows)
    }

    @Test("browser access never gates the panel")
    func tabAccessNeverAsksForPermissions() async {
        let world = TabWorld()
        await world.set(browsers: [
            BrowserTabStatus(bundleIdentifier: chrome, name: "Google Chrome", access: .denied),
            BrowserTabStatus(bundleIdentifier: safari, name: "Safari", access: .notDetermined),
        ])
        let h = TabHarness(world: world)
        await h.model.bootstrap()
        #expect(h.model.surface == .ready)
        #expect(!h.model.needsPermissions)
        #expect(h.model.canStart)
        #expect(await world.accessRequests.isEmpty)
    }

    @Test("the picker shows tabs, and search finds them by title, host and browser name")
    func searchOverTabs() async {
        let h = TabHarness()
        await h.model.bootstrap()
        h.model.showPicker()
        h.model.pickerTab = .tabs
        #expect(h.model.pickerItems.map(\.id) == [meetID, docsID])

        h.model.search = "roadmap"
        #expect(h.model.pickerItems.map(\.id) == [docsID])
        h.model.search = "meet.google"
        #expect(h.model.pickerItems.map(\.id) == [meetID])
        h.model.search = "chrome"
        #expect(h.model.pickerItems.map(\.id) == [meetID, docsID])
        h.model.search = "wikipedia"
        #expect(h.model.pickerItems.isEmpty)

        h.model.pickerTab = .windows
        h.model.search = "keynote"
        #expect(h.model.pickerItems.map(\.id) == [keynote.id])
    }

    @Test("arrow keys move one row at a time in the Tabs list, and Return chooses")
    func keyboardInTabsList() async {
        let h = TabHarness()
        await h.model.bootstrap()
        h.model.showPicker()
        h.model.pickerTab = .tabs
        h.model.moveSelection(dx: 0, dy: 1)
        h.model.moveSelection(dx: 0, dy: 1)
        #expect(h.model.pickerHighlightID == docsID)
        h.model.moveSelection(dx: 0, dy: -1)
        #expect(h.model.pickerHighlightID == meetID)
        h.model.chooseSelected()
        #expect(h.model.surface == .ready)
        #expect(h.model.selectedID == meetID)
    }

    @Test("choosing a tab pins it like a window and records the window that holds it")
    func chooseTab() async throws {
        let world = TabWorld()
        await world.set(chromeActive: meetTab.key)
        let h = TabHarness(world: world)
        await h.model.bootstrap()
        h.model.showPicker()
        h.model.pickerTab = .tabs
        let docs = try #require(h.model.pickerItems.first { $0.id == docsID })
        h.model.choose(docs)
        #expect(h.model.surface == .ready)
        #expect(h.model.pinned?.id == docsID)
        #expect(h.model.selectedSource?.id == docsID)
        #expect(h.model.choices?.primary.id == docsID)
        #expect(h.model.choices?.secondary?.id == meetID)
        #expect(h.model.canStart)

        await h.model.startRecording()
        #expect(h.model.surface == .recording)
        #expect(await world.started == chromeWindowID)
        await h.model.stopRecording()
    }

    @Test("thumbnails are asked for by preview id; a hidden tab asks for none")
    func thumbnailsByPreviewID() async {
        let world = TabWorld()
        await world.set(chromeActive: meetTab.key)
        let h = TabHarness(world: world)
        await h.model.bootstrap()
        #expect(h.model.choices?.primary.id == meetID)
        #expect(h.model.thumbnailIDs() == [chromeWindowID, display.id])

        await world.set(chromeActive: docsTab.key)
        await h.model.refreshCandidates()
        #expect(h.model.choices?.primary.id == meetID)
        #expect(h.model.thumbnailIDs() == [display.id])

        h.model.showPicker()
        h.model.pickerTab = .tabs
        #expect(h.model.thumbnailIDs().isEmpty)
        h.model.pickerTab = .windows
        #expect(h.model.thumbnailIDs() == h.model.candidates.windows.map(\.id))
    }

    @Test("an in-call tab in the background is the first choice and records every app's sound")
    func backgroundInCallTabDrivesChoices() async {
        let h = TabHarness()
        await h.model.bootstrap()
        #expect(h.model.choices?.inCallMeeting?.id == meetID)
        #expect(h.model.choices?.primary.id == meetID)
        #expect(h.model.choices?.secondary?.id == display.id)
        #expect(h.model.selectedID == meetID)
        #expect(h.model.effectiveAudio == .allApplications)
    }

    @Test("a meeting tab that joins a call after a window was picked takes the first slot")
    func inCallTabReplacesPin() async {
        let world = TabWorld()
        await world.set(browsers: [BrowserTabStatus(bundleIdentifier: chrome, name: "Google Chrome", access: .denied)])
        let h = TabHarness(world: world)
        await h.model.bootstrap()
        h.model.choose(keynote)
        #expect(h.model.choices?.primary.id == keynote.id)

        await world.set(browsers: [BrowserTabStatus(bundleIdentifier: chrome, name: "Google Chrome", access: .granted)])
        await h.model.refreshCandidates()
        #expect(h.model.choices?.primary.id == meetID)
        #expect(h.model.selectedID == meetID)
    }

    @Test("asking for a browser's tabs goes to the browser, then lists its tabs")
    func requestTabAccessRefreshes() async {
        let h = TabHarness()
        await h.model.bootstrap()
        #expect(!h.model.candidates.tabs.contains { $0.id == safariTabID })

        await h.model.requestTabAccess(bundleIdentifier: safari)
        #expect(await h.world.accessRequests == [safari])
        #expect(h.model.candidates.tabs.contains { $0.id == safariTabID })
        #expect(h.model.candidates.tabAccess.first { $0.bundleIdentifier == safari }?.access == .granted)
        #expect(h.opened.urls.isEmpty)
    }

    @Test("a browser that was denied opens Automation settings instead of asking again")
    func deniedBrowserOpensSettings() async {
        let world = TabWorld()
        await world.set(browsers: [BrowserTabStatus(bundleIdentifier: safari, name: "Safari", access: .denied)])
        let h = TabHarness(world: world)
        await h.model.bootstrap()

        await h.model.requestTabAccess(bundleIdentifier: safari)
        #expect(await world.accessRequests.isEmpty)
        #expect(h.opened.urls == [URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!])
    }

    @Test("while recording a tab, the video target is published and goes not-live when the tab hides")
    func videoTargetPublishedWhileRecording() async {
        let world = TabWorld()
        await world.set(chromeActive: meetTab.key)
        let h = TabHarness(world: world)
        await h.model.bootstrap()
        await h.model.startRecording()
        #expect(h.model.recordingSource?.id == meetID)
        #expect(h.model.videoTarget == VideoTarget(source: chromeWindowID, isLive: true))
        #expect(h.model.recordingPreviewID == chromeWindowID)
        #expect(h.model.thumbnailIDs() == [chromeWindowID])

        await world.set(chromeActive: docsTab.key)
        let hidden = await eventually {
            await h.model.pollRecording()
            return h.model.videoTarget == VideoTarget(source: chromeWindowID, isLive: false)
        }
        #expect(hidden)
        #expect(h.model.recordingPreviewID == nil)
        #expect(h.model.thumbnailIDs().isEmpty)

        await h.model.stopRecording()
        #expect(h.model.videoTarget == nil)
    }

    @Test("windows show before a slow browser answers, then tabs fill in")
    func windowsBeforeTabs() async {
        let world = TabWorld()
        await world.set(gated: true)
        let h = TabHarness(world: world)
        let refresh = Task { await h.model.refreshCandidates() }

        #expect(await eventually { h.model.candidates.windows.map(\.id) == [chromeWindowID, keynote.id, safariWindow.id] })
        #expect(h.model.candidates.tabs.isEmpty)
        #expect(h.model.choices?.primary.id == display.id)

        await world.releaseAll()
        await refresh.value
        #expect(h.model.candidates.tabs.map(\.id) == [meetID, docsID])
        #expect(h.model.choices?.primary.id == meetID)
        #expect(h.model.selectedID == meetID)
    }

    @Test("a slow tab listing never overwrites a newer window list")
    func slowSecondStepNeverOverwritesNewerFirstStep() async {
        let world = TabWorld()
        await world.set(gated: true)
        let h = TabHarness(world: world)

        let older = Task { await h.model.refreshCandidates() }
        #expect(await eventually { await world.waiting == 1 })

        await world.set(extraWindows: [keynote, notes])
        let newer = Task { await h.model.refreshCandidates() }
        #expect(await eventually { h.model.candidates.windows.contains { $0.id == notes.id } })
        #expect(await eventually { await world.waiting == 2 })

        await world.releaseOldest()
        await older.value
        #expect(h.model.candidates.windows.contains { $0.id == notes.id })
        #expect(h.model.candidates.tabs.isEmpty)

        await world.releaseAll()
        await newer.value
        #expect(h.model.candidates.windows.contains { $0.id == notes.id })
        #expect(h.model.candidates.tabs.map(\.id) == [meetID, docsID])
    }
}
