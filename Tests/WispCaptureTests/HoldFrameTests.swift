import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import WispCapture

/// The hold that keeps another tab out of a recording, through the real writer and encoder.
@Suite("Holding on a frame from before a tab switch")
struct HoldFrameTests {
    private func solid(blue: Bool) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = out!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: CVPixelBufferGetDataSize(buffer), by: 4) {
            base[i] = blue ? 220 : 20      // B
            base[i + 1] = 20               // G
            base[i + 2] = blue ? 20 : 220  // R
            base[i + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func sample(_ image: CVPixelBuffer, at seconds: Double) -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &out)
        return out!
    }

    /// True when the decoded picture at `seconds` is mostly blue.
    private func isBlue(_ url: URL, at seconds: Double) async throws -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[2] > pixel[0] // RGBA: blue beats red
    }

    @Test("the held picture is the tab from before the switch, not the tab that replaced it")
    func holdsEarlierFrame() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-hold-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TrackWriter(url: url, fileType: .mov, videoWidth: 64, videoHeight: 48)
        let history = FrameHistory(spacing: 0.15, keep: 0.5)
        let start = 1_000.0
        writer.anchor(at: CMTime(seconds: start, preferredTimescale: 600))

        // The recorded tab (blue) until 0.8 s, when the user switches to another tab (red).
        // The switch is noticed at 0.9 s; frames up to then were already written.
        var t = 0.0
        while t <= 0.9 {
            let image = solid(blue: t < 0.8)
            if writer.appendVideo(sample(image, at: start + t)) { history.record(image, at: start + t) }
            t += 1.0 / 30
            // Real capture is paced; a writer in real-time mode drops frames sent faster than it encodes.
            try await Task.sleep(for: .milliseconds(15))
        }
        let noticed = start + 0.9
        let earlier = try #require(history.frame(atOrBefore: noticed - 0.25))
        writer.appendHeldFrame(earlier, at: CMTime(seconds: noticed, preferredTimescale: 600))
        try await writer.finish(endingAt: CMTime(seconds: start + 2, preferredTimescale: 600))

        #expect(try await isBlue(url, at: 0.5))
        #expect(try await !isBlue(url, at: 0.85)) // the brief glimpse before the switch was noticed
        #expect(try await isBlue(url, at: 1.5))   // the held picture
    }
}
