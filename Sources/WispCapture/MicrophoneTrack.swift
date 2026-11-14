import AVFoundation
import CoreMedia
import Foundation

enum MicrophoneError: Error, Equatable, LocalizedError {
    case notAuthorized
    case noDevice
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Wisp is not allowed to use the microphone."
        case .noDevice: "No microphone is connected."
        case .unavailable: "The microphone could not be started."
        }
    }
}

/// The default microphone as `mic.m4a`, written through `TrackWriter` like the other tracks:
/// the same time zero (leading silence is padded), 10 s fragments that survive a crash, and a
/// level computed from the samples. AVAudioRecorder, used before, lost the whole file on a
/// crash and started a little late. The PCM passing through here is also where live features
/// (transcription while recording) can tap in later.
final class MicrophoneTrack: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: TrackWriter
    private let channels: Int
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "tech.incerto.wisp.capture.mic")
    private let lock = NSLock()
    private var smoothed: Float = 0
    private var started = false
    /// The clock the session stamps samples with; samples are moved onto the host clock.
    private var clock: CMClock?

    init(url: URL, channels: Int, bitRate: Int) throws {
        writer = try TrackWriter(url: url, fileType: .m4a, audioOnly: true, audioChannels: channels, audioBitRate: bitRate)
        self.channels = channels
        super.init()
    }

    var level: Float { lock.withLock { smoothed } }

    /// Starts the default input. Blocks briefly while the device starts; call off the main thread.
    func start(anchor: CMTime) throws {
        writer.anchor(at: anchor)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw MicrophoneError.notAuthorized }
        guard let device = AVCaptureDevice.default(for: .audio) else { throw MicrophoneError.noDevice }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneError.unavailable
        }
        session.addInput(input)
        // Float PCM at the writer's rate and channel count, so the writer only encodes.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        lock.withLock { clock = session.synchronizationClock }
        session.startRunning()
        guard session.isRunning else { throw MicrophoneError.unavailable }
        lock.withLock { started = true }
        NSLog("[WispCapture] microphone started channels=%d", channels)
    }

    /// False when the microphone never started, its device went away, or the writer failed.
    var isHealthy: Bool {
        lock.withLock { started } && session.isRunning && !writer.hasFailed
    }

    func stopCapturing() {
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func finish(endingAt end: CMTime) async throws {
        try await writer.finish(endingAt: end)
    }

    /// After a failed start: stop and discard.
    func cancel() async {
        stopCapturing()
        try? await writer.finish(endingAt: nil)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let sample = Self.onHostClock(sampleBuffer, from: lock.withLock({ clock })) else { return }
        writer.appendAudio(sample)
        let level = AudioLevel.decibels(sample)
        lock.withLock { smoothed = max(level, smoothed * 0.85) }
    }

    /// Re-stamps a sample from the capture session's clock onto the host clock the other
    /// tracks use. On most Macs the two are the same and the sample is returned as is.
    static func onHostClock(_ sample: CMSampleBuffer, from clock: CMClock?) -> CMSampleBuffer? {
        let host = CMClockGetHostTimeClock()
        guard let clock, !CFEqual(clock, host) else { return sample }
        // One timing entry covers every sample in the buffer, so its duration is one sample's.
        let rate = CMSampleBufferGetFormatDescription(sample)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 0
        var timing = CMSampleTimingInfo(
            duration: rate > 0 ? CMTime(value: 1, timescale: CMTimeScale(rate)) : .invalid,
            presentationTimeStamp: CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), from: clock, to: host),
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        ) == noErr else { return nil }
        return retimed
    }
}
