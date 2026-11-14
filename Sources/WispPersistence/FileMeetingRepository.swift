import Foundation
import WispApplication
import WispDomain

/// JSON index under the media root (`index.json`). Simple and inspectable.
///
/// The index must never lose recordings: a row this build cannot read (written by a newer
/// build, or edited by hand) is kept and written back untouched, and an index that is not
/// readable at all is set aside and rebuilt from the recording folders.
public actor FileMeetingRepository: MeetingRepository {
    private let indexURL: URL
    private var rows: [UUID: Meeting] = [:]
    /// Raw JSON of rows this build cannot decode, written back as they were.
    private var unreadableRows: [Data] = []
    private var loaded = false

    public init(root: URL) {
        self.indexURL = root.appendingPathComponent("index.json")
    }

    public func insert(_ meeting: Meeting) async throws {
        try loadIfNeeded()
        rows[meeting.id.raw] = meeting
        try persist()
    }

    public func update(_ meeting: Meeting) async throws {
        try loadIfNeeded()
        rows[meeting.id.raw] = meeting
        try persist()
    }

    public func fetch(id: MeetingID) async throws -> Meeting? {
        try loadIfNeeded()
        return rows[id.raw]
    }

    public func listRecent(limit: Int) async throws -> [Meeting] {
        try loadIfNeeded()
        return Array(
            rows.values
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(limit)
        )
    }

    public func delete(id: MeetingID) async throws {
        try loadIfNeeded()
        rows[id.raw] = nil
        try persist()
    }

    private var root: URL { indexURL.deletingLastPathComponent() }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: indexURL.path) else {
            // No index but recordings on disk (deleted by hand, lost in a copy): list them again.
            rows = Dictionary(Self.recoveredMeetings(under: root).map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
            loaded = true
            if !rows.isEmpty { try persist() }
            return
        }
        let data = try Data(contentsOf: indexURL)
        guard let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            try setAsideUnreadableIndex()
            rows = Dictionary(Self.recoveredMeetings(under: root).map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
            loaded = true
            try persist()
            return
        }
        var decoded: [UUID: Meeting] = [:]
        var unreadable: [Data] = []
        for element in elements {
            // Fragments (a bare number, null) are legal JSON array elements; writing them needs
            // .fragmentsAllowed, and without it Foundation raises instead of throwing.
            guard let raw = try? JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed]) else { continue }
            if let meeting = try? JSONDecoder.wisp.decode(Meeting.self, from: raw) {
                decoded[meeting.id.raw] = meeting
            } else {
                unreadable.append(raw)
            }
        }
        rows = decoded
        unreadableRows = unreadable
        loaded = true
    }

    private func persist() throws {
        let list = rows.values.sorted { $0.startedAt > $1.startedAt }
        var elements = try JSONSerialization.jsonObject(with: JSONEncoder.wisp.encode(list)) as? [Any] ?? []
        elements += unreadableRows.compactMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        let data = try JSONSerialization.data(withJSONObject: elements, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: indexURL, options: [.atomic])
    }

    /// Keeps the unreadable file next to the index (`index.unreadable-<time>.json`) for inspection.
    private func setAsideUnreadableIndex() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let backup = root.appendingPathComponent("index.unreadable-\(formatter.string(from: Date())).json")
        try FileManager.default.moveItem(at: indexURL, to: backup)
        NSLog("[WispPersistence] index.json was unreadable; moved it to %@ and rebuilt the list", backup.lastPathComponent)
    }

    /// One row per recording folder (`<uuid>/` for meetings, `ambient/<uuid>/` for Room).
    /// Titles are lost with the index; the status is `.interrupted` because nothing says the
    /// recording finished cleanly.
    static func recoveredMeetings(under root: URL) -> [Meeting] {
        func scan(_ dir: URL, mode: CaptureMode) -> [Meeting] {
            let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            return entries.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                      let uuid = UUID(uuidString: url.lastPathComponent)
                else { return nil }
                return Meeting(
                    id: MeetingID(uuid),
                    title: mode == .room ? "Recovered room recording" : "Recovered recording",
                    status: .interrupted,
                    startedAt: values.creationDate ?? Date(),
                    mode: mode
                )
            }
        }
        var found = scan(root, mode: .meeting)
        if let sub = CaptureMode.room.subdirectoryName {
            found += scan(root.appendingPathComponent(sub, isDirectory: true), mode: .room)
        }
        return found
    }
}

private extension JSONEncoder {
    static let wisp: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()
}

private extension JSONDecoder {
    static let wisp: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}
