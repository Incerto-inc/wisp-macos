import Foundation

/// Stable identity for a meeting: its folder name and its row in index.json.
public struct MeetingID: Hashable, Sendable, Codable {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }

    public var folderName: String { raw.uuidString.lowercased() }
}

/// What Wisp promises to keep separate on disk.
public enum TrackKind: String, Sendable, Codable, CaseIterable {
    case video
    case mic
    case system

    public var fileName: String {
        switch self {
        case .video: "video.mov"
        case .mic: "mic.m4a"
        case .system: "system.m4a"
        }
    }
}

public enum MeetingStatus: String, Sendable, Codable {
    case recording
    case completed
    case failed
    case interrupted
}

public struct Meeting: Sendable, Equatable, Codable {
    public var id: MeetingID
    public var title: String
    public var status: MeetingStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var sourceLabel: String?
    /// Defaults to `.meeting` for index.json rows written before Room mode existed.
    public var mode: CaptureMode

    public init(
        id: MeetingID = MeetingID(),
        title: String,
        status: MeetingStatus,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        sourceLabel: String? = nil,
        mode: CaptureMode = .meeting
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sourceLabel = sourceLabel
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status, startedAt, endedAt, sourceLabel, mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(MeetingID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(MeetingStatus.self, forKey: .status)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel)
        mode = try c.decodeIfPresent(CaptureMode.self, forKey: .mode) ?? .meeting
    }
}
