import Foundation
import Testing
import WispApplication
import WispDomain
@testable import WispUI

private struct Listing: CaptureSourceListing {
    func listShareableSources() async throws -> [CaptureSource] {
        [
            CaptureSource(id: CaptureSourceID("window:1"), kind: .window, title: "Zoom Meeting", applicationName: "zoom.us", bundleIdentifier: "us.zoom.xos", zOrder: 0),
            CaptureSource(id: CaptureSourceID("window:2"), kind: .window, title: "Notes", applicationName: "Notes", bundleIdentifier: "com.apple.Notes", zOrder: 1),
            CaptureSource(id: CaptureSourceID("screen:1"), kind: .screen, title: "Built-in Display"),
        ]
    }
}

private struct Pipeline: CapturePipeline {
    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {}
    func updateVideo(target: CaptureSourceID, live: Bool) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 1, mic: 1, system: 1) }
    func currentLevels() async -> CaptureLevels { .silent }
}

private struct Ambient: AmbientMicPipeline {
    func start(meetingID: MeetingID, directory: URL) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 0, mic: 1, system: 0) }
    func currentLevels() async -> CaptureLevels { .silent }
}

private actor Rows: MeetingRepository {
    var rows: [MeetingID: Meeting] = [:]
    func insert(_ meeting: Meeting) async throws { rows[meeting.id] = meeting }
    func update(_ meeting: Meeting) async throws { rows[meeting.id] = meeting }
    func fetch(id: MeetingID) async throws -> Meeting? { rows[id] }
    func listRecent(limit: Int) async throws -> [Meeting] { Array(rows.values.prefix(limit)) }
    func delete(id: MeetingID) async throws { rows[id] = nil }
}

private struct Folders: MeetingFileStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-key-tests-\(UUID().uuidString)")
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

private struct Granted: PermissionChecking {
    var screenGranted: Bool { true }
    var microphoneGranted: Bool { true }
}

@MainActor
private func readyModel() async -> PanelModel {
    let model = PanelModel(
        recording: RecordingService(sources: Listing(), pipeline: Pipeline(), ambient: Ambient(), meetings: Rows(), files: Folders()),
        thumbnails: nil,
        permissions: Granted(),
        mediaRoot: FileManager.default.temporaryDirectory,
        startsTicks: false
    )
    await model.bootstrap()
    return model
}

@MainActor
@Suite("Panel keyboard")
struct PanelKeyTests {
    @Test("Escape: cancels a rename first, then clears the search, then goes back, then hides the panel")
    func escapeOrder() async {
        let model = await readyModel()
        model.isRenaming = true
        #expect(model.handle(.escape, editingText: true) == .handled)
        #expect(!model.isRenaming)

        model.showPicker()
        model.search = "zoom"
        #expect(model.handle(.escape, editingText: true) == .handled)
        #expect(model.search.isEmpty)
        #expect(model.surface == .choosing)
        #expect(model.handle(.escape, editingText: false) == .handled)
        #expect(model.surface == .ready)
        #expect(model.handle(.escape, editingText: false) == .hidePanel)
    }

    @Test("arrows move the picker highlight; left and right leave a text field alone")
    func arrows() async {
        let model = await readyModel()
        model.showPicker()
        let first = model.pickerHighlightID
        #expect(model.handle(.right, editingText: true) == .passThrough)
        #expect(model.pickerHighlightID == first)
        #expect(model.handle(.right, editingText: false) == .handled)
        #expect(model.pickerHighlightID != first)
        #expect(model.handle(.down, editingText: true) == .handled)
    }

    @Test("Return chooses the highlighted source in the picker and does nothing elsewhere")
    func returnKey() async {
        let model = await readyModel()
        #expect(model.handle(.returnKey, editingText: false) == .passThrough)
        model.showPicker()
        _ = model.handle(.right, editingText: false)
        let highlighted = model.pickerHighlightID
        #expect(model.handle(.returnKey, editingText: false) == .handled)
        #expect(model.surface == .ready)
        #expect(model.selectedID == highlighted)
    }

    @Test("⌘F focuses search in the picker; ⌘. stops a recording")
    func commands() async {
        let model = await readyModel()
        #expect(model.handle(.command("f"), editingText: false) == .passThrough)
        model.showPicker()
        let request = model.searchFocusRequest
        #expect(model.handle(.command("f"), editingText: false) == .handled)
        #expect(model.searchFocusRequest == request + 1)
        model.back()

        await model.startRecording()
        #expect(model.surface == .recording)
        #expect(model.handle(.command("."), editingText: false) == .handled)
        for _ in 0..<100 where model.surface == .recording { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.surface == .ready)
    }
}
