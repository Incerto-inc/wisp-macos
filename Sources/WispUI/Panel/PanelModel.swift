import AppKit
import AVFoundation
import Foundation
import WispApplication
import WispDomain

/// Files of one recording, for playback in the detail state.
public struct RecordingFiles: Equatable {
    public var video: URL?
    public var mic: URL?
    public var system: URL?

    public init(video: URL?, mic: URL?, system: URL?) {
        self.video = video
        self.mic = mic
        self.system = system
    }
}

/// The menu-bar panel's state machine (spec §5.1). One panel, one surface at a time.
@MainActor
public final class PanelModel: ObservableObject {
    public enum Surface: Equatable {
        case permissions
        case ready
        case choosing
        case recording
        case detail(Meeting)
    }

    public enum PickerTab: Hashable {
        case windows
        case tabs
        case screens

        /// The kind of source the segment lists.
        public var kind: CaptureSourceKind {
            switch self {
            case .windows: return .window
            case .tabs: return .tab
            case .screens: return .screen
            }
        }
    }

    @Published public private(set) var surface: Surface = .ready
    @Published public private(set) var mode: CaptureMode = .meeting
    @Published public private(set) var candidates: CaptureCandidateSet = .empty
    @Published public private(set) var choices: RecordChoices?
    @Published public var selectedID: CaptureSourceID?
    @Published public private(set) var pinned: CaptureSource?
    @Published public var audioOverride: AudioSource?
    @Published public private(set) var meetings: [Meeting] = []
    @Published public private(set) var levels: CaptureLevels = .silent
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var recordingSource: CaptureSource?
    @Published public private(set) var recordingAudio: AudioSource?
    @Published public private(set) var recordingMode: CaptureMode?
    @Published public private(set) var inlineError: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var highlightedMeetingID: MeetingID?
    @Published public private(set) var isBusy = false
    @Published public private(set) var silentAudio = false
    /// Tracks that stopped while recording (a stream died, the disk filled, the mic went away).
    @Published public private(set) var stoppedTracks: Set<TrackKind> = []
    @Published public var search = ""
    @Published public var pickerTab: PickerTab = .windows
    @Published public private(set) var detailFiles: RecordingFiles?
    @Published public private(set) var screenGranted = false
    @Published public private(set) var micGranted = false
    @Published public private(set) var needsRelaunch = false
    /// Keyboard highlight inside the picker; only `choose` / `chooseSelected` commit it.
    @Published public private(set) var pickerHighlightID: CaptureSourceID?
    @Published public var isRenaming = false
    @Published public var confirmingDelete = false
    /// Bumped to ask the picker to focus its search field (⌘F).
    @Published public private(set) var searchFocusRequest = 0
    /// What the video records right now (for a tab: its window, and whether the tab is showing).
    /// `nil` when no meeting is recording.
    @Published public private(set) var videoTarget: VideoTarget?

    public let thumbnails: ThumbnailStore

    private let recording: RecordingService
    private let permissions: PermissionChecking
    private let mediaRoot: URL
    private let now: () -> Date
    private let startsTicks: Bool
    private let openURL: @MainActor (URL) -> Void
    /// Bumped by every candidate refresh; a result from an older refresh is dropped.
    private var refreshGeneration = 0
    private var tickTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var silentSince: Date?
    private var panelVisible = false
    /// The newest meter reading, kept while the panel is hidden.
    private var latestLevels: CaptureLevels = .silent
    /// The in-call meeting when the user pinned a window; a different call replaces the pin.
    private var pinnedAgainstCall: CaptureSourceID?

    public init(
        recording: RecordingService,
        thumbnails: CaptureThumbnailProvider?,
        permissions: PermissionChecking,
        mediaRoot: URL,
        now: @escaping () -> Date = Date.init,
        startsTicks: Bool = true,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.recording = recording
        self.thumbnails = ThumbnailStore(provider: thumbnails)
        self.permissions = permissions
        self.mediaRoot = mediaRoot
        self.now = now
        self.startsTicks = startsTicks
        self.openURL = openURL
    }

    // MARK: - Derived state

    public var isDetail: Bool {
        if case .detail = surface { return true }
        return false
    }

    public var needsPermissions: Bool {
        mode == .meeting ? !(screenGranted && micGranted) : !micGranted
    }

