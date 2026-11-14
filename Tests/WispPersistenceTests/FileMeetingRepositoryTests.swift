import Foundation
import Testing
import WispDomain
import WispPersistence

@Suite("FileMeetingRepository")
struct FileMeetingRepositoryTests {
    @Test("insert + listRecent persists across instances")
    func persistsIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = MeetingID()
        let meeting = Meeting(id: id, title: "Standup", status: .completed)
        let repo = FileMeetingRepository(root: root)
        try await repo.insert(meeting)

        let reloaded = FileMeetingRepository(root: root)
        let listed = try await reloaded.listRecent(limit: 10)
        #expect(listed.count == 1)
        #expect(listed.first?.id == id)
        #expect(listed.first?.title == "Standup")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a row this build cannot read is kept on disk, and the other rows still list")
    func keepsUnreadableRows() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FileMeetingRepository(root: root)
        try await repo.insert(Meeting(title: "A", status: .completed, startedAt: Date(timeIntervalSince1970: 100)))
        try await repo.insert(Meeting(title: "B", status: .completed, startedAt: Date(timeIntervalSince1970: 200)))
        try await repo.insert(Meeting(title: "C", status: .completed, startedAt: Date(timeIntervalSince1970: 300)))

        // A newer build wrote a status this build does not know.
        let index = root.appendingPathComponent("index.json")
        let text = try String(contentsOf: index, encoding: .utf8)
        let changed = text.replacingOccurrences(of: "\"title\" : \"B\"", with: "\"title\" : \"B\", \"future\" : 1")
            .replacingOccurrences(of: "\"completed\"", with: "\"transcribing\"", options: [], range: text.range(of: "\"completed\""))
        try changed.write(to: index, atomically: true, encoding: .utf8)

        let reopened = FileMeetingRepository(root: root)
        let listed = try await reopened.listRecent(limit: 10)
        #expect(listed.count == 2)
        try await reopened.insert(Meeting(title: "D", status: .completed))

        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]]
        #expect(rows?.count == 4)
        #expect(rows?.contains { ($0["status"] as? String) == "transcribing" } == true)
    }

    @Test("an index that is not readable at all is set aside and rebuilt from the recording folders")
    func rebuildsFromFolders() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = MeetingID()
        let roomID = MeetingID()
        let meetingDir = root.appendingPathComponent(meetingID.folderName, isDirectory: true)
        let roomDir = root.appendingPathComponent("ambient/\(roomID.folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: roomDir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: meetingDir.appendingPathComponent("video.mov"))
        try Data([1, 2, 3]).write(to: roomDir.appendingPathComponent("mic.m4a"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-meeting"), withIntermediateDirectories: true)
        try Data("{ truncated".utf8).write(to: root.appendingPathComponent("index.json"))

        let repo = FileMeetingRepository(root: root)
        let listed = try await repo.listRecent(limit: 10)
        #expect(Set(listed.map(\.id)) == [meetingID, roomID])
        #expect(listed.first { $0.id == roomID }?.mode == .room)
        #expect(listed.allSatisfy { $0.status == .interrupted })

        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("index.unreadable-") }
        #expect(backups.count == 1)
    }

    @Test("odd elements in the index (a number, null) are kept, not a crash")
    func oddElements() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FileMeetingRepository(root: root)
        try await repo.insert(Meeting(title: "A", status: .completed))
        let index = root.appendingPathComponent("index.json")
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [Any]
        rows.append(42)
        rows.append(NSNull())
        try JSONSerialization.data(withJSONObject: rows).write(to: index)

        let reopened = FileMeetingRepository(root: root)
        #expect(try await reopened.listRecent(limit: 10).count == 1)
        try await reopened.insert(Meeting(title: "B", status: .completed))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [Any]
        #expect(written?.count == 4)
    }

    @Test("a missing index is rebuilt from recording folders that are still there")
    func rebuildsWhenMissing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = MeetingID()
        let dir = root.appendingPathComponent(id.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("mic.m4a"))

        let listed = try await FileMeetingRepository(root: root).listRecent(limit: 10)
        #expect(listed.map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json").path))
    }
}
