import AVFoundation
import CoreMedia
import Foundation
import WispApplication
import WispDomain

/// Room-mode capture: the microphone only (no screen, no system audio), as `mic.m4a`.
/// Same writer as meeting recordings, so a long Room session survives a crash up to its last
/// 10 s fragment.
public actor MicOnlyAmbientPipeline: AmbientMicPipeline {
    private var microphone: MicrophoneTrack?
    private var micURL: URL?

    public init() {}

    public func start(meetingID: MeetingID, directory: URL) async throws {
        guard microphone == nil else { throw AmbientCaptureError.alreadyRunning }

        let url = directory.appendingPathComponent(TrackKind.mic.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Stereo when the input offers it (room and conference microphones).
        let channels = Self.preferredChannelCount()
        let track = try MicrophoneTrack(url: url, channels: channels, bitRate: channels >= 2 ? 128_000 : 96_000)
        do {
            try track.start(anchor: CMClockGetTime(CMClockGetHostTimeClock()))
        } catch {
            await track.cancel()
            throw AmbientCaptureError.recorderFailed(error.localizedDescription)
        }
        microphone = track
        micURL = url
        NSLog("[WispCapture] room microphone started meeting=%@", meetingID.folderName)
    }

    public func stop() async throws -> TrackByteCounts {
        guard let track = microphone, let url = micURL else { throw AmbientCaptureError.notRunning }
        microphone = nil
        micURL = nil
        track.stopCapturing()
        try await track.finish(endingAt: CMClockGetTime(CMClockGetHostTimeClock()))
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        NSLog("[WispCapture] room microphone stopped bytes=%lld", bytes)
        return TrackByteCounts(video: 0, mic: bytes, system: 0)
    }

    public func currentLevels() async -> CaptureLevels {
        CaptureLevels(mic: microphone?.level ?? 0, system: 0)
    }

    public func health() async -> CaptureHealth {
        guard let microphone, !microphone.isHealthy else { return .ok }
        return CaptureHealth(stoppedTracks: [.mic])
    }

    private static func preferredChannelCount() -> Int {
        guard let device = AVCaptureDevice.default(for: .audio) else { return 1 }
        let maxChannels = device.formats
            .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0.formatDescription)?.pointee.mChannelsPerFrame }
            .max() ?? 1
        return maxChannels >= 2 ? 2 : 1
    }
}

public enum AmbientCaptureError: Error, Sendable, Equatable, LocalizedError {
    case alreadyRunning
    case notRunning
    case recorderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A Room recording is already running."
        case .notRunning: "Nothing is recording right now."
        case .recorderFailed(let reason): "The microphone could not start (\(reason))."
        }
    }
}