    /// `system.m4a` source: the user's override, else the in-call meeting app, else every app.
    public var effectiveAudio: AudioSource {
        audioOverride ?? AudioSourcePolicy.automatic(inCallMeeting: choices?.inCallMeeting)
    }

    public var allSources: [CaptureSource] { candidates.all }

    public var selectedSource: CaptureSource? {
        guard let selectedID else { return nil }
        return allSources.first { $0.id == selectedID }
    }

    /// Picker segments: Tabs only while a supported browser is running.
    public var pickerTabs: [PickerTab] {
        candidates.tabAccess.isEmpty ? [.windows, .screens] : [.windows, .tabs, .screens]
    }

    /// Whether the current segment has a search field (screens are too few to search).
    public var pickerSearches: Bool { pickerTab != .screens }

    /// Browsers whose tabs Wisp may not read yet, for the rows under the Tabs list.
    public var browsersWithoutTabAccess: [BrowserTabStatus] {
        candidates.tabAccess.filter { $0.access != .granted }
    }

    /// The image that stands for the recording right now: the recorded window while it is live,
    /// none while a recorded tab is hidden.
    public var recordingPreviewID: CaptureSourceID? {
        if let videoTarget { return videoTarget.isLive ? videoTarget.source : nil }
        return recordingSource?.previewID
    }

    public var canStart: Bool {
        guard !isBusy, surface == .ready else { return false }
        switch mode {
        case .room: return micGranted
        case .meeting: return screenGranted && micGranted && selectedSource != nil
        }
    }

