import Foundation

/// Pure rule: bytes on disk decide completed vs failed.
public enum MeetingOutcome: Sendable, Equatable {
    case completed
    case failed(reason: String)

    /// Meeting mode: kept when any track has data. A meeting whose video is empty (a recorded
    /// tab never showed, screen capture failed) still has the sound a transcript needs; the
    /// panel warns about the empty track instead of discarding the meeting.
    public static func fromCapturedBytes(video: Int64, mic: Int64, system: Int64) -> MeetingOutcome {
        if video > 0 || mic > 0 || system > 0 {
            return .completed
        }
        return .failed(reason: "Nothing was recorded.")
    }

    /// Room (ambient) mode: mic-only session succeeds when mic file has bytes.
    public static func fromAmbientMicBytes(mic: Int64) -> MeetingOutcome {
        if mic > 0 {
            return .completed
        }
        return .failed(reason: "The microphone recorded nothing.")
    }

    public static func fromCapturedBytes(
        mode: CaptureMode,
        video: Int64,
        mic: Int64,
        system: Int64
    ) -> MeetingOutcome {
        switch mode {
        case .meeting:
            return fromCapturedBytes(video: video, mic: mic, system: system)
        case .room:
            return fromAmbientMicBytes(mic: mic)
        }
    }

    /// A recording still marked `.recording` when Wisp starts again never stopped cleanly
    /// (crash, force quit, power loss): its files may be cut short, so it is `.interrupted`
    /// when anything was written and `.failed` when nothing was.
    public static func statusAfterInterruption(video: Int64, mic: Int64, system: Int64) -> MeetingStatus {
        video > 0 || mic > 0 || system > 0 ? .interrupted : .failed
    }

    public var status: MeetingStatus {
        switch self {
        case .completed: .completed
        case .failed: .failed
        }
    }
}
