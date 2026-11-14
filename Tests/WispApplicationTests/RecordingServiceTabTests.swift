import Foundation
import Testing
import WispApplication
import WispDomain

// MARK: - Fakes

private let chrome = "com.google.Chrome"

private func chromeWindow(_ id: Int, _ title: String, frame: CaptureRect, z: Int) -> CaptureSource {
    CaptureSource(
        id: CaptureSourceID("window:\(id)"),
        kind: .window,
        title: title,
        applicationName: "Google Chrome",
        bundleIdentifier: chrome,
        size: CaptureSize(width: frame.width, height: frame.height),
        zOrder: z,
        frame: frame
    )
}

private let mainFrame = CaptureRect(x: 0, y: 25, width: 1200, height: 800)
private let poppedFrame = CaptureRect(x: 200, y: 100, width: 800, height: 600)
private let meetKey = BrowserTabKey(bundleIdentifier: chrome, tabKey: "42")

private func meetSnapshot(active: String, meetInOwnWindow: Bool = false) -> BrowserSnapshot {
    let docs = BrowserTabSnapshot(key: "7", title: "Docs", url: "https://docs.example/")
    let meet = BrowserTabSnapshot(key: "42", title: "Meet – abc-defg-hij", url: "https://meet.google.com/abc-defg-hij")
    if meetInOwnWindow {
        return BrowserSnapshot(bundleIdentifier: chrome, name: "Google Chrome", windows: [
            BrowserWindowSnapshot(key: "1", index: 2, title: "Docs", bounds: mainFrame, isPrivate: false, activeTabKey: "7", tabs: [docs]),
            BrowserWindowSnapshot(key: "2", index: 1, title: meet.title, bounds: poppedFrame, isPrivate: false, activeTabKey: "42", tabs: [meet]),
        ])
    }
    let title = active == "42" ? meet.title : docs.title
    return BrowserSnapshot(bundleIdentifier: chrome, name: "Google Chrome", windows: [
        BrowserWindowSnapshot(key: "1", index: 1, title: title, bounds: mainFrame, isPrivate: false, activeTabKey: active, tabs: [docs, meet]),
    ])
}

private actor World {
    var sources: [CaptureSource] = [
        chromeWindow(10, "Docs", frame: mainFrame, z: 0),
        CaptureSource(id: CaptureSourceID("screen:1"), kind: .screen, title: "Display"),
    ]
    var browsers: [BrowserTabStatus] = [
        BrowserTabStatus(bundleIdentifier: chrome, name: "Google Chrome", access: .granted),
        BrowserTabStatus(bundleIdentifier: "com.apple.Safari", name: "Safari", access: .notDetermined),
    ]
    var snapshot: BrowserSnapshot? = meetSnapshot(active: "7")
    var titles: [CaptureSourceID: String] = [CaptureSourceID("window:10"): "Docs"]
    var shown: [BrowserTabKey] = []
    var started: CaptureSourceID?
    var startedLive: Bool?
    /// False: the browser ignores "show this tab" (the tab stays hidden).
    var showWorks = true
    func set(showWorks: Bool) { self.showWorks = showWorks }
    /// The next reads fail (a slow or busy browser), then reads work again.
    var failingReads = 0
    func set(failingReads: Int) { self.failingReads = failingReads }
    func takeFailure() -> Bool {
        guard failingReads > 0 else { return false }
        failingReads -= 1
        return true
    }
    var updates: [VideoTarget] = []
    var snapshotRequests: [String] = []
    var accessRequests: [String] = []

    func set(snapshot: BrowserSnapshot?) { self.snapshot = snapshot }
    func set(sources: [CaptureSource]) { self.sources = sources }
    func set(title: String?, for id: CaptureSourceID) { titles[id] = title }
    var stopped: Set<TrackKind> = []
    func set(stopped: Set<TrackKind>) { self.stopped = stopped }
    func recordShow(_ key: BrowserTabKey) {
        shown.append(key)
        guard showWorks else { return }
        // Showing the tab makes it the active one, as a real browser would.
        if var snap = snapshot, let index = snap.windows.firstIndex(where: { $0.tabs.contains { $0.key == key.tabKey } }) {
            snap.windows[index].activeTabKey = key.tabKey
            snap.windows[index].title = snap.windows[index].tabs.first { $0.key == key.tabKey }?.title ?? ""
            snapshot = snap
            titles[CaptureSourceID("window:10")] = snap.windows[index].title
        }
    }
    func recordStart(_ id: CaptureSourceID, live: Bool) {
        started = id
        startedLive = live
    }
    func recordUpdate(_ target: VideoTarget) { updates.append(target) }
    func recordSnapshotRequest(_ bundle: String) { snapshotRequests.append(bundle) }
    func recordAccessRequest(_ bundle: String) { accessRequests.append(bundle) }
}

