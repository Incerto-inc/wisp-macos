import Foundation
import Testing
import WispDomain

@Suite("CaptureMode")
struct CaptureModeTests {
    @Test("room uses ambient subdirectory")
    func roomSubdirectory() {
        #expect(CaptureMode.room.subdirectoryName == "ambient")
        #expect(CaptureMode.meeting.subdirectoryName == nil)
    }

    @Test("Meeting Codable defaults missing mode to meeting")
    func meetingDecodeDefaultsMode() throws {
        let id = MeetingID()
        let json = """
        {
          "id": { "raw": "\(id.raw.uuidString)" },
          "title": "Legacy",
          "status": "completed",
          "startedAt": "2026-01-01T00:00:00Z"
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: data)
        #expect(meeting.mode == .meeting)
        #expect(meeting.title == "Legacy")
    }
}
