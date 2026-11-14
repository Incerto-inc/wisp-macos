import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// One AVAssetWriter track file. Every track shares one time zero (`anchor(at:)`), so
/// video.mov, system.m4a and mic.m4a line up; files are written in fragments so a crash keeps
/// everything up to the last one.
final class TrackWriter: @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var anchorTime: CMTime?
    /// Set when the writer refuses a sample (disk full, encoder error); nothing more is appended.
    private var appendFailed = false
    private var lastVideoTime: CMTime?
    private let queue = DispatchQueue(label: "tech.incerto.wisp.track-writer")

    /// How often the file is made self-contained on disk. A crash or power loss keeps everything
    /// up to the last fragment instead of losing the whole file.
    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    init(
        url: URL,
        fileType: AVFileType,
        videoWidth: Int = 0,
        videoHeight: Int = 0,
        audioOnly: Bool = false,
        audioChannels: Int = 2,
        audioBitRate: Int = 128_000
    ) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.movieFragmentInterval = Self.fragmentInterval

        if audioOnly {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: audioChannels,
                AVEncoderBitRateKey: audioBitRate,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(aInput) else {
                throw CapturePipelineError.writerFailed("cannot add audio input")
            }
            writer.add(aInput)
            audioInput = aInput
        } else {
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw CapturePipelineError.writerFailed("cannot add video input")
            }
            writer.add(input)
            videoInput = input
        }

        guard writer.startWriting() else {
            throw CapturePipelineError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
    }

    convenience init(url: URL, fileType: AVFileType, videoWidth: Int, videoHeight: Int) throws {
        try self.init(url: url, fileType: fileType, videoWidth: videoWidth, videoHeight: videoHeight, audioOnly: false)
    }

    /// The shared time zero (host clock) every track starts its session at.
    func anchor(at time: CMTime) {
        queue.sync { anchorTime = time }
    }

    /// True when the frame was written.
    @discardableResult
    func appendVideo(_ sample: CMSampleBuffer) -> Bool {
        // ScreenCaptureKit sends status-only frames (no image) while nothing changes; the writer
        // holds the last real frame until the session ends, so those are skipped.
        guard CMSampleBufferGetImageBuffer(sample) != nil, Self.isCompleteFrame(sample) else { return false }
        return queue.sync {
            guard let videoInput, videoInput.isReadyForMoreMediaData, canAppend else { return false }
            startSessionIfNeeded(sample)
            let appended = videoInput.append(sample)
            noteResult(appended)
            if appended { lastVideoTime = CMSampleBufferGetPresentationTimeStamp(sample) }
            return appended
        }
    }

    /// Writes `image` as a new frame at `time` (or just after the last frame, if that is later).
    func appendHeldFrame(_ image: CVPixelBuffer, at time: CMTime) {
        queue.sync {
            guard sessionStarted, let videoInput, videoInput.isReadyForMoreMediaData, canAppend else { return }
            var stamp = time
            if let lastVideoTime, CMTimeCompare(stamp, lastVideoTime) <= 0 {
                stamp = CMTimeAdd(lastVideoTime, CMTime(value: 1, timescale: 600))
            }
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format) == noErr,
                  let format
            else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: stamp, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: image,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sample
            ) == noErr, let sample else { return }
            let appended = videoInput.append(sample)
            noteResult(appended)
            if appended { lastVideoTime = stamp }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        queue.sync {
            guard let audioInput, audioInput.isReadyForMoreMediaData, canAppend else { return }
            if !sessionStarted {
                startSessionIfNeeded(sample)
                // Audio containers drop a leading gap, so fill anchor → first sample with silence;
                // otherwise system.m4a would start early relative to video.mov and mic.m4a.
                if let silence = silence(before: sample) {
                    noteResult(audioInput.append(silence))
                }
            }
            noteResult(audioInput.append(sample))
        }
    }

    /// True once the writer refused a sample or failed; nothing more is written.
    var hasFailed: Bool {
        queue.sync { appendFailed || writer.status == .failed }
    }

    /// On the writer queue: false once the writer has failed.
    private var canAppend: Bool {
        !appendFailed && writer.status == .writing
    }

    private func noteResult(_ appended: Bool) {
        guard !appended, !appendFailed else { return }
        appendFailed = true
        NSLog(
            "[WispCapture] %@: writer stopped accepting samples (%@)",
            url.lastPathComponent,
            writer.error?.localizedDescription ?? "unknown"
        )
    }

    /// A silent buffer in the sample's own format covering [anchor, first sample).
    private func silence(before sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let anchorTime,
              let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0
        else { return nil }
        let gap = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), anchorTime))
        guard gap > 0.005, gap < 10 else { return nil }
        let frames = AVAudioFrameCount(gap * asbd.mSampleRate)
        let pcmFormat = AVAudioFormat(cmAudioFormatDescription: format)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: anchorTime,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: CMItemCount(frames), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &out
        ) == noErr, let out,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                out, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: pcm.audioBufferList
            ) == noErr
        else { return nil }
        return out
    }

    private static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return true }
        return status == .complete
    }

    private func startSessionIfNeeded(_ sample: CMSampleBuffer) {
        guard !sessionStarted else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        var start = pts
        if let anchorTime {
            let lead = CMTimeGetSeconds(CMTimeSubtract(pts, anchorTime))
            // Video may legitimately start late (a recorded tab hidden at first): the movie then
            // opens on an empty stretch and stays aligned. Audio pads its gap with silence, which
            // is capped, so it only starts at the anchor for a short lead.
            let maximumLead = videoInput != nil ? Double.infinity : 10
            if lead >= 0, lead <= maximumLead {
                start = anchorTime
            } else {
                NSLog("[WispCapture] %@: first sample %.3f s from the anchor — starting at the sample", url.lastPathComponent, lead)
            }
        }
        writer.startSession(atSourceTime: start)
        sessionStarted = true
    }

    /// Finishes the file; `end` (shared stop time) makes every track end together.
    func finish(endingAt end: CMTime? = nil) async throws {
        let started: Bool = await withCheckedContinuation { cont in
            queue.async { [self] in
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                if sessionStarted, let end, end.isValid {
                    writer.endSession(atSourceTime: end)
                }
                cont.resume(returning: sessionStarted)
            }
        }

        if !started {
            writer.cancelWriting()
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                cont.resume()
            }
        }
        if writer.status == .failed {
            // A failed writer (disk full, encoder error) may still leave the fragments written
            // before the failure. Keep the file only when it actually plays.
            let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            if playable {
                NSLog(
                    "[WispCapture] %@: writer failed but the file plays up to the failure — keeping it (%@)",
                    url.lastPathComponent,
                    writer.error?.localizedDescription ?? "unknown"
                )
                return
            }
            throw CapturePipelineError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }
    }
}

/// Rough 0…1 level from float32 PCM. Reads only a contiguous buffer; anything else reports 0
/// rather than reading past the segment.
enum AudioLevel {
    /// Linear meter used for system audio (RMS × 3).
    static func rms(_ sampleBuffer: CMSampleBuffer) -> Float {
        min(1, max(0, rawRMS(sampleBuffer) * 3))
    }

    /// Meter on a decibel scale (−50 dBFS … 0 dBFS → 0…1), closer to how loud a voice sounds.
    static func decibels(_ sampleBuffer: CMSampleBuffer) -> Float {
        let rms = rawRMS(sampleBuffer)
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 50) / 50))
    }

    private static func rawRMS(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        var segment = 0
        var total = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &segment, totalLengthOut: &total, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, segment == total, segment >= MemoryLayout<Float>.size
        else { return 0 }
        let sampleCount = segment / MemoryLayout<Float>.size
        return dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { ptr in
            var sum: Float = 0
            for i in 0..<sampleCount {
                sum += ptr[i] * ptr[i]
            }
            return (sum / Float(sampleCount)).squareRoot()
        }
    }
}
