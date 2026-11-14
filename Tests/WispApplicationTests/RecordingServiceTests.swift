import Foundation
import Testing
import WispApplication
import WispDomain

private struct FakeListing: CaptureSourceListing {
    var items: [CaptureSource] = [
        CaptureSource(
            id: CaptureSourceID("window:1"),
            kind: .window,
            title: "Zoom Meeting",
            applicationName: "zoom.us",
            bundleIdentifier: "us.zoom.xos"
        ),
    ]

    func listShareableSources() async throws -> [CaptureSource] { items }
}

private final class ControllablePipeline: CapturePipeline, @unchecked Sendable {
    var videoBytes: Int64 = 128
    var failStart: Bool = false
    var failStop: Bool = false
    var lastVideo: CaptureSourceID?
    var lastAudio: AudioSource?

    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {
        _ = (meetingID, directory)
        lastVideo = video
        lastAudio = audio
        if failStart {
            throw RecordingError.alreadyRecording
        }
    }

    func updateVideo(target: CaptureSourceID, live: Bool) async throws {}

    func stop() async throws -> TrackByteCounts {
        if failStop {
            throw RecordingError.notRecording
        }
        return TrackByteCounts(video: videoBytes, mic: 1, system: 1)
    }

    func currentLevels() async -> CaptureLevels { .silent }
}

private final class ControllableAmbient: AmbientMicPipeline, @unchecked Sendable {
    var micBytes: Int64 = 64
    var failStart: Bool = false
    var started = false

    func start(meetingID: MeetingID, directory: URL) async throws {
        _ = (meetingID, directory)
        if failStart {
            throw RecordingError.alreadyRecording
        }
        started = true
    }

    func stop() async throws -> TrackByteCounts {
        TrackByteCounts(video: 0, mic: micBytes, system: 0)
    }

    func currentLevels() async -> CaptureLevels {
        CaptureLevels(mic: started ? 0.4 : 0, system: 0)
    }
}

private struct TempFiles: MeetingFileStore {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func meetingDirectory(for id: MeetingID) throws -> URL {
        try directory(for: id, mode: .meeting)
    }

    func ensureMeetingDirectory(for id: MeetingID) throws -> URL {
        try ensureDirectory(for: id, mode: .meeting)
    }

