import Testing
import WispDomain

@Suite("MeetingOutcome")
struct MeetingOutcomeTests {
    @Test("video bytes > 0 → completed")
    func completedWhenVideoPresent() {
        let outcome = MeetingOutcome.fromCapturedBytes(video: 10, mic: 0, system: 0)
        #expect(outcome == .completed)
        #expect(outcome.status == .completed)
    }

    @Test("no video but sound → completed: the audio is what a transcript needs")
    func completedWithSoundOnly() {
        let outcome = MeetingOutcome.fromCapturedBytes(video: 0, mic: 100, system: 100)
        #expect(outcome == .completed)
    }

    @Test("nothing at all → failed, with a reason a person can read")
    func failedWhenNothingRecorded() {
        let outcome = MeetingOutcome.fromCapturedBytes(video: 0, mic: 0, system: 0)
        #expect(outcome == .failed(reason: "Nothing was recorded."))
    }

    @Test("ambient mic bytes > 0 → completed")
    func ambientCompletedWhenMicPresent() {
        let outcome = MeetingOutcome.fromAmbientMicBytes(mic: 42)
        #expect(outcome == .completed)
        #expect(outcome.status == .completed)
    }

    @Test("ambient empty mic → failed")
    func ambientFailedWhenMicEmpty() {
        let outcome = MeetingOutcome.fromAmbientMicBytes(mic: 0)
        #expect(outcome == .failed(reason: "The microphone recorded nothing."))
    }

    @Test("mode dispatch: room ignores empty video")
    func modeDispatchRoom() {
        let outcome = MeetingOutcome.fromCapturedBytes(
            mode: .room,
            video: 0,
            mic: 8,
            system: 0
        )
        #expect(outcome == .completed)
    }

    @Test("mode dispatch: a meeting with only a microphone track is still kept")
    func modeDispatchMeeting() {
        let outcome = MeetingOutcome.fromCapturedBytes(
            mode: .meeting,
            video: 0,
            mic: 8,
            system: 0
        )
        #expect(outcome == .completed)
    }
}