private struct WorldListing: CaptureSourceListing {
    let world: World
    func listShareableSources() async throws -> [CaptureSource] { await world.sources }
}

private struct WorldTabs: BrowserTabReading {
    let world: World
    func runningBrowsers() async -> [BrowserTabStatus] { await world.browsers }
    func requestAccess(bundleIdentifier: String) async -> BrowserTabAccess {
        await world.recordAccessRequest(bundleIdentifier)
        return .granted
    }
    func snapshot(bundleIdentifier: String) async throws -> BrowserSnapshot {
        await world.recordSnapshotRequest(bundleIdentifier)
        if await world.takeFailure() { throw CocoaError(.userCancelled) }
        guard bundleIdentifier == chrome, let snapshot = await world.snapshot else {
            throw CocoaError(.featureUnsupported)
        }
        return snapshot
    }
    func show(_ tab: BrowserTabKey) async throws { await world.recordShow(tab) }
}

private struct WorldTitles: WindowTitleReading {
    let world: World
    func title(of id: CaptureSourceID) async -> String? { await world.titles[id] }
}

private struct WorldPipeline: CapturePipeline {
    let world: World
    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {
        await world.recordStart(video, live: startsLive)
    }
    func updateVideo(target: CaptureSourceID, live: Bool) async throws {
        await world.recordUpdate(VideoTarget(source: target, isLive: live))
    }
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 10, mic: 10, system: 10) }
    func currentLevels() async -> CaptureLevels { .silent }
    func health() async -> CaptureHealth { CaptureHealth(stoppedTracks: await world.stopped) }
}

private struct NoAmbient: AmbientMicPipeline {
    func start(meetingID: MeetingID, directory: URL) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 0, mic: 0, system: 0) }
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-tab-tests-\(UUID().uuidString)", isDirectory: true)
    func meetingDirectory(for id: MeetingID) throws -> URL { try directory(for: id, mode: .meeting) }
    func ensureMeetingDirectory(for id: MeetingID) throws -> URL { try ensureDirectory(for: id, mode: .meeting) }
    func removeMeetingDirectory(for id: MeetingID) throws {}
    func directory(for id: MeetingID, mode: CaptureMode) throws -> URL { root.appendingPathComponent(id.folderName) }
    func ensureDirectory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        let url = try directory(for: id, mode: mode)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func makeService(_ world: World, withTabs: Bool = true, spacing: Duration = .milliseconds(5)) -> RecordingService {
    RecordingService(
        sources: WorldListing(world: world),
        pipeline: WorldPipeline(world: world),
        ambient: NoAmbient(),
        meetings: Repo(),
        files: Files(),
        tabs: withTabs ? WorldTabs(world: world) : nil,
        titles: WorldTitles(world: world),
        tabFollowInterval: .milliseconds(5),
        tabRecheckInterval: .seconds(60),
        tabTitleCheckSpacing: spacing
    )
}

/// Polls `condition` until it holds or two seconds pass.
private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Tests

