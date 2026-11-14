import CoreGraphics
import Combine
import Foundation
import Testing
@testable import WispUI
import WispApplication
import WispDomain

// MARK: - Fakes

private let zoomMeeting = CaptureSource(id: CaptureSourceID("window:1"), kind: .window, title: "Zoom Meeting", applicationName: "zoom.us", bundleIdentifier: "us.zoom.xos", zOrder: 1)
private let keynote = CaptureSource(id: CaptureSourceID("window:2"), kind: .window, title: "Q4 Roadmap.key", applicationName: "Keynote", bundleIdentifier: "com.apple.iWork.Keynote", zOrder: 0)
private let notion = CaptureSource(id: CaptureSourceID("window:3"), kind: .window, title: "Roadmap", applicationName: "Notion", bundleIdentifier: "notion.id", zOrder: 2)
private let mainDisplay = CaptureSource(id: CaptureSourceID("screen:1"), kind: .screen, title: "Built-in Retina Display")

private struct WindowGone: LocalizedError {
    var errorDescription: String? { "That window is no longer available. Pick another one." }
}

private final class FakeListing: CaptureSourceListing, @unchecked Sendable {
    var items: [CaptureSource] = [zoomMeeting, keynote, mainDisplay]
    var fails = false
    var calls = 0
    func listShareableSources() async throws -> [CaptureSource] {
        calls += 1
        if fails { throw WindowGone() }
        return items
    }
}

private final class FakePipeline: CapturePipeline, @unchecked Sendable {
    var lastVideo: CaptureSourceID?
    var lastAudio: AudioSource?
    var failStart = false
    var system: Float = 0.3
    var startCount = 0
    var stopped: Set<TrackKind> = []
    func health() async -> CaptureHealth { CaptureHealth(stoppedTracks: stopped) }
    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {
        if failStart { throw WindowGone() }
        startCount += 1
        lastVideo = video
        lastAudio = audio
    }
    func updateVideo(target: CaptureSourceID, live: Bool) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 10, mic: 10, system: 10) }
    func currentLevels() async -> CaptureLevels { CaptureLevels(mic: 0.3, system: system) }
}

private struct FakeAmbient: AmbientMicPipeline {
    func start(meetingID: MeetingID, directory: URL) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 0, mic: 10, system: 0) }
    func currentLevels() async -> CaptureLevels { .silent }
}

