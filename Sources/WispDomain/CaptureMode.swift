import Foundation

/// How a session is captured. Meeting uses screen + mic + system; Room is mic-only ambient.
public enum CaptureMode: String, Sendable, Codable, CaseIterable, Equatable {
    case meeting
    case room

    public var displayName: String {
        switch self {
        case .meeting: "Meeting"
        case .room: "Room"
        }
    }

    /// Room sessions live under `ambient/` so they stay distinct from 3-track meetings.
    public var subdirectoryName: String? {
        switch self {
        case .meeting: nil
        case .room: "ambient"
        }
    }
}
