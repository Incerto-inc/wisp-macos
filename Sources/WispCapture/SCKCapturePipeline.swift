import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import WispApplication
import WispDomain

/// ScreenCaptureKit + mic writers. Separate files under the meeting directory:
/// `video.mov`, `mic.m4a`, `system.m4a`.
///
/// Video and system audio come from two streams so the sound does not depend on what is shown:
/// the video stream follows the chosen window/display, the audio stream follows the chosen app
/// (or every app). ScreenCaptureKit filters audio per application, never per window.
public actor SCKCapturePipeline: CapturePipeline {
    private enum State {
        case idle
        case starting
        /// From a successful start until stop finishes (even if a stream already died).
        case running(ActiveSession, video: CaptureTargetID)
        case stopping
    }

    private var state: State = .idle
    /// The filter change in flight. `stop()` waits for it, so a retarget never touches a stream
    /// that is being torn down, and two retargets never overlap.
    private var retarget: Task<Void, Error>?

    public init() {}

    public func start(meetingID: MeetingID, video sourceID: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {
        guard case .idle = state else { throw CapturePipelineError.alreadyRunning }
        guard let target = CaptureTargetID(sourceID) else { throw CapturePipelineError.sourceNotFound(sourceID.raw) }
        state = .starting
        do {
            try await start(meetingID: meetingID, target: target, audio: audio, directory: directory, startsLive: startsLive)
        } catch {
            state = .idle
            throw CapturePipelineError.from(error)
        }
    }

    private func start(meetingID: MeetingID, target: CaptureTargetID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {
        let content = try await ScreenCaptureKitCalls.shareableContent().value
        let videoFilter = try Self.makeVideoFilter(target: target, content: content)
        let audioPlan = Self.makeAudioFilter(audio: audio, content: content)

        let videoURL = directory.appendingPathComponent(TrackKind.video.fileName)
        let micURL = directory.appendingPathComponent(TrackKind.mic.fileName)
        let systemURL = directory.appendingPathComponent(TrackKind.system.fileName)
        for url in [videoURL, micURL, systemURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let newSession = try ActiveSession(
            videoFilter: videoFilter,
            videoConfiguration: Self.makeVideoConfiguration(filter: videoFilter),
            audioFilter: audioPlan?.filter,
            audioConfiguration: Self.makeAudioConfiguration(),
            videoURL: videoURL,
            micURL: micURL,
            systemURL: systemURL
        )
        newSession.frames.set(open: startsLive)
        try await newSession.start()
        state = .running(newSession, video: target)
        NSLog(
            "[WispCapture] started meeting=%@ video=%@ audio=%@",
            meetingID.folderName,
            target.sourceID.raw,
            audioPlan?.label ?? "none"
        )
    }

    /// Same target: only opens or closes the frame gate. Another window or display: swaps the
    /// stream's filter (the writer keeps its size; SCK scales the new content to fit). A target
    /// that cannot be found throws `sourceNotFound` and leaves the current filter in place.
    public func updateVideo(target sourceID: CaptureSourceID, live: Bool) async throws {
        guard case .running(let session, let current) = state else { throw CapturePipelineError.notRunning }
        guard let target = CaptureTargetID(sourceID), target.isCapturable else {
            throw CapturePipelineError.sourceNotFound(sourceID.raw)
        }
        if !live, session.frames.isOpen {
            session.frames.set(open: false)
            // The switch to another tab is noticed a few frames late; end on a frame from before it.
            session.holdOnEarlierFrame()
        }
        if target != current {
            let previous = retarget
            let change = Task {
                _ = try? await previous?.value
                let content = try await ScreenCaptureKitCalls.shareableContent().value
                try await session.updateVideoFilter(Self.makeVideoFilter(target: target, content: content))
            }
            retarget = change
            do {
                try await change.value
            } catch {
                throw CapturePipelineError.from(error)
            }
            // Stopped (or restarted) while the filter changed: nothing left to update.
            guard case .running(let now, _) = state, now === session else { return }
            state = .running(session, video: target)
            NSLog("[WispCapture] video moved to %@", target.sourceID.raw)
        }
        session.frames.set(open: live)
    }

    public func stop() async throws -> TrackByteCounts {
        guard case .running(let current, _) = state else {
            // Idempotent: a second stop, or a stop after a failed start.
            throw CapturePipelineError.notRunning
        }
        // Claim the session first so a concurrent stop or retarget cannot touch the streams.
        state = .stopping
        defer { state = .idle }
        _ = try? await retarget?.value
        retarget = nil
        let counts = try await current.stop()
        NSLog("[WispCapture] stopped video=%lld mic=%lld system=%lld", counts.video, counts.mic, counts.system)
        return counts
    }

    public func currentLevels() async -> CaptureLevels {
        guard case .running(let session, _) = state else { return .silent }
        return session.levels()
    }

    public func health() async -> CaptureHealth {
        guard case .running(let session, _) = state else { return .ok }
        return session.health()
    }

    // MARK: - Filters

    private static func makeVideoFilter(target: CaptureTargetID, content: SCShareableContent) throws -> SCContentFilter {
        switch target {
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CapturePipelineError.sourceNotFound(target.sourceID.raw)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .screen(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CapturePipelineError.sourceNotFound(target.sourceID.raw)
            }
            // Keep Wisp's own panel out of screen recordings.
            return SCContentFilter(display: display, excludingApplications: ownApplications(in: content), exceptingWindows: [])
        case .tab:
            // RecordingService records a tab through its window; the pipeline never sees tab ids.
            throw CapturePipelineError.sourceNotFound(target.sourceID.raw)
        }
    }

    /// Audio-only filter: the chosen app, or every app except Wisp. A missing app falls back to every app.
    private static func makeAudioFilter(audio: AudioSource, content: SCShareableContent) -> (filter: SCContentFilter, label: String)? {
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            return nil
        }
        if case .application(let bundleIdentifier, _) = audio {
            if let app = content.applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                return (SCContentFilter(display: display, including: [app], exceptingWindows: []), bundleIdentifier)
            }
            NSLog("[WispCapture] audio app %@ not available — recording all apps instead", bundleIdentifier)
        }
        return (SCContentFilter(display: display, excludingApplications: ownApplications(in: content), exceptingWindows: []), "all apps")
    }

    private static func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        guard let own = Bundle.main.bundleIdentifier else { return [] }
        return content.applications.filter { $0.bundleIdentifier == own }
    }

    private static func makeVideoConfiguration(filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let width = max(Int(filter.contentRect.width), 640)
        let height = max(Int(filter.contentRect.height), 360)
        let maxEdge = 1920
        let scale = min(1.0, Double(maxEdge) / Double(max(width, height)))
        config.width = Int((Double(width) * scale).rounded(.down))
        config.height = Int((Double(height) * scale).rounded(.down))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 8
        config.showsCursor = true
        config.capturesAudio = false
        // The output size is fixed for the whole file; a recorded tab can move to a window of
        // another size, which is then scaled in without distortion.
        config.scalesToFit = true
        config.preservesAspectRatio = true
        if #available(macOS 14.2, *) {
            config.includeChildWindows = true
        }
        return config
    }

    private static func makeAudioConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // The audio stream still has to carry video; keep it tiny and slow.
        config.width = 64
        config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false
        return config
    }
}

