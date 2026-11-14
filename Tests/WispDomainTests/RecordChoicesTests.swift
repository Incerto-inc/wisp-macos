import Testing
import WispDomain

@Suite("RecordChoices")
struct RecordChoicesTests {
    private let main = display(1, "Built-in Retina Display")
    private let zoom = window(1, "Zoom Meeting", app: "zoom.us", bundle: "us.zoom.xos", z: 1)
    private let keynote = window(2, "Q4 Roadmap.key", app: "Keynote", bundle: "com.apple.iWork.Keynote", z: 0)

    @Test("an in-call meeting is primary and the main screen is the alternative")
    func meetingFirst() throws {
        let choices = try #require(RecordChoices.make(windows: [zoom, keynote], screens: [main], pinned: nil))
        #expect(choices.primary.id == zoom.id)
        #expect(choices.secondary?.id == main.id)
        #expect(choices.inCallMeeting?.id == zoom.id)
    }

    @Test("without a meeting the main screen is primary and the frontmost window is the alternative")
    func noMeeting() throws {
        let slack = window(3, "#product", app: "Slack", bundle: "com.tinyspeck.slackmacgap", z: 0)
        let notion = window(4, "Roadmap", app: "Notion", bundle: "notion.id", z: 1)
        let choices = try #require(RecordChoices.make(windows: [notion, slack], screens: [main], pinned: nil))
        #expect(choices.primary.id == main.id)
        #expect(choices.secondary?.id == slack.id)
        #expect(choices.inCallMeeting == nil)
    }

    @Test("a window picked from Other Window becomes primary; the meeting stays as the alternative")
    func pinnedWindow() throws {
        let choices = try #require(RecordChoices.make(windows: [zoom, keynote], screens: [main], pinned: keynote))
        #expect(choices.primary.id == keynote.id)
        #expect(choices.secondary?.id == zoom.id)
        #expect(choices.inCallMeeting?.id == zoom.id)
    }

    @Test("nothing to record yields no choices")
    func empty() {
        #expect(RecordChoices.make(windows: [], screens: [], pinned: nil) == nil)
    }

    @Test("audio follows the in-call meeting app, otherwise all apps")
    func automaticAudio() {
        #expect(AudioSourcePolicy.automatic(inCallMeeting: zoom) == .application(bundleIdentifier: "us.zoom.xos", name: "zoom.us"))
        #expect(AudioSourcePolicy.automatic(inCallMeeting: nil) == .allApplications)
        #expect(AudioSource.allApplications.displayName == "All apps")
        #expect(AudioSource.application(bundleIdentifier: "us.zoom.xos", name: "zoom.us").displayName == "Zoom")
    }

    @Test("a Meet call in a browser records every app's sound (browser audio comes from helper processes)")
    func meetDefaultsToAllApps() {
        let meet = window(7, "Meet - abc-defg-hij", app: "Google Chrome", bundle: "com.google.Chrome")
        #expect(AudioSourcePolicy.automatic(inCallMeeting: meet) == .allApplications)
    }

    @Test("labels: untitled windows use the app name; off-screen windows say Other Desktop")
    func labels() {
        let untitled = window(5, "", app: "Preview", bundle: "com.apple.Preview")
        let elsewhere = window(6, "Roadmap", app: "Notion", bundle: "notion.id", onScreen: false)
        #expect(CaptureSourceLabel.title(untitled) == "Preview")
        #expect(CaptureSourceLabel.subtitle(elsewhere) == "Notion · Other Desktop")
        #expect(CaptureSourceLabel.subtitle(keynote) == "Keynote")
        #expect(CaptureSourceLabel.title(main) == "Built-in Retina Display")
    }
}
