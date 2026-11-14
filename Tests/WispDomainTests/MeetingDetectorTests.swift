import Testing
import WispDomain

@Suite("MeetingDetector")
struct MeetingDetectorTests {
    @Test("Zoom meeting and floating video windows are in a call")
    func zoomInCall() {
        let meeting = window(1, "Zoom Meeting", app: "zoom.us", bundle: "us.zoom.xos")
        let floating = window(2, "zoom floating video window", app: "zoom.us", bundle: "us.zoom.xos")
        #expect(MeetingDetector.signal(for: meeting) == MeetingSignal(app: .zoom, isInCall: true))
        #expect(MeetingDetector.signal(for: floating) == MeetingSignal(app: .zoom, isInCall: true))
    }

    @Test("Zoom Workplace home window is a meeting app but not a call")
    func zoomHomeIsNotACall() {
        let home = window(3, "Zoom Workplace", app: "zoom.us", bundle: "us.zoom.xos")
        #expect(MeetingDetector.signal(for: home) == MeetingSignal(app: .zoom, isInCall: false))
    }

    @Test("Teams meeting window is a call; the main Teams window is not")
    func teams() {
        let call = window(4, "Meeting with Kim | Microsoft Teams", app: "Microsoft Teams", bundle: "com.microsoft.teams2")
        let main = window(5, "Microsoft Teams", app: "Microsoft Teams", bundle: "com.microsoft.teams2")
        #expect(MeetingDetector.signal(for: call) == MeetingSignal(app: .teams, isInCall: true))
        #expect(MeetingDetector.signal(for: main) == MeetingSignal(app: .teams, isInCall: false))
    }

    @Test("Meet tabs with a meeting code are calls in any browser")
    func meetCodes() {
        let chrome = window(6, "Meet - abc-defg-hij", app: "Google Chrome", bundle: "com.google.Chrome")
        let dia = window(7, "Meet – abc-defg-hij – Dia", app: "Dia", bundle: "company.thebrowser.dia")
        #expect(MeetingDetector.signal(for: chrome) == MeetingSignal(app: .meet, isInCall: true))
        #expect(MeetingDetector.signal(for: dia) == MeetingSignal(app: .meet, isInCall: true))
    }

    @Test("the Google Meet landing page and unrelated 'meeting' titles are not meetings")
    func notMeetings() {
        let landing = window(8, "Google Meet: オンライン ウェブ会議…会議通話 | Google Workspace", app: "Google Chrome", bundle: "com.google.Chrome")
        let notes = window(9, "Meeting notes", app: "Notes", bundle: "com.apple.Notes")
        #expect(MeetingDetector.signal(for: landing) == nil)
        #expect(MeetingDetector.signal(for: notes) == nil)
    }

    @Test("Webex meeting window is a call")
    func webex() {
        let room = window(10, "Personal Room Meeting", app: "Webex", bundle: "com.cisco.webexmeetingsapp")
        #expect(MeetingDetector.signal(for: room) == MeetingSignal(app: .webex, isInCall: true))
    }

    @Test("the Teams Calls tab is not a call")
    func teamsCallsTab() {
        let calls = window(11, "Calls | Microsoft Teams", app: "Microsoft Teams", bundle: "com.microsoft.teams2")
        #expect(MeetingDetector.signal(for: calls) == MeetingSignal(app: .teams, isInCall: false))
    }

    @Test("a note whose name looks like a Meet code is not a Meet call")
    func codeLikeNoteIsNotMeet() {
        let note = window(12, "Meeting notes – one-step-out.md", app: "Notes", bundle: "com.apple.Notes")
        let draft = window(13, "meet abc-defg-hij draft", app: "TextEdit", bundle: "com.apple.TextEdit")
        #expect(MeetingDetector.signal(for: note) == nil)
        #expect(MeetingDetector.signal(for: draft) == nil)
    }
}