@Suite("RecordingService with browser tabs")
struct RecordingServiceTabTests {
    @Test("candidates include tabs from browsers Wisp may read, and every browser's access")
    func listsTabs() async throws {
        let world = World()
        let set = try await makeService(world).listCaptureCandidates()
        #expect(set.tabs.map(\.id) == [meetKey.sourceID, BrowserTabKey(bundleIdentifier: chrome, tabKey: "7").sourceID])
        #expect(set.tabs.first?.tab?.windowID == CaptureSourceID("window:10"))
        #expect(set.tabAccess.map(\.access) == [.granted, .notDetermined])
        #expect(await world.snapshotRequests == [chrome])
    }

    @Test("windows and screens can be listed without waiting for browsers")
    func listsWithoutTabs() async throws {
        let world = World()
        let set = try await makeService(world).listCaptureCandidates(includingTabs: false)
        #expect(set.tabs.isEmpty)
        #expect(set.tabAccess.isEmpty)
        #expect(set.windows.count == 1)
        #expect(await world.snapshotRequests.isEmpty)
    }

    @Test("without a tab reader there are no tabs")
    func noReader() async throws {
        let set = try await makeService(World(), withTabs: false).listCaptureCandidates()
        #expect(set.tabs.isEmpty)
        #expect(set.tabAccess.isEmpty)
    }

    @Test("asking for access goes to the reader")
    func requestAccess() async {
        let world = World()
        let access = await makeService(world).requestTabAccess(bundleIdentifier: "com.apple.Safari")
        #expect(access == .granted)
        #expect(await world.accessRequests == ["com.apple.Safari"])
    }

    @Test("recording a background tab brings it forward in its window and records that window")
    func startsOnHostWindow() async throws {
        let world = World()
        let service = makeService(world)
        _ = try await service.start(video: meetKey.sourceID, audio: .allApplications, title: "Meet")
        #expect(await world.shown == [meetKey])
        #expect(await world.started == CaptureSourceID("window:10"))
        #expect(await service.videoTarget() == VideoTarget(source: CaptureSourceID("window:10"), isLive: true))
        _ = try await service.stop()
    }

    @Test("switching to another tab holds the video; switching back resumes it")
    func holdsWhileHidden() async throws {
        let world = World()
        let service = makeService(world)
        _ = try await service.start(video: meetKey.sourceID, audio: .allApplications, title: "Meet")
        let host = CaptureSourceID("window:10")

        await world.set(snapshot: meetSnapshot(active: "7"))
        await world.set(title: "Docs", for: host)
        #expect(await eventually { await service.videoTarget() == VideoTarget(source: host, isLive: false) })
        #expect(await world.updates.last == VideoTarget(source: host, isLive: false))

        await world.set(snapshot: meetSnapshot(active: "42"))
        await world.set(title: "Meet – abc-defg-hij", for: host)
        #expect(await eventually { await service.videoTarget() == VideoTarget(source: host, isLive: true) })
        _ = try await service.stop()
    }

