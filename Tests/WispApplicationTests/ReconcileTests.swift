import Foundation
import Testing
import WispApplication
import WispDomain

private actor Rows: MeetingRepository {
    var rows: [MeetingID: Meeting] = [:]
    func insert(_ meeting: Meeting) async throws { rows[meeting.id] = meeting }
    func update(_ meeting: Meeting) async throws { rows[meeting.id] = meeting }
    func fetch(id: MeetingID) async throws -> Meeting? { rows[id] }
    func listRecent(limit: Int) async throws -> [Meeting] { Array(rows.values.prefix(limit)) }
    func delete(id: MeetingID) async throws { rows[id] = nil }
}

private struct Folders: MeetingFileStore {
    let root: URL
    func meetingDirectory(for id: MeetingID) throws -> URL { try directory(for: id, mode: .meeting) }
    func ensureMeetingDirectory(for id: MeetingID) throws -> URL { try ensureDirectory(for: id, mode: .meeting) }
    func removeMeetingDirectory(for id: MeetingID) throws {}
    func directory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        root.appendingPathComponent(mode.subdirectoryName ?? "", isDirectory: true).appendingPathComponent(id.folderName)
    }
    func ensureDirectory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        let url = try directory(for: id, mode: mode)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct NoSources: CaptureSourceListing {
    func listShareableSources() async throws -> [CaptureSource] { [] }
}

private struct NoPipeline: CapturePipeline {
    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {}
    func updateVideo(target: CaptureSourceID, live: Bool) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 0, mic: 0, system: 0) }
    func currentLevels() async -> CaptureLevels { .silent }
}

private struct NoAmbient: AmbientMicPipeline {
    func start(meetingID: MeetingID, directory: URL) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 0, mic: 0, system: 0) }
    func currentLevels() async -> CaptureLevels { .silent }
}

@Suite("Recordings left behind by a crash")
struct ReconcileTests {
    @Test("a recording that never stopped is marked interrupted when it has data, failed when it has none")
    func marksInterrupted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = Rows()
        let folders = Folders(root: root)
        let withData = Meeting(title: "Crashed mid-call", status: .recording)
        let empty = Meeting(title: "Crashed at start", status: .recording)
        let room = Meeting(title: "Room", status: .recording, mode: .room)
        for meeting in [withData, empty, room] { try await rows.insert(meeting) }
        try Data([1]).write(to: try folders.ensureDirectory(for: withData.id, mode: .meeting).appendingPathComponent("video.mov"))
        _ = try folders.ensureDirectory(for: empty.id, mode: .meeting)
        try Data([1]).write(to: try folders.ensureDirectory(for: room.id, mode: .room).appendingPathComponent("mic.m4a"))

        let service = RecordingService(sources: NoSources(), pipeline: NoPipeline(), ambient: NoAmbient(), meetings: rows, files: folders)
        let fixed = try await service.reconcileInterruptedMeetings()

        #expect(fixed == 3)
        #expect(try await rows.fetch(id: withData.id)?.status == .interrupted)
        #expect(try await rows.fetch(id: empty.id)?.status == .failed)
        #expect(try await rows.fetch(id: room.id)?.status == .interrupted)
    }

    @Test("a recording that began after launch is never settled as left over")
    func ignoresRecordingsFromThisLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = Rows()
        let service = RecordingService(sources: NoSources(), pipeline: NoPipeline(), ambient: NoAmbient(), meetings: rows, files: Folders(root: root))
        // Inserted by a start that is still running (its phase not yet visible to this check).
        let starting = Meeting(title: "Just started", status: .recording, startedAt: Date().addingTimeInterval(1))
        try await rows.insert(starting)
        #expect(try await service.reconcileInterruptedMeetings() == 0)
        #expect(try await rows.fetch(id: starting.id)?.status == .recording)
    }
}