    func directory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        var url = root
        if let sub = mode.subdirectoryName {
            url = url.appendingPathComponent(sub, isDirectory: true)
        }
        return url.appendingPathComponent(id.folderName, isDirectory: true)
    }

    func ensureDirectory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        let url = try directory(for: id, mode: mode)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func removeMeetingDirectory(for id: MeetingID) throws {
        for mode in CaptureMode.allCases {
            let url = try directory(for: id, mode: mode)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

@Suite("RecordingService")
struct RecordingServiceTests {
    @Test("start then stop yields completed when video bytes present")
    func startStopHappyPath() async throws {
        let files = try TempFiles()
        let repo = LocalMeetingRepo()
        let service = RecordingService(
            sources: FakeListing(),
            pipeline: ControllablePipeline(),
            ambient: ControllableAmbient(),
            meetings: repo,
            files: files
        )

        let id = try await service.start(video: CaptureSourceID("window:1"), audio: .allApplications, title: "Zoom Meeting")
        let result = try await service.stop()
        #expect(result.outcome == .completed)
        #expect(result.tracks.video == 128)
        let stored = try await repo.fetch(id: id)
        #expect(stored?.status == .completed)
        #expect(stored?.mode == .meeting)
    }

    @Test("failed start marks meeting failed and allows retry")
    func failedStartAllowsRetry() async throws {
        let files = try TempFiles()
        let repo = LocalMeetingRepo()
        let pipeline = ControllablePipeline()
        pipeline.failStart = true
        let service = RecordingService(
            sources: FakeListing(),
            pipeline: pipeline,
            ambient: ControllableAmbient(),
            meetings: repo,
            files: files
        )

        do {
            _ = try await service.start(video: CaptureSourceID("window:1"), audio: .allApplications, title: "Zoom Meeting")
            Issue.record("expected start to throw")
        } catch {
            // expected
        }

        let failedRows = try await repo.listRecent(limit: 5)
        #expect(failedRows.count == 1)
        #expect(failedRows.first?.status == .failed)

        pipeline.failStart = false
        let id = try await service.start(video: CaptureSourceID("window:1"), audio: .allApplications, title: "Zoom Meeting")
        let result = try await service.stop()
        #expect(result.outcome == .completed)
        let stored = try await repo.fetch(id: id)
        #expect(stored?.status == .completed)
    }

    @Test("failed stop marks meeting failed and allows retry")
    func failedStopAllowsRetry() async throws {
        let files = try TempFiles()
        let repo = LocalMeetingRepo()
        let pipeline = ControllablePipeline()
        pipeline.failStop = true
        let service = RecordingService(
            sources: FakeListing(),
            pipeline: pipeline,
            ambient: ControllableAmbient(),
            meetings: repo,
            files: files
        )

        let id = try await service.start(video: CaptureSourceID("window:1"), audio: .allApplications, title: "Zoom Meeting")
        do {
            _ = try await service.stop()
            Issue.record("expected stop to throw")
        } catch {
            // expected
        }

        let stored = try await repo.fetch(id: id)
        #expect(stored?.status == .failed)
        #expect(RecordingLifecycle.canStart(from: await service.currentPhase()))

        pipeline.failStop = false
        let id2 = try await service.start(video: CaptureSourceID("window:1"), audio: .allApplications, title: "Zoom Meeting")
        let result = try await service.stop()
        #expect(result.outcome == .completed)
        let stored2 = try await repo.fetch(id: id2)
        #expect(stored2?.status == .completed)
    }

    @Test("startRoom then stop completes on mic bytes and uses ambient path")
    func roomStartStopHappyPath() async throws {
        let files = try TempFiles()
        let repo = LocalMeetingRepo()
        let ambient = ControllableAmbient()
        ambient.micBytes = 99
        let service = RecordingService(
            sources: FakeListing(),
            pipeline: ControllablePipeline(),
            ambient: ambient,
            meetings: repo,
            files: files
        )

        let id = try await service.startRoom(title: "Room")
        #expect(await service.currentMode() == .room)
        let dir = try await service.meetingDirectory(for: id, mode: .room)
        #expect(dir.path.contains("/ambient/"))
        let result = try await service.stop()
        #expect(result.outcome == .completed)
        #expect(result.tracks.mic == 99)
        #expect(result.tracks.video == 0)
        let stored = try await repo.fetch(id: id)
        #expect(stored?.mode == .room)
        #expect(stored?.status == .completed)
        #expect(stored?.title.contains("Room") == true)
    }

    @Test("cannot start meeting while room is recording")
    func mutualExclusion() async throws {
        let files = try TempFiles()
        let repo = LocalMeetingRepo()
        let service = RecordingService(
            sources: FakeListing(),
            pipeline: ControllablePipeline(),
            ambient: ControllableAmbient(),
            meetings: repo,
            files: files
        )
        _ = try await service.startRoom()
        do {
            _ = try await service.start(video: CaptureSourceID("window:1"), audio: .allApplications, title: "Zoom")
            Issue.record("expected alreadyRecording")
        } catch let error as RecordingError {
            #expect(error == .alreadyRecording)
        }
        _ = try await service.stop()
    }

    @Test("acknowledgeFailure clears sticky failed phase")
    func acknowledgeFailureClearsPhase() async throws {
        let files = try TempFiles()
        let repo = LocalMeetingRepo()
        let pipeline = ControllablePipeline()
        pipeline.failStart = true
        let service = RecordingService(
            sources: FakeListing(),
            pipeline: pipeline,
            ambient: ControllableAmbient(),
            meetings: repo,
            files: files
        )
        do {
            _ = try await service.start(video: CaptureSourceID("window:1"), audio: .allApplications, title: "Zoom")
        } catch {
            // expected
        }
        if case .failed = await service.currentPhase() {
            // ok
        } else {
            Issue.record("expected failed phase")
        }
        await service.acknowledgeFailure()
        #expect(await service.currentPhase() == .idle)
    }
}


@Suite("RecordingService candidates and audio")
struct RecordingServiceCandidateTests {
    private func service(listing: FakeListing, pipeline: ControllablePipeline = ControllablePipeline(), own: String? = nil) throws -> RecordingService {
        RecordingService(
            sources: listing,
            pipeline: pipeline,
            ambient: ControllableAmbient(),
            meetings: LocalMeetingRepo(),
            files: try TempFiles(),
            ownBundleIdentifier: own
        )
    }

    @Test("start hands the chosen video and audio source to the pipeline")
    func startPassesAudioSourceToPipeline() async throws {
        let pipeline = ControllablePipeline()
        let recording = try service(listing: FakeListing(), pipeline: pipeline)
        let zoomAudio = AudioSource.application(bundleIdentifier: "us.zoom.xos", name: "zoom.us")
        _ = try await recording.start(video: CaptureSourceID("window:2"), audio: zoomAudio, title: "Q4 Roadmap.key")
        #expect(pipeline.lastVideo == CaptureSourceID("window:2"))
        #expect(pipeline.lastAudio == zoomAudio)
    }

    @Test("candidates drop menu-bar and helper windows and keep displays separately")
    func listCaptureCandidatesFiltersAndOrders() async throws {
        let listing = FakeListing(items: [
            CaptureSource(id: CaptureSourceID("window:10"), kind: .window, title: "Menubar", applicationName: "Window Server", bundleIdentifier: "com.apple.WindowServer", isNormalLayer: false),
            CaptureSource(id: CaptureSourceID("window:11"), kind: .window, title: "Helper", applicationName: "Teams WebView", bundleIdentifier: "com.microsoft.teams2.helper", ownerIsRegularApp: false),
            CaptureSource(id: CaptureSourceID("window:12"), kind: .window, title: "Zoom Meeting", applicationName: "zoom.us", bundleIdentifier: "us.zoom.xos"),
            CaptureSource(id: CaptureSourceID("screen:1"), kind: .screen, title: "Built-in Retina Display"),
        ])
        let set = try await service(listing: listing).listCaptureCandidates()
        #expect(set.windows.map(\.id) == [CaptureSourceID("window:12")])
        #expect(set.screens.map(\.id) == [CaptureSourceID("screen:1")])
    }

    @Test("candidates never include Wisp's own windows")
    func listCaptureCandidatesDropsOwnWindows() async throws {
        let listing = FakeListing(items: [
            CaptureSource(id: CaptureSourceID("window:20"), kind: .window, title: "Wisp", applicationName: "Wisp", bundleIdentifier: "tech.incerto.wisp.mac"),
        ])
        let set = try await service(listing: listing, own: "tech.incerto.wisp.mac").listCaptureCandidates()
        #expect(set.windows.isEmpty)
    }
}

@Suite("CaptureUserFacingError")
struct CaptureUserFacingErrorTests {
    @Test("an error's own description is used when it reads like a sentence")
    func usesLocalizedDescription() {
        #expect(CaptureUserFacingError.message(for: RecordingError.tabUnavailable) == "That tab is no longer open. Pick another one.")
    }

    @Test("raw Domain= dumps are replaced")
    func stripsCocoaDump() {
        let error = NSError(
            domain: "Fake",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3808 \"boom\" UserInfo={NSLocalizedDescription=boom}",
            ]
        )
        let message = CaptureUserFacingError.message(for: error)
        #expect(!message.contains("Domain="))
        #expect(!message.contains("UserInfo="))
    }
}

private actor LocalMeetingRepo: MeetingRepository {
    private var rows: [UUID: Meeting] = [:]

    func insert(_ meeting: Meeting) async throws { rows[meeting.id.raw] = meeting }
    func update(_ meeting: Meeting) async throws { rows[meeting.id.raw] = meeting }
    func fetch(id: MeetingID) async throws -> Meeting? { rows[id.raw] }
    func listRecent(limit: Int) async throws -> [Meeting] {
        Array(rows.values.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }
    func delete(id: MeetingID) async throws { rows[id.raw] = nil }
}
