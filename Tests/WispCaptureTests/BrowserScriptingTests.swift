import CoreVideo
import Foundation
import Testing
@testable import WispCapture
import WispDomain

@Suite("Capture target ids")
struct CaptureTargetIDTests {
    @Test("window, screen and tab ids parse; anything else does not")
    func parses() {
        #expect(CaptureTargetID(CaptureSourceID("window:4521")) == .window(4521))
        #expect(CaptureTargetID(CaptureSourceID("screen:1")) == .screen(1))
        let key = BrowserTabKey(bundleIdentifier: "com.google.Chrome", tabKey: "1803")
        #expect(CaptureTargetID(key.sourceID) == .tab(key))
        #expect(CaptureTargetID(CaptureSourceID("window:abc")) == nil)
        #expect(CaptureTargetID(CaptureSourceID("app:zoom")) == nil)
        #expect(CaptureTargetID.window(7).sourceID == CaptureSourceID("window:7"))
    }
}

@Suite("Browser scripting")
struct BrowserScriptingTests {
    @Test("Chrome-family output becomes a snapshot: keys, order, frames, incognito, active tab")
    func parsesChromium() throws {
        let json = #"""
        {"windows":[
          {"key":"1081","index":1,"title":"Meet – abc-defg-hij","bounds":{"x":0,"y":38,"width":1512,"height":944},"private":false,"active":"1803",
           "tabs":[{"key":"1802","title":"Inbox","url":"https://mail.example/"},{"key":"1803","title":"Meet – abc-defg-hij","url":"https://meet.google.com/abc-defg-hij"}]},
          {"key":"1090","index":2,"title":"Secret","bounds":{"x":40,"y":60,"width":800,"height":600},"private":true,"active":"1900",
           "tabs":[{"key":"1900","title":"Secret","url":"https://s.example/"}]}
        ]}
        """#
        let snapshot = try #require(try BrowserSnapshotParser.parse(Data(json.utf8), bundleIdentifier: "com.google.Chrome", name: "Google Chrome"))
        #expect(snapshot.bundleIdentifier == "com.google.Chrome")
        #expect(snapshot.name == "Google Chrome")
        #expect(snapshot.windows.count == 2)
        let front = snapshot.windows[0]
        #expect(front.key == "1081")
        #expect(front.index == 1)
        #expect(front.bounds == CaptureRect(x: 0, y: 38, width: 1512, height: 944))
        #expect(front.activeTabKey == "1803")
        #expect(front.tabs.map(\.key) == ["1802", "1803"])
        #expect(front.tabs[1].url == "https://meet.google.com/abc-defg-hij")
        #expect(snapshot.windows[1].isPrivate)
    }

    @Test("Safari has no tab ids: a tab is its window and position, so a page that changes its address keeps its key")
    func derivesSafariKeys() throws {
        let json = #"""
        {"windows":[
          {"key":"55","index":1,"title":"Docs","bounds":null,"private":false,"activeIndex":2,
           "tabs":[{"title":"Docs","url":"https://docs.example/a"},{"title":"Docs","url":"https://docs.example/a"},{"title":"","url":""}]},
          {"key":"56","index":2,"title":"Meet","bounds":null,"private":false,"activeIndex":1,
           "tabs":[{"title":"Meet","url":"https://meet.google.com/abc-defg-hij?authuser=0"}]}
        ]}
        """#
        let snapshot = try #require(try BrowserSnapshotParser.parse(Data(json.utf8), bundleIdentifier: "com.apple.Safari", name: "Safari"))
        let keys = snapshot.windows.map { $0.tabs.map(\.key) }
        #expect(keys == [["55/1", "55/2", "55/3"], ["56/1"]])
        #expect(snapshot.windows[0].activeTabKey == "55/2")
        #expect(snapshot.windows[1].activeTabKey == "56/1")
    }

    @Test("a browser that quit while being read gives no snapshot")
    func quitBrowser() throws {
        #expect(try BrowserSnapshotParser.parse(Data("null\n".utf8), bundleIdentifier: "company.thebrowser.dia", name: "Dia") == nil)
    }

    @Test("malformed output is an error, not an empty browser")
    func malformed() {
        #expect(throws: (any Error).self) {
            _ = try BrowserSnapshotParser.parse(Data("{\"windows\": 3".utf8), bundleIdentifier: "com.google.Chrome", name: "Chrome")
        }
    }

    @Test("macOS permission answers map to tab access; a browser that is not running has none")
    func accessMapping() {
        #expect(BrowserAccessStatus.access(from: 0) == .granted)
        #expect(BrowserAccessStatus.access(from: -1744) == .notDetermined)
        #expect(BrowserAccessStatus.access(from: -1743) == .denied)
        #expect(BrowserAccessStatus.access(from: -600) == nil)
    }

    @Test("every snapshot script checks that the browser still runs and reads tabs in bulk")
    func scriptsAreSafe() {
        for family in BrowserFamily.allCases {
            let script = BrowserScripts.snapshot(family)
            #expect(script.contains("app.running()"), "\(family) must not relaunch a quit browser")
            #expect(script.contains("tabs.url()"), "\(family) must read tab URLs in one event")
            #expect(script.contains("tabs.title()") || script.contains("tabs.name()"), "\(family) must read tab titles in one event")
            #expect(BrowserScripts.show(family).contains("app.running()"))
        }
    }

    @Test("Safari's show script finds a tab by the same window-and-position key the parser makes")
    func safariShowKeys() {
        #expect(BrowserScripts.show(.safari).contains("String(w.id()) + '/' + (j + 1)"))
    }

    @Test("known browsers map to their scripting family; Firefox is not supported")
    func families() {
        #expect(SupportedBrowsers.family(for: "com.google.Chrome") == .chromium)
        #expect(SupportedBrowsers.family(for: "com.brave.Browser") == .chromium)
        #expect(SupportedBrowsers.family(for: "company.thebrowser.Browser") == .arc)
        #expect(SupportedBrowsers.family(for: "company.thebrowser.dia") == .dia)
        #expect(SupportedBrowsers.family(for: "com.apple.Safari") == .safari)
        #expect(SupportedBrowsers.family(for: "org.mozilla.firefox") == nil)
    }
}

@Suite("Script runner")
struct ScriptRunnerTests {
    @Test("returns what the script prints and passes arguments without quoting tricks")
    func runs() async throws {
        let out = try await OSAScriptRunner().run("function run(argv) { return argv[0] + '|' + argv[1] }", arguments: ["a\"b", "c d"])
        #expect(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "a\"b|c d")
    }

    @Test("a script that hangs is stopped at the timeout")
    func timesOut() async {
        let runner = OSAScriptRunner(timeout: .milliseconds(300))
        let start = ContinuousClock.now
        await #expect(throws: BrowserScriptError.timedOut) {
            _ = try await runner.run("delay(10); 'late'", arguments: [])
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("cancelling the task stops the script promptly")
    func cancels() async {
        let task = Task { try await OSAScriptRunner(timeout: .seconds(20)).run("delay(10); 'late'", arguments: []) }
        try? await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}

@Suite("Frame gate")
struct FrameGateTests {
    @Test("frames pass only while the gate is open")
    func gate() {
        let gate = FrameGate()
        #expect(gate.isOpen)
        gate.set(open: false)
        #expect(!gate.isOpen)
        gate.set(open: true)
        #expect(gate.isOpen)
    }
}

@Suite("Capture errors")
struct CaptureErrorTests {
    private func sck(_ code: Int) -> NSError {
        NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: code, userInfo: [NSLocalizedDescriptionKey: "raw"])
    }

    @Test("ScreenCaptureKit errors become the pipeline's own, with plain copy")
    func mapsScreenCaptureKitErrors() {
        #expect(CapturePipelineError.from(sck(-3801)) as? CapturePipelineError == .screenRecordingDenied)
        if case .sourceNotFound = CapturePipelineError.from(sck(-3815)) as? CapturePipelineError {} else {
            Issue.record("a missing capture source should read as sourceNotFound")
        }
        #expect(CapturePipelineError.from(sck(-3802)) as? CapturePipelineError == .screenCaptureFailed)
        #expect((CapturePipelineError.from(sck(-3801)) as? LocalizedError)?.errorDescription?.contains("Screen Recording") == true)
    }

    @Test("other errors pass through untouched")
    func passesOthersThrough() {
        let other = CocoaError(.fileWriteOutOfSpace)
        #expect(CapturePipelineError.from(other) as? CocoaError == other)
        #expect(CapturePipelineError.from(CapturePipelineError.alreadyRunning) as? CapturePipelineError == .alreadyRunning)
    }
}

@Suite("Recent frames kept for a hold")
struct FrameHistoryTests {
    private func buffer(fill: UInt8) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = out!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(fill), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func firstByte(_ buffer: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CVPixelBufferGetBaseAddress(buffer)!.load(as: UInt8.self)
    }

    @Test("gives back a copy of the newest frame from before the cutoff")
    func picksFrameBeforeCutoff() throws {
        let history = FrameHistory(spacing: 0.1, keep: 0.6)
        for step in 0...20 { // a frame every 50 ms for 1 s; the fill encodes the step
            history.record(buffer(fill: UInt8(step)), at: Double(step) * 0.05)
        }
        let held = try #require(history.frame(atOrBefore: 0.75))
        let byte = firstByte(held)
        #expect(byte <= 15)
        #expect(byte >= 12)
    }

    @Test("the kept copy does not change when the source buffer is reused")
    func copies() throws {
        let history = FrameHistory(spacing: 0.1, keep: 0.6)
        let source = buffer(fill: 7)
        history.record(source, at: 0)
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source), 99, CVPixelBufferGetDataSize(source))
        CVPixelBufferUnlockBaseAddress(source, [])
        #expect(firstByte(try #require(history.frame(atOrBefore: 1))) == 7)
    }

    @Test("nothing older than the cutoff means nothing to hold; forget clears it")
    func emptyCases() {
        let history = FrameHistory(spacing: 0.1, keep: 0.6)
        history.record(buffer(fill: 1), at: 5)
        #expect(history.frame(atOrBefore: 4.9) == nil)
        history.forget()
        #expect(history.frame(atOrBefore: 10) == nil)
    }
}