public enum CapturePipelineError: Error, Sendable, Equatable, LocalizedError {
    case alreadyRunning
    case notRunning
    case sourceNotFound(String)
    case writerFailed(String)
    /// macOS refused screen capture (Screen Recording is off for Wisp).
    case screenRecordingDenied
    /// Any other ScreenCaptureKit failure.
    case screenCaptureFailed

    /// ScreenCaptureKit errors become this type, so no layer above this module needs to know
    /// ScreenCaptureKit's error domain or codes. Other errors pass through.
    public static func from(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" else { return error }
        switch ns.code {
        case -3801: return CapturePipelineError.screenRecordingDenied // userDeclined
        case -3815: return CapturePipelineError.sourceNotFound("noCaptureSource") // noCaptureSource
        default: return CapturePipelineError.screenCaptureFailed
        }
    }

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A recording is already in progress."
        case .notRunning:
            return "No active recording to stop."
        case .sourceNotFound:
            return "That window is no longer available. Pick another one."
        case .writerFailed(let reason):
            return "Could not finish writing the recording (\(reason))."
        case .screenRecordingDenied:
            return "Wisp is not allowed to record the screen. Turn it on in System Settings › Privacy & Security › Screen Recording."
        case .screenCaptureFailed:
            return "Screen capture failed. Pick the source again, or check Screen Recording permission."
        }
    }
}

/// SCStreamErrorDomain codes we treat as “already stopped” (idempotent stop).
enum SCStreamStopCode {
    /// Failed to stop a stream that is already stopped or does not exist.
    static let alreadyStopped = -3808
}

enum SCStreamStopError {
    static func isAlreadyStopped(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
           ns.code == SCStreamStopCode.alreadyStopped
        {
            return true
        }
        let text = ns.localizedDescription.lowercased()
        return text.contains("already stopped") || text.contains("does not exist")
    }
}

