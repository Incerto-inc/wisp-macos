import Foundation
import WispApplication
import WispDomain

/// Recording folders under ~/Movies/Wisp-macos: `<uuid>/` for meetings, `ambient/<uuid>/` for Room.
public struct LocalMeetingFileStore: MeetingFileStore {
    public var root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            self.root = movies.appendingPathComponent("Wisp-macos", isDirectory: true)
        }
    }

    public func meetingDirectory(for id: MeetingID) throws -> URL {
        try directory(for: id, mode: .meeting)
    }

    public func ensureMeetingDirectory(for id: MeetingID) throws -> URL {
        try ensureDirectory(for: id, mode: .meeting)
    }

    public func directory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        var url = root
        if let sub = mode.subdirectoryName {
            url = url.appendingPathComponent(sub, isDirectory: true)
        }
        return url.appendingPathComponent(id.folderName, isDirectory: true)
    }

    public func ensureDirectory(for id: MeetingID, mode: CaptureMode) throws -> URL {
        let url = try directory(for: id, mode: mode)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func removeMeetingDirectory(for id: MeetingID) throws {
        // Prefer ambient path if present (Room sessions); else meeting root.
        let ambient = try directory(for: id, mode: .room)
        let meeting = try directory(for: id, mode: .meeting)
        let fm = FileManager.default
        if fm.fileExists(atPath: ambient.path) {
            try fm.removeItem(at: ambient)
        }
        if fm.fileExists(atPath: meeting.path) {
            try fm.removeItem(at: meeting)
        }
    }
}
