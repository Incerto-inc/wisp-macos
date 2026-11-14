import Foundation

/// Invalid combinations are unrepresentable: you cannot be Idle with a meeting id.
public enum RecordingPhase: Sendable, Equatable {
    case idle
    case starting(MeetingID)
    case recording(MeetingID)
    case stopping(MeetingID)
    case failed(MeetingID, message: String)
}

/// Pure transitions — adapters drive I/O; this encodes lifecycle only.
public enum RecordingLifecycle {
    /// Idle or a previous failed attempt — never while starting/recording/stopping.
    public static func canStart(from phase: RecordingPhase) -> Bool {
        switch phase {
        case .idle, .failed: return true
        case .starting, .recording, .stopping: return false
        }
    }

    public static func canStop(from phase: RecordingPhase) -> Bool {
        if case .recording = phase { return true }
        return false
    }
}