// MARK: - Session

private final class ActiveSession: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let videoFilter: SCContentFilter
    private let videoConfiguration: SCStreamConfiguration
    private let audioFilter: SCContentFilter?
    private let audioConfiguration: SCStreamConfiguration
    private let videoWriter: TrackWriter
    private let systemWriter: TrackWriter
    private let microphone: MicrophoneTrack
    private let videoOutput: VideoOutput
    private let audioOutput: AudioOutput
    /// Closed while a recorded tab is hidden: frames are dropped, the timeline runs on.
    let frames = FrameGate()
    /// Copies of recent frames, for `holdOnEarlierFrame`.
    let history = FrameHistory(spacing: 0.15, keep: 0.5)
    private let discardOutput = DiscardOutput()
    private let videoURL: URL
    private let micURL: URL
    private let systemURL: URL
    private let videoQueue = DispatchQueue(label: "tech.incerto.wisp.capture.video")
    private let audioQueue = DispatchQueue(label: "tech.incerto.wisp.capture.audio")
    /// Guards `running` against `didStopWithError` (sync helpers — never called under `await`).
    private let stateQueue = DispatchQueue(label: "tech.incerto.wisp.capture.stream-state")
    /// Set and cleared only by the task that starts/stops the session.
    private var videoStream: SCStream?
    private var audioStream: SCStream?
    private var running: Set<ObjectIdentifier> = []
    /// Tracks whose stream ended with an error while recording.
    private var streamFailures: Set<TrackKind> = []

    init(
        videoFilter: SCContentFilter,
        videoConfiguration: SCStreamConfiguration,
        audioFilter: SCContentFilter?,
        audioConfiguration: SCStreamConfiguration,
        videoURL: URL,
        micURL: URL,
        systemURL: URL
    ) throws {
        self.videoFilter = videoFilter
        self.videoConfiguration = videoConfiguration
        self.audioFilter = audioFilter
        self.audioConfiguration = audioConfiguration
        self.videoURL = videoURL
        self.micURL = micURL
        self.systemURL = systemURL
        let videoWriter = try TrackWriter(
            url: videoURL,
            fileType: .mov,
            videoWidth: videoConfiguration.width,
            videoHeight: videoConfiguration.height
        )
        let systemWriter = try TrackWriter(url: systemURL, fileType: .m4a, audioOnly: true)
        self.videoWriter = videoWriter
        self.systemWriter = systemWriter
        self.videoOutput = VideoOutput(writer: videoWriter, gate: frames, history: history)
        self.audioOutput = AudioOutput(writer: systemWriter)
        self.microphone = try MicrophoneTrack(url: micURL, channels: 1, bitRate: 96_000)
        super.init()
    }

    /// Every track shares one time zero — the moment capture starts — so video.mov,
    /// system.m4a and mic.m4a line up when played (or transcribed) together.
    func start() async throws {
        let anchor = CMClockGetTime(CMClockGetHostTimeClock())
        videoWriter.anchor(at: anchor)
        systemWriter.anchor(at: anchor)
        do {
            try microphone.start(anchor: anchor)
        } catch {
            NSLog("[WispCapture] microphone failed to start — continuing without it: %@", error.localizedDescription)
        }

        let video = SCStream(filter: videoFilter, configuration: videoConfiguration, delegate: self)
        do {
            try video.addStreamOutput(videoOutput, type: .screen, sampleHandlerQueue: videoQueue)
            videoStream = video
            try await video.startCapture()
            markRunning(video, true)
        } catch {
            videoStream = nil
            await microphone.cancel()
            throw error
        }

        // System audio is best-effort: a failed audio stream must not lose the video or mic.
        if let audioFilter {
            let audio = SCStream(filter: audioFilter, configuration: audioConfiguration, delegate: self)
            do {
                try audio.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: audioQueue)
                try audio.addStreamOutput(discardOutput, type: .screen, sampleHandlerQueue: audioQueue)
                audioStream = audio
                try await audio.startCapture()
                markRunning(audio, true)
            } catch {
                audioStream = nil
                NSLog("[WispCapture] audio stream failed to start (continuing without system audio): %@", error.localizedDescription)
            }
        }
        NSLog("[WispCapture] mic + video stream + audio stream running")
    }

    /// Writes a copy of a frame from before the switch that closed the gate, so the held picture
    /// is the recorded tab and not the tab that briefly replaced it.
    func holdOnEarlierFrame() {
        let now = CMTimeGetSeconds(CMClockGetHostTimeClock().time)
        guard let earlier = history.frame(atOrBefore: now - Self.switchDetectionMargin) else { return }
        videoWriter.appendHeldFrame(earlier, at: CMClockGetHostTimeClock().time)
        history.forget()
    }

    /// How long another tab's frames can reach the writer before the switch is noticed
    /// (title poll every 50 ms, plus frame and window-server latency), with room to spare.
    static let switchDetectionMargin = 0.25

    /// Points the running video stream at another window or display.
    func updateVideoFilter(_ filter: SCContentFilter) async throws {
        guard let videoStream else { throw CapturePipelineError.notRunning }
        try await videoStream.updateContentFilter(filter)
    }

    func stop() async throws -> TrackByteCounts {
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        await stopStream(videoStream, outputs: [(videoOutput, .screen)])
        await stopStream(audioStream, outputs: [(audioOutput, .audio), (discardOutput, .screen)])
        microphone.stopCapturing()
        // Finish every file even if one fails, so none is left without its index.
        var videoError: Error?
        do {
            try await videoWriter.finish(endingAt: end)
        } catch {
            videoError = error
        }
        // Mic and system audio are best-effort: an empty track warns, it does not fail the meeting.
        do {
            try await microphone.finish(endingAt: end)
        } catch {
            NSLog("[WispCapture] mic writer finish failed (continuing): %@", error.localizedDescription)
        }
        do {
            try await systemWriter.finish(endingAt: end)
        } catch {
            NSLog("[WispCapture] system writer finish failed (continuing): %@", error.localizedDescription)
        }
        if let videoError { throw videoError }
        return TrackByteCounts(
            video: Self.byteCount(videoURL),
            mic: Self.byteCount(micURL),
            system: Self.byteCount(systemURL)
        )
    }

    private func stopStream(_ stream: SCStream?, outputs: [(any SCStreamOutput, SCStreamOutputType)]) async {
        guard let stream else { return }
        if claimStop(stream) {
            do {
                try await stream.stopCapture()
            } catch {
                if SCStreamStopError.isAlreadyStopped(error) {
                    NSLog("[WispCapture] stopCapture ignored — stream already stopped (-3808)")
                } else {
                    NSLog("[WispCapture] stopCapture error (continuing teardown): %@", error.localizedDescription)
                }
            }
        }
        for (output, type) in outputs {
            try? stream.removeStreamOutput(output, type: type)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        markRunning(stream, false)
        let track: TrackKind = stream === videoStream ? .video : .system
        stateQueue.sync { _ = streamFailures.insert(track) }
        NSLog("[WispCapture] stream stopped with error: %@", error.localizedDescription)
    }

    private func markRunning(_ stream: SCStream, _ isRunning: Bool) {
        stateQueue.sync {
            if isRunning {
                running.insert(ObjectIdentifier(stream))
            } else {
                running.remove(ObjectIdentifier(stream))
            }
        }
    }

    /// True once per stream while it is still running (the caller then calls stopCapture).
    private func claimStop(_ stream: SCStream) -> Bool {
        stateQueue.sync { running.remove(ObjectIdentifier(stream)) != nil }
    }

    func health() -> CaptureHealth {
        var stopped = stateQueue.sync { streamFailures }
        if videoWriter.hasFailed { stopped.insert(.video) }
        if systemWriter.hasFailed { stopped.insert(.system) }
        if !microphone.isHealthy { stopped.insert(.mic) }
        return CaptureHealth(stoppedTracks: stopped)
    }

    func levels() -> CaptureLevels {
        CaptureLevels(mic: microphone.level, system: audioOutput.level)
    }

    private static func byteCount(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return 0 }
        return Int64(size)
    }
}

/// Video stream → video.mov.
private final class VideoOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: TrackWriter
    private let gate: FrameGate
    private let history: FrameHistory

    init(writer: TrackWriter, gate: FrameGate, history: FrameHistory) {
        self.writer = writer
        self.gate = gate
        self.history = history
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, gate.isOpen else { return }
        if writer.appendVideo(sampleBuffer), let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
            history.record(image, at: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        }
    }
}

/// Audio stream → system.m4a, plus a smoothed level for the panel meter.
private final class AudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: TrackWriter
    private let lock = NSLock()
    private var smoothed: Float = 0

    init(writer: TrackWriter) {
        self.writer = writer
    }

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return smoothed
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        writer.appendAudio(sampleBuffer)
        let rms = AudioLevel.rms(sampleBuffer)
        lock.lock()
        smoothed = max(rms, smoothed * 0.85)
        lock.unlock()
    }
}

/// The audio stream must also carry tiny video frames; they are dropped here.
private final class DiscardOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