    public var inputDeviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone"
    }

    // MARK: - Lifecycle

    /// Called when the panel opens: re-reads permissions, recordings and candidates.
    /// At launch (often at login): permissions, crash recovery and the recordings list only.
    /// Windows and browser tabs are listed when the panel opens (`bootstrap`), so starting
    /// the Mac does not send Apple Events to every running browser.
    public func startUp() async {
        refreshPermissions()
        settleSurface()
        _ = try? await recording.reconcileInterruptedMeetings()
        await refreshMeetings()
        settleSurface()
    }

    public func bootstrap() async {
        refreshPermissions()
        settleSurface()
        _ = try? await recording.reconcileInterruptedMeetings()
        await refreshMeetings()
        if mode == .meeting, screenGranted {
            await refreshCandidates()
        }
        settleSurface()
    }

    public func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible {
            if levels != latestLevels { levels = latestLevels }
            thumbnails.startLive { [weak self] in self?.thumbnailIDs() ?? [] }
        } else {
            thumbnails.stop()
            if case .detail = surface { closeDetail() }
            if surface == .choosing { surface = .ready }
        }
    }

    public func setMode(_ newMode: CaptureMode) async {
        guard surface != .recording, !isBusy, newMode != mode else { return }
        mode = newMode
        inlineError = nil
        notice = nil
        if newMode == .meeting, screenGranted, candidates == .empty {
            await refreshCandidates()
        }
        settleSurface()
    }

    /// Lists windows and screens first and shows them, then fills in browser tabs, which can take
    /// a while. A result from an older refresh never replaces a newer one.
    public func refreshCandidates() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let quick = try await recording.listCaptureCandidates(includingTabs: false)
            guard generation == refreshGeneration else { return }
            publish(quick.keepingTabs(from: candidates))
        } catch {
            guard generation == refreshGeneration else { return }
            candidates = .empty
            choices = nil
            selectedID = nil
            inlineError = Self.listingFailed
            return
        }
        // Windows are already on screen; if the browsers cannot be listed, keep what is shown.
        guard let full = try? await recording.listCaptureCandidates(includingTabs: true),
              generation == refreshGeneration
        else { return }
        publish(full)
    }

    /// Asks macOS for one browser's tabs (its Automation prompt, once), then lists again.
    /// A browser the user already refused can only be allowed in System Settings.
    public func requestTabAccess(bundleIdentifier: String) async {
        if candidates.tabAccess.first(where: { $0.bundleIdentifier == bundleIdentifier })?.access == .denied {
            openAutomationSettings()
            return
        }
        _ = await recording.requestTabAccess(bundleIdentifier: bundleIdentifier)
        await refreshCandidates()
    }

    // MARK: - Choosing

    public func select(_ id: CaptureSourceID) {
        selectedID = id
        inlineError = nil
    }

    public func showPicker() {
        guard surface == .ready, mode == .meeting else { return }
        search = ""
        pickerTab = selectedSource?.kind == .tab && pickerTabs.contains(.tabs) ? .tabs : .windows
        pickerHighlightID = selectedID
        surface = .choosing
    }

    public func back() {
        switch surface {
        case .choosing:
            pickerHighlightID = nil
            surface = .ready
        case .detail:
            closeDetail()
        default:
            break
        }
    }

    public func choose(_ source: CaptureSource) {
        let alreadyOffered = [choices?.primary.id, choices?.secondary?.id].contains(source.id)
        if !alreadyOffered {
            pinned = source
            pinnedAgainstCall = choices?.inCallMeeting?.id
            rebuildChoices(keepSelection: false)
        }
        selectedID = source.id
        pickerHighlightID = nil
        inlineError = nil
        surface = .ready
    }

    // MARK: - Keyboard

    public func focusSearch() {
        guard surface == .choosing else { return }
        if !pickerSearches { pickerTab = .windows }
        searchFocusRequest += 1
    }

    /// Arrow keys: left/right between the two cards (changes the selection);
    /// in the picker they only move the highlight, so browsing never changes what gets recorded.
    /// The grids have two columns; the Tabs list moves one row per up/down.
    public func moveSelection(dx: Int, dy: Int) {
        switch surface {
        case .ready where mode == .meeting:
            let ids = [choices?.primary.id, choices?.secondary?.id].compactMap { $0 }
            guard !ids.isEmpty else { return }
            let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
            selectedID = ids[min(ids.count - 1, max(0, current + dx + dy))]
        case .choosing:
            let ids = pickerItems.map(\.id)
            guard !ids.isEmpty else { return }
            let current = pickerHighlightID.flatMap { ids.firstIndex(of: $0) } ?? -1
            let step = pickerTab == .tabs ? dy : dx + dy * 2
            guard step != 0 else { return }
            pickerHighlightID = ids[min(ids.count - 1, max(0, current + step))]
        default:
            return
        }
    }

    /// Return in the picker: choose the highlighted tile, or the first match when it was filtered out.
    public func chooseSelected() {
        guard surface == .choosing else { return }
        let items = pickerItems
        guard let source = items.first(where: { $0.id == pickerHighlightID }) ?? items.first else { return }
        choose(source)
    }

    /// What the picker shows for the current segment and search — the one list the view,
    /// the keyboard and the thumbnails all use.
    public var pickerItems: [CaptureSource] {
        let items = candidates.sources(of: pickerTab.kind)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pickerSearches, !query.isEmpty else { return items }
        return items.filter { Self.matches($0, query) }
    }

    /// Title and app (browser) name; for tabs, the host as well.
    private static func matches(_ source: CaptureSource, _ query: String) -> Bool {
        var fields = [CaptureSourceLabel.title(source), CaptureSourceLabel.appName(source)]
        if let host = source.tab?.host { fields.append(host) }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Recording

    public func startRecording() async {
        guard canStart else { return }
        isBusy = true
        defer { isBusy = false }
        inlineError = nil
        notice = nil
        do {
            switch mode {
            case .room:
                _ = try await recording.startRoom(title: "Room")
                recordingSource = nil
                recordingAudio = nil
            case .meeting:
                guard let source = selectedSource else { return }
                let audio = effectiveAudio
                let title = CaptureSourceLabel.title(choices?.inCallMeeting ?? source)
                _ = try await recording.start(video: source.id, audio: audio, title: title)
                recordingSource = source
                recordingAudio = audio
                videoTarget = await recording.videoTarget()
            }
            recordingMode = mode
            recordingStartedAt = now()
            elapsed = 0
            silentSince = nil
            silentAudio = false
            surface = .recording
            if startsTicks { startTicks() }
            await refreshMeetings()
        } catch {
            inlineError = CaptureUserFacingError.message(for: error)
            surface = .ready
            await refreshCandidates()
            await refreshMeetings()
        }
    }

    public func stopRecording() async {
        guard surface == .recording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let mode = recordingMode ?? self.mode
        let audioName = recordingAudio?.displayName ?? "the meeting"
        stopTicks()
        do {
            let result = try await recording.stop()
            switch result.outcome {
            case .completed:
                if let stopped = stoppedTracksText {
                    notice = "\(stopped) during the recording."
                } else if mode == .meeting, result.tracks.video <= 0 {
                    notice = "No video was recorded. The sound was saved."
                } else if result.tracks.mic <= 0 {
                    notice = "The microphone track is empty. Check the Microphone permission."
                } else if mode == .meeting, result.tracks.system <= 0 {
                    notice = "No sound was recorded from \(audioName)."
                }
            case .failed(let reason):
                inlineError = reason
            }
        } catch {
            inlineError = CaptureUserFacingError.message(for: error)
        }
        clearStoppedTracks()
        recordingSource = nil
        recordingAudio = nil
        recordingMode = nil
        videoTarget = nil
        forgetPin()
        await refreshMeetings()
        highlight(meetings.first?.id)
        settleSurface(afterRecording: true)
        if mode == .meeting { await refreshCandidates() }
    }

    /// One round of the recording poll: meter levels and where the video is.
    func pollRecording() async {
        let levels = await recording.currentLevels()
        let target = await recording.videoTarget()
        let health = await recording.captureHealth()
        // A round that finishes after Stop must not bring old levels or a target back.
        guard !Task.isCancelled, surface == .recording else { return }
        ingest(levels: levels)
        if recordingMode == .meeting, target != videoTarget { videoTarget = target }
        if health.stoppedTracks != stoppedTracks { stoppedTracks = health.stoppedTracks }
    }

    /// "Screen capture stopped", "Screen capture, Microphone stopped"; nil while all tracks run.
    public var stoppedTracksText: String? {
        let names: [(TrackKind, String)] = [(.video, "Screen capture"), (.system, "System audio"), (.mic, "Microphone")]
        let stopped = names.filter { stoppedTracks.contains($0.0) }.map(\.1)
        guard !stopped.isEmpty else { return nil }
        return stopped.joined(separator: ", ") + " stopped"
    }

    /// Feeds one meter reading; raises `silentAudio` after 30 s without sound from the audio source.
    /// Readings arrive ten times a second. Publishing them redraws SwiftUI (and, for the elapsed
    /// time, the menu-bar item on every display), so the meters only go to a visible panel and the
    /// elapsed time only changes once a second — together most of Wisp's CPU while recording.
    func ingest(levels: CaptureLevels) {
        latestLevels = levels
        if panelVisible, levels != self.levels { self.levels = levels }
        let t = now()
        if let started = recordingStartedAt {
            let whole = (t.timeIntervalSince(started) + 0.000_001).rounded(.down)
            if whole != elapsed { elapsed = whole }
        }
        guard recordingMode == .meeting else {
            silentAudio = false
            return
        }
        if levels.system < 0.02 {
            let since = silentSince ?? t
            silentSince = since
            silentAudio = t.timeIntervalSince(since) >= 30
        } else {
            silentSince = nil
            silentAudio = false
        }
    }

    /// Called before the app quits: lets an in-flight start/stop settle (up to 5 s), then stops an
    /// active recording so its files are finished instead of left without an index.
    public func prepareForQuit() async {
        for _ in 0..<100 where isBusy {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if surface == .recording {
            await stopRecording()
        }
    }

    // MARK: - Recent / detail

    public func openDetail(_ meeting: Meeting) async {
        do {
            let dir = try await recording.meetingDirectory(for: meeting.id, mode: meeting.mode)
            func existing(_ kind: TrackKind) -> URL? {
                let url = dir.appendingPathComponent(kind.fileName)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return size > 0 ? url : nil
            }
            let files = RecordingFiles(video: existing(.video), mic: existing(.mic), system: existing(.system))
            guard files.video != nil || files.mic != nil else {
                inlineError = "This recording has no playable files. Show it in Finder to check."
                return
            }
            detailFiles = files
            surface = .detail(meeting)
        } catch {
            inlineError = CaptureUserFacingError.message(for: error)
        }
    }

    public func closeDetail() {
        detailFiles = nil
        isRenaming = false
        confirmingDelete = false
        if case .detail = surface { surface = .ready }
    }

    public func reveal(_ meeting: Meeting) async {
        guard let dir = try? await recording.meetingDirectory(for: meeting.id, mode: meeting.mode) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    public func delete(_ meeting: Meeting) async {
        do {
            try await recording.deleteMeeting(id: meeting.id)
            if case .detail(let shown) = surface, shown.id == meeting.id { closeDetail() }
            await refreshMeetings()
        } catch {
            inlineError = CaptureUserFacingError.message(for: error)
        }
    }

    public func rename(_ meeting: Meeting, to title: String) async {
        do {
            try await recording.renameMeeting(id: meeting.id, title: title)
            await refreshMeetings()
            if case .detail(let shown) = surface, shown.id == meeting.id,
               let updated = meetings.first(where: { $0.id == meeting.id })
            {
                surface = .detail(updated)
            }
        } catch {
            inlineError = CaptureUserFacingError.message(for: error)
        }
    }

    // MARK: - System hand-offs

    public func openRecordingsFolder() {
        NSWorkspace.shared.open(mediaRoot)
    }

    public func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            openURL(url)
        }
    }

    /// Privacy & Security › Automation, where a refused browser can be allowed again.
    public func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            openURL(url)
        }
    }

    public func openPrivacySettings() {
        WispPermissions.openScreenRecordingSettings()
    }

    public func openPermissionsGuide() {
        if let url = URL(string: "https://github.com/Incerto-inc/wisp-macos/blob/main/docs/permissions-howto.md") {
            openURL(url)
        }
    }

    public func requestScreenPermission() {
        let asked = UserDefaults.standard.bool(forKey: Self.askedScreenKey)
        if !asked {
            // First press: macOS shows its own prompt; opening Settings too would stack two dialogs.
            UserDefaults.standard.set(true, forKey: Self.askedScreenKey)
            _ = WispPermissions.requestScreenRecording()
        } else if !WispPermissions.requestScreenRecording() {
            WispPermissions.openScreenRecordingSettings()
        }
        // TCC applies screen-recording grants to a new process only.
        needsRelaunch = true
        refreshPermissions()
    }

    public func requestMicrophonePermission() async {
        if WispPermissions.microphoneStatus() == .unknown {
            _ = await WispPermissions.requestMicrophone()
        } else {
            WispPermissions.openMicrophoneSettings()
        }
        refreshPermissions()
        settleSurface()
    }

    public func relaunch() {
        WispPermissions.quitAndRelaunch()
    }

    // MARK: - Snapshot support

    /// Puts the model into a fixed state for offscreen rendering (snapshot tool only).
    public func applyPreview(_ state: PanelPreviewState) {
        stopTicks()
        mode = state.mode
        screenGranted = state.screenGranted
        micGranted = state.micGranted
        needsRelaunch = state.needsRelaunch
        candidates = state.candidates
        pinned = state.pinned
        rebuildChoices(keepSelection: false)
        if let selected = state.selectedID { selectedID = selected }
        meetings = state.meetings
        recordingSource = state.recordingSource
        recordingAudio = state.recordingAudio
        recordingMode = state.surface == .recording ? state.mode : nil
        videoTarget = state.videoTarget
        elapsed = state.elapsed
        levels = state.levels
        silentAudio = state.silentAudio
        stoppedTracks = state.stoppedTracks
        highlightedMeetingID = state.highlightedMeetingID
        search = state.search
        pickerTab = state.pickerTab
        detailFiles = state.detailFiles
        inlineError = state.inlineError
        notice = nil
        thumbnails.preset(state.thumbnails)
        surface = state.surface
    }

    // MARK: - Private

    private static let listingFailed = "Couldn't list windows. Check Screen & System Audio permission."
    private static let askedScreenKey = "wisp.askedScreenRecording"

    private func refreshPermissions() {
        screenGranted = permissions.screenGranted
        micGranted = permissions.microphoneGranted
        if screenGranted { needsRelaunch = false }
    }

    private func refreshMeetings() async {
        if let rows = try? await recording.listRecentMeetings() {
            meetings = rows
        }
    }

    /// A window picked through Other Window applies to one recording, or until another call starts.
    private func forgetPin() {
        pinned = nil
        pinnedAgainstCall = nil
        audioOverride = nil
        rebuildChoices(keepSelection: true)
    }

    /// Shows a candidate list: drops a pin whose source is gone, lets a new call replace a pin,
    /// and keeps the picker on a segment that still exists.
    private func publish(_ next: CaptureCandidateSet) {
        candidates = next
        if let pinned, !allSources.contains(where: { $0.id == pinned.id }) {
            self.pinned = nil
        }
        if pinned != nil, let inCall = candidates.inCallMeeting, inCall.id != pinnedAgainstCall {
            forgetPin()
        }
        if !pickerTabs.contains(pickerTab) { pickerTab = .windows }
        rebuildChoices(keepSelection: true)
        if inlineError == Self.listingFailed { inlineError = nil }
    }

    /// `keepSelection` keeps a card the user moved to; a selection still on the first card follows
    /// it, so a call found by a later refresh (tabs arrive second) becomes the selection.
    private func rebuildChoices(keepSelection: Bool) {
        let previousPrimary = choices?.primary.id
        choices = RecordChoices.make(candidates: candidates, pinned: pinned)
        let offered = [choices?.primary.id, choices?.secondary?.id].compactMap { $0 }
        let onFirstCard = selectedID == nil || selectedID == previousPrimary
        if !keepSelection || onFirstCard || !offered.contains(selectedID!) {
            selectedID = choices?.primary.id
        }
    }

    private func settleSurface(afterRecording: Bool = false) {
        if surface == .recording, !afterRecording { return }
        if needsPermissions {
            surface = .permissions
        } else if surface == .permissions || afterRecording {
            surface = .ready
        }
    }

    private func highlight(_ id: MeetingID?) {
        highlightedMeetingID = id
        guard id != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.highlightedMeetingID == id { self?.highlightedMeetingID = nil }
        }
    }

    func thumbnailIDs() -> [CaptureSourceID] {
        guard mode == .meeting else { return [] }
        switch surface {
        case .ready:
            return [choices?.primary.previewID, choices?.secondary?.previewID].compactMap { $0 }
        case .choosing:
            // The Tabs segment is a list without pictures.
            return pickerTab == .tabs ? [] : pickerItems.compactMap(\.previewID)
        case .recording:
            return [recordingPreviewID].compactMap { $0 }
        case .permissions, .detail:
            return []
        }
    }

    private func startTicks() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollRecording()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopTicks() {
        tickTask?.cancel()
        tickTask = nil
        recordingStartedAt = nil
        silentSince = nil
        silentAudio = false
        levels = .silent
        latestLevels = .silent
        elapsed = 0
    }

    /// After the stop notice has been chosen.
    private func clearStoppedTracks() {
        stoppedTracks = []
    }
}