    @Test("a tab dragged into its own window is followed there")
    func followsMove() async throws {
        let world = World()
        let service = makeService(world)
        _ = try await service.start(video: meetKey.sourceID, audio: .allApplications, title: "Meet")

        await world.set(sources: [
            chromeWindow(10, "Docs", frame: mainFrame, z: 1),
            chromeWindow(11, "Meet – abc-defg-hij", frame: poppedFrame, z: 0),
        ])
        await world.set(snapshot: meetSnapshot(active: "7", meetInOwnWindow: true))
        await world.set(title: "Docs", for: CaptureSourceID("window:10"))
        #expect(await eventually {
            await service.videoTarget() == VideoTarget(source: CaptureSourceID("window:11"), isLive: true)
        })
        _ = try await service.stop()
    }

    @Test("after stop the video is no longer steered")
    func stopEndsFollowing() async throws {
        let world = World()
        let service = makeService(world)
        _ = try await service.start(video: meetKey.sourceID, audio: .allApplications, title: "Meet")
        _ = try await service.stop()
        let updatesAtStop = await world.updates.count
        await world.set(snapshot: meetSnapshot(active: "7"))
        await world.set(title: "Docs", for: CaptureSourceID("window:10"))
        try await Task.sleep(for: .milliseconds(60))
        #expect(await world.updates.count == updatesAtStop)
        #expect(await service.videoTarget() == nil)
    }

    @Test("a tab that is gone cannot be started, and no meeting row is left behind")
    func goneTab() async throws {
        let world = World()
        let service = makeService(world)
        await world.set(snapshot: BrowserSnapshot(bundleIdentifier: chrome, name: "Google Chrome", windows: []))
        await #expect(throws: RecordingError.tabUnavailable) {
            _ = try await service.start(video: meetKey.sourceID, audio: .allApplications, title: "Meet")
        }
        #expect(await service.currentPhase() == .idle)
        #expect(try await service.listRecentMeetings().isEmpty)
    }

    @Test("window recordings report their window as the live target")
    func windowTarget() async throws {
        let world = World()
        let service = makeService(world)
        _ = try await service.start(video: CaptureSourceID("window:10"), audio: .allApplications, title: "Docs")
        #expect(await service.videoTarget() == VideoTarget(source: CaptureSourceID("window:10"), isLive: true))
        #expect(await world.shown.isEmpty)
        _ = try await service.stop()
    }

    @Test("capture health comes from the pipeline while a meeting records, and is fine when idle")
    func health() async throws {
        let world = World()
        let service = makeService(world)
        #expect(await service.captureHealth() == .ok)
        _ = try await service.start(video: CaptureSourceID("window:10"), audio: .allApplications, title: "Docs")
        await world.set(stopped: [.system])
        #expect(await service.captureHealth() == CaptureHealth(stoppedTracks: [.system]))
        _ = try await service.stop()
        #expect(await service.captureHealth() == .ok)
    }

    @Test("a title that keeps changing holds frames at once but reads the browser at most once per spacing")
    func rateLimitsTitleChecks() async throws {
        let world = World()
        let service = makeService(world, spacing: .milliseconds(300))
        _ = try await service.start(video: meetKey.sourceID, audio: .allApplications, title: "Meet")
        let host = CaptureSourceID("window:10")
        try await Task.sleep(for: .milliseconds(50))
        let before = await world.snapshotRequests.count

        // Another tab comes forward and its title then ticks every few milliseconds.
        await world.set(snapshot: meetSnapshot(active: "7"))
        let began = ContinuousClock.now
        for tick in 0..<40 {
            await world.set(title: "(\(tick)) Inbox", for: host)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.videoTarget() == VideoTarget(source: host, isLive: false))
        let reads = await world.snapshotRequests.count - before
        // At most one read per 300 ms spacing, however slow the machine running the test is.
        let allowed = Int((ContinuousClock.now - began) / .milliseconds(300)) + 1
        #expect(reads >= 1)
        #expect(reads <= allowed)
        #expect(reads < 40)
        _ = try await service.stop()
    }

    @Test("a tab that cannot be brought forward is recorded with frames held from the first moment")
    func startsHeldWhenHidden() async throws {
        let world = World()
        await world.set(showWorks: false)
        let service = makeService(world)
        _ = try await service.start(video: meetKey.sourceID, audio: .allApplications, title: "Meet")
        #expect(await world.startedLive == false)
        #expect(await service.videoTarget() == VideoTarget(source: CaptureSourceID("window:10"), isLive: false))
        _ = try await service.stop()
    }

    @Test("a browser read that fails once does not count as the tab being closed")
    func toleratesFailedRead() async throws {
        let world = World()
        let service = makeService(world, spacing: .milliseconds(5))
        _ = try await service.start(video: meetKey.sourceID, audio: .allApplications, title: "Meet")
        let host = CaptureSourceID("window:10")
        try await Task.sleep(for: .milliseconds(30))
        #expect(await service.videoTarget() == VideoTarget(source: host, isLive: true))

        // The page retitles itself while the browser is too busy to answer once.
        await world.set(failingReads: 1)
        await world.set(title: "Meet – abc-defg-hij (1)", for: host)
        #expect(await eventually { await world.failingReads == 0 })
        #expect(await eventually { await service.videoTarget() == VideoTarget(source: host, isLive: true) })
        _ = try await service.stop()
    }
}
