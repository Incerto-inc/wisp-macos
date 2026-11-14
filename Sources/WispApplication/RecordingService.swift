import Foundation
import WispDomain

/// Deep application module: start/stop recording with one-at-a-time ownership.
public actor RecordingService {
    private let sources: CaptureSourceListing
    private let pipeline: CapturePipeline
    private let ambient: AmbientMicPipeline
    private let meetings: MeetingRepository
    private let files: MeetingFileStore
    private let ownBundleIdentifier: String?
    /// Rows still marked `.recording` that began before this moment were left by an earlier run.
    private let launchedAt = Date()
    private let tabs: BrowserTabReading?
    private let titles: WindowTitleReading?
    private let tabFollowInterval: Duration
    private let tabRecheckInterval: Duration
    /// A page whose title keeps changing must not make the follower read the browser constantly.
    private let tabTitleCheckSpacing: Duration

    private var phase: RecordingPhase = .idle
    /// Which pipeline owns the active session (nil when idle).
    private var activeMode: CaptureMode?
    /// What the video track records right now (nil when not recording a meeting).
    private var target: VideoTarget?
    /// Keeps the video on a recorded tab while it moves between windows or hides.
    private var follower: Task<Void, Never>?

    public init(
        sources: CaptureSourceListing,
        pipeline: CapturePipeline,
        ambient: AmbientMicPipeline,
        meetings: MeetingRepository,
        files: MeetingFileStore,
        ownBundleIdentifier: String? = nil,
        tabs: BrowserTabReading? = nil,
        titles: WindowTitleReading? = nil,
        // A window-title read costs ~0.03 ms; polling often keeps another tab's frames out.
        tabFollowInterval: Duration = .milliseconds(50),
        tabRecheckInterval: Duration = .seconds(10),
        tabTitleCheckSpacing: Duration = .seconds(1)
    ) {
        self.sources = sources
        self.pipeline = pipeline
        self.ambient = ambient
        self.meetings = meetings
        self.files = files
        self.ownBundleIdentifier = ownBundleIdentifier
        self.tabs = tabs
        self.titles = titles
        self.tabFollowInterval = tabFollowInterval
        self.tabRecheckInterval = tabRecheckInterval
        self.tabTitleCheckSpacing = tabTitleCheckSpacing
    }

    public func currentPhase() -> RecordingPhase { phase }

    public func currentMode() -> CaptureMode? { activeMode }

    /// Recordable windows (filtered and ordered), displays, and tabs of browsers Wisp may read.
    /// Browsers answer slowly (and a hung one only after a timeout), so callers that show a panel
    /// can list with `includingTabs: false` first and fill tabs in with a second call.
    public func listCaptureCandidates(includingTabs: Bool = true) async throws -> CaptureCandidateSet {
        let raw = try await sources.listShareableSources()
        let windows = CaptureCandidates.windows(from: raw, ownBundleIdentifier: ownBundleIdentifier)
        let screens = CaptureCandidates.screens(from: raw)
        guard includingTabs, let tabs else { return CaptureCandidateSet(windows: windows, screens: screens) }

        let browsers = await tabs.runningBrowsers()
        let snapshots = await Self.snapshots(of: browsers.filter { $0.access == .granted }, using: tabs)
        return CaptureCandidateSet(
            windows: windows,
            screens: screens,
            tabs: CaptureCandidates.tabs(from: BrowserTabs.sources(from: snapshots, windows: windows)),
            tabAccess: browsers
        )
    }

    /// Shows the macOS Automation prompt for one browser (once); returns the answer.
    public func requestTabAccess(bundleIdentifier: String) async -> BrowserTabAccess {
        await tabs?.requestAccess(bundleIdentifier: bundleIdentifier) ?? .denied
    }

    /// The window or display the video records right now, and whether frames are being written.
    public func videoTarget() -> VideoTarget? { target }

    /// Meeting mode: video follows `video`, `system.m4a` records `audio`.
    /// A tab records the window that holds it, only while the tab is the one shown.
    public func start(video: CaptureSourceID, audio: AudioSource, title: String) async throws -> MeetingID {
        guard RecordingLifecycle.canStart(from: phase) else {
            throw RecordingError.alreadyRecording
        }

        let id = MeetingID()
        phase = .starting(id)
        activeMode = .meeting

        let tabKey = BrowserTabKey(sourceID: video)
        var captured = video
        var startsLive = true
        if let tabKey {
            do {
                (captured, startsLive) = try await placeTab(tabKey)
            } catch {
                // Nothing was created yet: back to idle, no meeting row.
                phase = .idle
                activeMode = nil
                throw error
            }
        }

        do {
            let directory = try files.ensureDirectory(for: id, mode: .meeting)
            let meeting = Meeting(
                id: id,
                title: title,
                status: .recording,
                sourceLabel: title,
                mode: .meeting
            )
            try await meetings.insert(meeting)
            try await pipeline.start(meetingID: id, video: captured, audio: audio, directory: directory, startsLive: startsLive)
            target = VideoTarget(source: captured, isLive: startsLive)
            phase = .recording(id)
            if let tabKey { startFollowing(tabKey) }
            return id
        } catch {
            if var meeting = try? await meetings.fetch(id: id) {
                meeting.status = .failed
                meeting.endedAt = Date()
                try? await meetings.update(meeting)
            }
            phase = .failed(id, message: CaptureUserFacingError.message(for: error))
            activeMode = nil
            target = nil
            throw error
        }
    }

    // MARK: - Tabs

    /// Reads every granted browser at once; one that fails (quit mid-read, access revoked) is left out.
    private static func snapshots(of browsers: [BrowserTabStatus], using reader: BrowserTabReading) async -> [BrowserSnapshot] {
        await withTaskGroup(of: (Int, BrowserSnapshot?).self) { group in
            for (index, browser) in browsers.enumerated() {
                group.addTask { (index, try? await reader.snapshot(bundleIdentifier: browser.bundleIdentifier)) }
            }
            var results: [(Int, BrowserSnapshot)] = []
            for await (index, snapshot) in group {
                if let snapshot { results.append((index, snapshot)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func recordableWindows() async throws -> [CaptureSource] {
        CaptureCandidates.windows(from: try await sources.listShareableSources(), ownBundleIdentifier: ownBundleIdentifier)
    }

    /// Finds the tab's window and makes the tab the one it shows.
    /// Returns the window to record and whether the tab is showing in it.
    private func placeTab(_ key: BrowserTabKey) async throws -> (window: CaptureSourceID, showing: Bool) {
        guard let tabs else { throw RecordingError.tabUnavailable }
        let before = TabFollow.state(
            of: key,
            snapshot: try? await tabs.snapshot(bundleIdentifier: key.bundleIdentifier),
            windows: try await recordableWindows()
        )
        switch before {
        case .showing(let window):
            return (window, true)
        case .hidden(let window?):
            try? await tabs.show(key)
            // Window titles change when the tab comes forward, so match against a fresh list.
            let after = TabFollow.state(
                of: key,
                snapshot: try? await tabs.snapshot(bundleIdentifier: key.bundleIdentifier),
                windows: (try? await recordableWindows()) ?? []
            )
            if case .showing(let shown) = after { return (shown, true) }
            return (window, false)
        case .hidden(nil), .closed:
            throw RecordingError.tabUnavailable
        }
    }

    private func startFollowing(_ key: BrowserTabKey) {
        follower?.cancel()
        follower = Task { [weak self] in await self?.follow(key) }
    }

    /// Watches the recorded window's title (cheap) and looks at the browser's tabs when it changes,
    /// plus every `tabRecheckInterval` for changes a title does not reveal (a tab dragged elsewhere).
    private func follow(_ key: BrowserTabKey) async {
        var lastTitle: String?? = .none // unknown until the first check
        var lastCheck = ContinuousClock.now - tabRecheckInterval
        var unconfirmedChange = false
        while !Task.isCancelled {
            guard let current = target, case .recording = phase else { return }
            let title = await titles?.title(of: current.source)
            if let known = lastTitle, known != title {
                lastTitle = .some(title)
                unconfirmedChange = true
                if current.isLive {
                    // Another tab may be showing: stop writing frames now (cheap), confirm below.
                    await steer(to: VideoTarget(source: current.source, isLive: false))
                }
            }
            let sinceCheck = ContinuousClock.now - lastCheck
            let firstCheck = lastTitle == nil
            if firstCheck || (unconfirmedChange && sinceCheck >= tabTitleCheckSpacing) || sinceCheck >= tabRecheckInterval {
                lastCheck = .now
                unconfirmedChange = false
                let snapshot: BrowserSnapshot?
                do {
                    snapshot = try await tabs?.snapshot(bundleIdentifier: key.bundleIdentifier)
                } catch {
                    // A busy or slow browser is not a closed tab: keep the current state and ask
                    // again after the spacing. (A quit browser fails fast, without a script.)
                    guard !Task.isCancelled else { return }
                    unconfirmedChange = true
                    try? await Task.sleep(for: tabFollowInterval)
                    continue
                }
                guard !Task.isCancelled else { return }
                let windows = (try? await recordableWindows()) ?? []
                guard !Task.isCancelled else { return }
                let now = target ?? current
                switch TabFollow.state(of: key, snapshot: snapshot, windows: windows) {
                case .showing(let window):
                    await steer(to: VideoTarget(source: window, isLive: true))
                case .hidden(let window):
                    await steer(to: VideoTarget(source: window ?? now.source, isLive: false))
                case .closed:
                    await steer(to: VideoTarget(source: now.source, isLive: false))
                }
                lastTitle = .some(await titles?.title(of: target?.source ?? current.source))
            }
            try? await Task.sleep(for: tabFollowInterval)
        }
    }

    private func steer(to next: VideoTarget) async {
        guard next != target, case .recording = phase, !Task.isCancelled else { return }
        do {
            try await pipeline.updateVideo(target: next.source, live: next.isLive)
            if case .recording = phase { target = next }
        } catch {
            NSLog("[WispApplication] could not move video to %@: %@", next.source.raw, String(describing: error))
        }
    }

    private func stopFollowing() async {
        let running = follower
        follower = nil
        running?.cancel()
        await running?.value
    }

    /// Room (ambient): continuous mic capture, no screen source required.
    public func startRoom(title: String = "Room") async throws -> MeetingID {
        guard RecordingLifecycle.canStart(from: phase) else {
            throw RecordingError.alreadyRecording
        }

        let id = MeetingID()
        phase = .starting(id)
        activeMode = .room

        let stampedTitle: String = {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "Room" : trimmed
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return "\(base) · \(formatter.string(from: Date()))"
        }()

        do {
            let directory = try files.ensureDirectory(for: id, mode: .room)
            let meeting = Meeting(
                id: id,
                title: stampedTitle,
                status: .recording,
                sourceLabel: "Room mic",
                mode: .room
            )
            try await meetings.insert(meeting)
            try await ambient.start(meetingID: id, directory: directory)
            phase = .recording(id)
            return id
        } catch {
            if var meeting = try? await meetings.fetch(id: id) {
                meeting.status = .failed
                meeting.endedAt = Date()
                try? await meetings.update(meeting)
            }
            phase = .failed(id, message: CaptureUserFacingError.message(for: error))
            activeMode = nil
            throw error
        }
    }

    public func stop() async throws -> RecordingStopResult {
        guard case .recording(let id) = phase else {
            throw RecordingError.notRecording
        }
        let mode = activeMode ?? .meeting
        phase = .stopping(id)
        await stopFollowing()
        defer { target = nil }

        do {
            let counts: TrackByteCounts
            switch mode {
            case .meeting:
                counts = try await pipeline.stop()
            case .room:
                counts = try await ambient.stop()
            }
            let outcome = MeetingOutcome.fromCapturedBytes(
                mode: mode,
                video: counts.video,
                mic: counts.mic,
                system: counts.system
            )

            if var meeting = try await meetings.fetch(id: id) {
                meeting.status = outcome.status
                meeting.endedAt = Date()
                try await meetings.update(meeting)
            }

            phase = .idle
            activeMode = nil
            return RecordingStopResult(outcome: outcome, tracks: counts)
        } catch {
            let friendly = CaptureUserFacingError.message(for: error)
            if var meeting = try? await meetings.fetch(id: id) {
                meeting.status = .failed
                meeting.endedAt = Date()
                try? await meetings.update(meeting)
            }
            phase = .failed(id, message: friendly)
            activeMode = nil
            throw RecordingError.stopFailed(friendly)
        }
    }

    /// Clear a sticky `.failed` phase after the user dismisses the banner.
    public func acknowledgeFailure() {
        if case .failed = phase {
            phase = .idle
            activeMode = nil
        }
    }

    public func listRecentMeetings(limit: Int = 30) async throws -> [Meeting] {
        try await meetings.listRecent(limit: limit)
    }

    public func meetingDirectory(for id: MeetingID) throws -> URL {
        // Resolve by stored mode when possible; fall back to whichever path exists.
        // Callers that already fetched the meeting should prefer directory(for:mode:).
        let ambient = try files.directory(for: id, mode: .room)
        if FileManager.default.fileExists(atPath: ambient.path) {
            return ambient
        }
        return try files.directory(for: id, mode: .meeting)
    }

    public func meetingDirectory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        try files.directory(for: id, mode: mode)
    }

    public func deleteMeeting(id: MeetingID) async throws {
        try await meetings.delete(id: id)
        try files.removeMeetingDirectory(for: id)
    }

    public func renameMeeting(id: MeetingID, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var meeting = try await meetings.fetch(id: id) else { return }
        meeting.title = trimmed
        try await meetings.update(meeting)
    }

    /// Tracks that stopped while recording (shown in the panel, reported after Stop).
    public func captureHealth() async -> CaptureHealth {
        switch (phase, activeMode) {
        case (.recording, .meeting?): return await pipeline.health()
        case (.recording, .room?): return await ambient.health()
        default: return .ok
        }
    }

    public func currentLevels() async -> CaptureLevels {
        switch activeMode {
        case .room:
            return await ambient.currentLevels()
        case .meeting, .none:
            return await pipeline.currentLevels()
        }
    }

    /// Settle rows still marked `.recording` after a crash or force quit.
    @discardableResult
    public func reconcileInterruptedMeetings() async throws -> Int {
        let activeID: MeetingID? = {
            switch phase {
            case .starting(let id), .recording(let id), .stopping(let id), .failed(let id, _):
                return id
            case .idle:
                return nil
            }
        }()

        let recent = try await meetings.listRecent(limit: 100)
        var fixed = 0
        // Only rows from an earlier run: a start racing this check (its row inserted, its phase
        // not yet seen here) must not be settled as left over.
        for var meeting in recent where meeting.status == .recording && meeting.startedAt < launchedAt {
            if let activeID, meeting.id == activeID { continue }
            let dir = try files.directory(for: meeting.id, mode: meeting.mode)
            let counts = TrackByteCounts(
                video: Self.byteCount(dir.appendingPathComponent(TrackKind.video.fileName)),
                mic: Self.byteCount(dir.appendingPathComponent(TrackKind.mic.fileName)),
                system: Self.byteCount(dir.appendingPathComponent(TrackKind.system.fileName))
            )
            meeting.status = MeetingOutcome.statusAfterInterruption(
                video: counts.video,
                mic: counts.mic,
                system: counts.system
            )
            meeting.endedAt = meeting.endedAt ?? Date()
            try await meetings.update(meeting)
            fixed += 1
        }
        return fixed
    }

    private static func byteCount(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return 0 }
        return Int64(size)
    }
}

public enum RecordingError: Error, Sendable, Equatable, LocalizedError {
    case alreadyRecording
    case notRecording
    case stopFailed(String)
    /// The chosen tab was closed, or its window can no longer be found.
    case tabUnavailable

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "Nothing is recording right now."
        case .stopFailed(let message):
            return message
        case .tabUnavailable:
            return "That tab is no longer open. Pick another one."
        }
    }
}

/// Short panel copy for any error (never a `Domain=` dump). Adapters translate their own
/// framework errors into `LocalizedError`s; this only guards against raw text slipping through.
public enum CaptureUserFacingError {
    public static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription,
           !description.isEmpty, !looksLikeRawCocoaDump(description)
        {
            return description
        }
        let ns = error as NSError
        let text = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || looksLikeRawCocoaDump(text) || looksLikeRawCocoaDump(String(describing: error)) {
            return "Recording failed. Try again, or check Screen Recording and Microphone permissions."
        }
        return text
    }

    private static func looksLikeRawCocoaDump(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("domain=")
            || t.contains("userinfo=")
            || t.contains("scstreamerrordomain")
            || t.contains("nslocalizeddescription")
    }
}