/// A fixed panel state for the snapshot tool.
public struct PanelPreviewState {
    public var surface: PanelModel.Surface
    public var mode: CaptureMode = .meeting
    public var screenGranted = true
    public var micGranted = true
    public var needsRelaunch = false
    public var candidates: CaptureCandidateSet = .empty
    public var pinned: CaptureSource?
    public var selectedID: CaptureSourceID?
    public var meetings: [Meeting] = []
    public var recordingSource: CaptureSource?
    public var recordingAudio: AudioSource?
    public var videoTarget: VideoTarget?
    public var elapsed: TimeInterval = 0
    public var levels: CaptureLevels = .silent
    public var silentAudio = false
    public var stoppedTracks: Set<TrackKind> = []
    public var highlightedMeetingID: MeetingID?
    public var search = ""
    public var pickerTab: PanelModel.PickerTab = .windows
    public var detailFiles: RecordingFiles?
    public var inlineError: String?
    public var thumbnails: [CaptureSourceID: CGImage] = [:]

    public init(surface: PanelModel.Surface) {
        self.surface = surface
    }
}

extension CaptureCandidateSet {
    /// Every candidate the picker can offer.
    var all: [CaptureSource] { windows + tabs + screens }

    /// The candidates of one kind. Exhaustive, so a new kind has to be placed here.
    func sources(of kind: CaptureSourceKind) -> [CaptureSource] {
        switch kind {
        case .window: return windows
        case .tab: return tabs
        case .screen: return screens
        }
    }

    /// Fresh windows and screens with the tabs of an earlier list, until the browsers answer
    /// again. Tabs whose window is gone are left out.
    func keepingTabs(from earlier: CaptureCandidateSet) -> CaptureCandidateSet {
        let windowIDs = Set(windows.map(\.id))
        var next = self
        next.tabs = earlier.tabs.filter { $0.tab?.windowID.map(windowIDs.contains) ?? false }
        next.tabAccess = earlier.tabAccess
        return next
    }
}
