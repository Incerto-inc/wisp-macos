import CoreGraphics
import Foundation
import WispDomain

/// Lists capturable windows/screens. Implemented by ScreenCaptureKit adapter.
public protocol CaptureSourceListing: Sendable {
    func listShareableSources() async throws -> [CaptureSource]
}

/// Small preview images for the picker and the live card. `nil` when the source
/// cannot be captured right now (closed, minimized, permission missing).
public protocol CaptureThumbnailProvider: Sendable {
    func thumbnail(for id: CaptureSourceID, maxPixelSize: Int) async -> CGImage?
}

/// Where a capture target sits on screen right now, in CoreGraphics global coordinates
/// (origin at the top-left of the main display). Drives the on-screen recording frame.
public struct CaptureTargetFrame: Sendable, Equatable {
    public var rect: CGRect
    public var isDisplay: Bool

    public init(rect: CGRect, isDisplay: Bool) {
        self.rect = rect
        self.isDisplay = isDisplay
    }
}

/// `nil` when the target is not visible (closed, minimized, on another desktop).
public protocol CaptureTargetLocating: Sendable {
    func frame(of id: CaptureSourceID) async -> CaptureTargetFrame?
}

/// Reads tabs through each browser's scripting interface. macOS asks the user once per browser
/// (Privacy & Security → Automation); nothing here may trigger that prompt except `requestAccess`.
public protocol BrowserTabReading: Sendable {
    /// Supported browsers that are running, with Wisp's access to each. Never prompts.
    func runningBrowsers() async -> [BrowserTabStatus]
    /// Shows the macOS prompt for one browser if it has not been answered yet; returns the result.
    func requestAccess(bundleIdentifier: String) async -> BrowserTabAccess
    /// Windows and tabs of one running browser whose access is granted. Must not launch the
    /// browser, and must give up promptly when the calling task is cancelled.
    func snapshot(bundleIdentifier: String) async throws -> BrowserSnapshot
    /// Makes the tab the one its window shows, without bringing the browser forward.
    func show(_ tab: BrowserTabKey) async throws
}

/// The current title of a window, cheap enough to poll several times a second.
/// `nil` when the window is gone. A change is the cue to look at a browser's tabs again.
public protocol WindowTitleReading: Sendable {
    func title(of id: CaptureSourceID) async -> String?
}

/// What the video track is recording right now.
public struct VideoTarget: Sendable, Equatable {
    /// The window or display being captured (for a tab: the window that holds it).
    public var source: CaptureSourceID
    /// False while frames are held (a recorded tab is hidden or closed).
    public var isLive: Bool

    public init(source: CaptureSourceID, isLive: Bool) {
        self.source = source
        self.isLive = isLive
    }
}

/// Live mic / system signal levels for the recording panel (0...1).
public struct CaptureLevels: Sendable, Equatable {
    public var mic: Float
    public var system: Float

    public init(mic: Float, system: Float) {
        self.mic = mic
        self.system = system
    }

    public static let silent = CaptureLevels(mic: 0, system: 0)
}

/// Tracks that stopped taking data while recording: a stream ended with an error (permission
/// revoked, display gone), a writer refused samples (disk full), the microphone went away.
/// Empty while everything runs.
public struct CaptureHealth: Sendable, Equatable {
    public var stoppedTracks: Set<TrackKind>

    public init(stoppedTracks: Set<TrackKind> = []) {
        self.stoppedTracks = stoppedTracks
    }

    public static let ok = CaptureHealth()
}

/// Owns the three-track capture pipeline for one meeting at a time.
public protocol CapturePipeline: Sendable {
    /// Video follows `video`; `system.m4a` records `audio`, whatever the video shows.
    /// With `startsLive == false` no frame is written until `updateVideo(live: true)`
    /// (a recorded tab that is not showing yet).
    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws
    /// Points the running video at another window or display, and pauses or resumes frames.
    /// While `live` is false the stream keeps running but writes nothing, so the video holds its
    /// last frame; timing and A/V alignment are unaffected.
    func updateVideo(target: CaptureSourceID, live: Bool) async throws
    func stop() async throws -> TrackByteCounts
    /// Best-effort RMS-style levels while capturing; zeros when idle.
    func currentLevels() async -> CaptureLevels
    /// Which tracks stopped while recording; `.ok` when idle.
    func health() async -> CaptureHealth
}

/// Mic-only ambient (Room) capture — no screen / system audio.
public protocol AmbientMicPipeline: Sendable {
    func start(meetingID: MeetingID, directory: URL) async throws
    func stop() async throws -> TrackByteCounts
    func currentLevels() async -> CaptureLevels
    func health() async -> CaptureHealth
}

/// Test doubles that never fail need not say so.
public extension CapturePipeline {
    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL) async throws {
        try await start(meetingID: meetingID, video: video, audio: audio, directory: directory, startsLive: true)
    }

    func health() async -> CaptureHealth { .ok }
}

public extension AmbientMicPipeline {
    func health() async -> CaptureHealth { .ok }
}

public struct TrackByteCounts: Sendable, Equatable {
    public var video: Int64
    public var mic: Int64
    public var system: Int64

    public init(video: Int64, mic: Int64, system: Int64) {
        self.video = video
        self.mic = mic
        self.system = system
    }
}

/// Stop payload so UI can warn when mic/system tracks are empty while video succeeded.
public struct RecordingStopResult: Sendable, Equatable {
    public var outcome: MeetingOutcome
    public var tracks: TrackByteCounts

    public init(outcome: MeetingOutcome, tracks: TrackByteCounts) {
        self.outcome = outcome
        self.tracks = tracks
    }
}

public protocol MeetingRepository: Sendable {
    func insert(_ meeting: Meeting) async throws
    func update(_ meeting: Meeting) async throws
    func fetch(id: MeetingID) async throws -> Meeting?
    func listRecent(limit: Int) async throws -> [Meeting]
    func delete(id: MeetingID) async throws
}

public protocol MeetingFileStore: Sendable {
    func meetingDirectory(for id: MeetingID) throws -> URL
    func ensureMeetingDirectory(for id: MeetingID) throws -> URL
    func removeMeetingDirectory(for id: MeetingID) throws
    /// Mode-aware path: Meeting → root/<uuid>; Room → root/ambient/<uuid>.
    func directory(for id: MeetingID, mode: CaptureMode) throws -> URL
    func ensureDirectory(for id: MeetingID, mode: CaptureMode) throws -> URL
}
