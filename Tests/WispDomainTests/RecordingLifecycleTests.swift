import Testing
import WispDomain

@Suite("RecordingLifecycle")
struct RecordingLifecycleTests {
    @Test("can start from idle or failed, not mid-flight")
    func startOnlyIdleOrFailed() {
        let id = MeetingID()
        #expect(RecordingLifecycle.canStart(from: .idle))
        #expect(RecordingLifecycle.canStart(from: .failed(id, message: "boom")))
        #expect(!RecordingLifecycle.canStart(from: .recording(id)))
        #expect(!RecordingLifecycle.canStart(from: .starting(id)))
        #expect(!RecordingLifecycle.canStart(from: .stopping(id)))
    }

    @Test("can stop only while recording")
    func stopOnlyRecording() {
        let id = MeetingID()
        #expect(RecordingLifecycle.canStop(from: .recording(id)))
        #expect(!RecordingLifecycle.canStop(from: .idle))
        #expect(!RecordingLifecycle.canStop(from: .starting(id)))
    }
}