private actor FakeRepo: MeetingRepository {
    var rows: [MeetingID: Meeting] = [:]
    func insert(_ meeting: Meeting) async throws { rows[meeting.id] = meeting }
    func update(_ meeting: Meeting) async throws { rows[meeting.id] = meeting }
    func fetch(id: MeetingID) async throws -> Meeting? { rows[id] }
    func listRecent(limit: Int) async throws -> [Meeting] {
        Array(rows.values.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }
    func delete(id: MeetingID) async throws { rows[id] = nil }
}

private struct TempFiles: MeetingFileStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-ui-tests-\(UUID().uuidString)")
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

private struct FakePermissions: PermissionChecking {
    var screenGranted = true
    var microphoneGranted = true
}

@MainActor
private final class Harness {
    let listing = FakeListing()
    let pipeline = FakePipeline()
    let repo = FakeRepo()
    var now = Date(timeIntervalSince1970: 1_000_000)
    lazy var model = PanelModel(
        recording: RecordingService(sources: listing, pipeline: pipeline, ambient: FakeAmbient(), meetings: repo, files: TempFiles()),
        thumbnails: nil,
        permissions: permissions,
        mediaRoot: FileManager.default.temporaryDirectory,
        now: { [unowned self] in self.now },
        startsTicks: false
    )
    var permissions = FakePermissions()

    init(permissions: FakePermissions = FakePermissions()) {
        self.permissions = permissions
    }
}

// MARK: - Tests

@MainActor
@Suite("PanelModel")
struct PanelModelTests {
    @Test("missing screen permission shows the permissions surface in Meeting mode")
    func missingScreenPermissionShowsPermissions() async {
        let h = Harness(permissions: FakePermissions(screenGranted: false, microphoneGranted: true))
        await h.model.bootstrap()
        #expect(h.model.surface == .permissions)
    }

    @Test("Room mode needs only the microphone")
    func roomNeedsMicrophoneOnly() async {
        let h = Harness(permissions: FakePermissions(screenGranted: false, microphoneGranted: true))
        await h.model.bootstrap()
        await h.model.setMode(.room)
        #expect(h.model.surface == .ready)
        #expect(h.model.canStart)
    }

    @Test("with permissions, the in-call meeting is selected and the display is the alternative")
    func grantedShowsReadyWithInCallMeetingSelected() async {
        let h = Harness()
        await h.model.bootstrap()
        #expect(h.model.surface == .ready)
        #expect(h.model.selectedID == zoomMeeting.id)
        #expect(h.model.choices?.secondary?.id == mainDisplay.id)
        #expect(h.model.effectiveAudio == .application(bundleIdentifier: "us.zoom.xos", name: "zoom.us"))
    }

    @Test("choosing from the picker pins the window and returns to ready")
    func chooseFromPickerPinsAndReturnsToReady() async {
        let h = Harness()
        await h.model.bootstrap()
        h.model.showPicker()
        #expect(h.model.surface == .choosing)
        h.model.choose(keynote)
        #expect(h.model.surface == .ready)
        #expect(h.model.selectedID == keynote.id)
        #expect(h.model.choices?.primary.id == keynote.id)
        #expect(h.model.choices?.secondary?.id == zoomMeeting.id)
    }

    @Test("recording a non-meeting window still records the meeting app's audio")
    func startRecordsSelectedVideoWithMeetingAudio() async {
        let h = Harness()
        await h.model.bootstrap()
        h.model.choose(keynote)
        await h.model.startRecording()
        #expect(h.model.surface == .recording)
        #expect(h.pipeline.lastVideo == keynote.id)
        #expect(h.pipeline.lastAudio == .application(bundleIdentifier: "us.zoom.xos", name: "zoom.us"))
    }

    @Test("a failed start stays on ready with one inline sentence")
    func startFailureStaysReadyWithInlineError() async {
        let h = Harness()
        await h.model.bootstrap()
        h.pipeline.failStart = true
        await h.model.startRecording()
        #expect(h.model.surface == .ready)
        #expect(h.model.inlineError == "That window is no longer available. Pick another one.")
    }

    @Test("when listing fails there is nothing to start")
    func listingFailureDisablesStart() async {
        let h = Harness()
        h.listing.fails = true
        await h.model.bootstrap()
        #expect(h.model.choices == nil)
        #expect(!h.model.canStart)
        #expect(h.model.inlineError != nil)
    }

    @Test("a double Start creates one meeting")
    func doubleStartCreatesOneMeeting() async throws {
        let h = Harness()
        await h.model.bootstrap()
        async let first: Void = h.model.startRecording()
        async let second: Void = h.model.startRecording()
        _ = await (first, second)
        let rows = try await h.repo.listRecent(limit: 10)
        #expect(rows.count == 1)
        #expect(h.pipeline.startCount == 1)
        #expect(h.model.inlineError == nil)
        #expect(h.model.surface == .recording)
    }

    @Test("stop returns to ready and highlights the new recording")
    func stopReturnsToReadyAndHighlightsNewest() async throws {
        let h = Harness()
        await h.model.bootstrap()
        await h.model.startRecording()
        await h.model.stopRecording()
        let rows = try await h.repo.listRecent(limit: 10)
        #expect(h.model.surface == .ready)
        #expect(h.model.highlightedMeetingID == rows.first?.id)
    }

    @Test("a track that stops mid-recording is shown at once and reported again after Stop")
    func stoppedTrackShown() async {
        let h = Harness()
        await h.model.bootstrap()
        await h.model.startRecording()
        await h.model.pollRecording()
        #expect(h.model.stoppedTracks.isEmpty)

        h.pipeline.stopped = [.video]
        await h.model.pollRecording()
        #expect(h.model.stoppedTracks == [.video])
        #expect(h.model.stoppedTracksText == "Screen capture stopped")

        await h.model.stopRecording()
        #expect(h.model.notice == "Screen capture stopped during the recording.")
        #expect(h.model.stoppedTracks.isEmpty)
    }

    @Test("launching settles permissions and the recordings list without listing windows or browsers")
    func launchIsQuiet() async {
        let h = Harness()
        await h.model.startUp()
        #expect(h.listing.calls == 0)
        #expect(h.model.surface == .ready)
        await h.model.bootstrap()
        #expect(h.listing.calls > 0)
    }

    @Test("while recording, the elapsed time changes once a second and the meters only reach a visible panel")
    func quietUpdatesWhileHidden() async {
        let h = Harness()
        await h.model.bootstrap()
        await h.model.startRecording()
        h.model.setPanelVisible(false)

        var elapsedChanges = 0
        var levelChanges = 0
        let a = h.model.$elapsed.dropFirst().sink { _ in elapsedChanges += 1 }
        let b = h.model.$levels.dropFirst().sink { _ in levelChanges += 1 }
        for step in 1...20 {
            h.now += 0.1
            h.model.ingest(levels: CaptureLevels(mic: Float(step) / 40, system: 0.3))
        }
        #expect(elapsedChanges == 2)
        #expect(h.model.elapsed == 2)
        #expect(levelChanges == 0)

        h.model.setPanelVisible(true)
        #expect(h.model.levels == CaptureLevels(mic: 0.5, system: 0.3))
        h.now += 0.1
        h.model.ingest(levels: CaptureLevels(mic: 0.1, system: 0.3))
        #expect(h.model.levels == CaptureLevels(mic: 0.1, system: 0.3))
        _ = (a, b)
    }

    @Test("30 seconds without sound from the audio source raises the warning; sound clears it")
    func silentAudioWarningAfter30s() async {
        let h = Harness()
        await h.model.bootstrap()
        await h.model.startRecording()
        h.model.ingest(levels: CaptureLevels(mic: 0.3, system: 0))
        h.now += 29
        h.model.ingest(levels: CaptureLevels(mic: 0.3, system: 0))
        #expect(!h.model.silentAudio)
        h.now += 2
        h.model.ingest(levels: CaptureLevels(mic: 0.3, system: 0))
        #expect(h.model.silentAudio)
        h.model.ingest(levels: CaptureLevels(mic: 0.3, system: 0.2))
        #expect(!h.model.silentAudio)
    }

    @Test("quitting during a recording stops it first so the files are finished")
    func quitDuringRecordingStopsAndCompletesTheMeeting() async throws {
        let h = Harness()
        await h.model.bootstrap()
        await h.model.startRecording()
        await h.model.prepareForQuit()
        let rows = try await h.repo.listRecent(limit: 10)
        #expect(rows.first?.status == .completed)
        #expect(h.model.surface != .recording)
    }

    @Test("browsing the picker with the keyboard and going back keeps the selection")
    func browsingThePickerAndGoingBackKeepsTheSelection() async {
        let h = Harness()
        h.listing.items = [zoomMeeting, keynote, notion, mainDisplay]
        await h.model.bootstrap()
        h.model.showPicker()
        h.model.moveSelection(dx: 0, dy: 1)
        h.model.back()
        #expect(h.model.selectedID == zoomMeeting.id)
        await h.model.startRecording()
        #expect(h.pipeline.lastVideo == zoomMeeting.id)
    }

    @Test("Return in the picker chooses the first match when the highlight was filtered out")
    func returnChoosesFirstMatch() async {
        let h = Harness()
        h.listing.items = [zoomMeeting, keynote, notion, mainDisplay]
        await h.model.bootstrap()
        h.model.showPicker()
        h.model.search = "notion"
        h.model.chooseSelected()
        #expect(h.model.surface == .ready)
        #expect(h.model.selectedID == notion.id)
    }

    @Test("a window picked for one recording is forgotten afterwards")
    func pinnedWindowIsForgottenAfterRecording() async {
        let h = Harness()
        await h.model.bootstrap()
        h.model.choose(keynote)
        h.model.audioOverride = .allApplications
        await h.model.startRecording()
        await h.model.stopRecording()
        #expect(h.model.choices?.primary.id == zoomMeeting.id)
        #expect(h.model.selectedID == zoomMeeting.id)
        #expect(h.model.audioOverride == nil)
    }

    @Test("a call that starts after picking a window takes the first slot again")
    func newCallReplacesPinnedChoice() async {
        let h = Harness()
        h.listing.items = [keynote, notion, mainDisplay]
        await h.model.bootstrap()
        h.model.choose(notion)
        h.listing.items = [zoomMeeting, keynote, notion, mainDisplay]
        await h.model.refreshCandidates()
        #expect(h.model.choices?.primary.id == zoomMeeting.id)
        #expect(h.model.selectedID == zoomMeeting.id)
    }

    @Test("Room mode asks for no window thumbnails")
    func roomModeRequestsNoThumbnails() async {
        let h = Harness()
        await h.model.bootstrap()
        await h.model.setMode(.room)
        #expect(h.model.thumbnailIDs().isEmpty)
    }

    @Test("Back leaves the picker and the recording detail")
    func backFromChoosingAndDetail() async {
        let h = Harness()
        await h.model.bootstrap()
        h.model.showPicker()
        h.model.back()
        #expect(h.model.surface == .ready)
    }
}

@Suite("Ash & Ink contrast")
struct PaletteContrastTests {
    private func luminance(_ c: InkToken.RGB) -> Double {
        func f(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.red) + 0.7152 * f(c.green) + 0.0722 * f(c.blue)
    }

    private func contrast(_ a: InkToken, on b: InkToken, dark: Bool) -> Double {
        let (la, lb) = (luminance(a.rgb(dark: dark)), luminance(b.rgb(dark: dark)))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("body text is at least 7:1 and secondary text at least 4.5:1 on the panel", arguments: [true, false])
    func textContrast(dark: Bool) {
        #expect(contrast(.text, on: .panel, dark: dark) >= 7)
        #expect(contrast(.secondary, on: .panel, dark: dark) >= 4.5)
    }

    @Test("button text on vermillion is at least 4.5:1", arguments: [true, false])
    func buttonContrast(dark: Bool) {
        #expect(contrast(.onVermillion, on: .vermillionButton, dark: dark) >= 4.5)
    }
}
