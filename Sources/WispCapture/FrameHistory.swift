import CoreVideo
import Foundation

/// Copies of recent video frames. When a recorded tab is hidden, the switch is noticed a few
/// frames late; the pipeline then ends on a copy from before the switch instead of on the
/// other tab's picture. Copies are taken every `spacing` seconds and kept for `keep` seconds,
/// so only a handful exist (about 2 MB each at 1470 × 956), and they never hold on to
/// ScreenCaptureKit's own buffers, whose pool is small.
final class FrameHistory: @unchecked Sendable {
    private let spacing: Double
    private let keep: Double
    private let lock = NSLock()
    private var frames: [(time: Double, image: CVPixelBuffer)] = []

    init(spacing: Double, keep: Double) {
        self.spacing = spacing
        self.keep = keep
    }

    /// `time` is the frame's presentation time in seconds on the host clock.
    func record(_ image: CVPixelBuffer, at time: Double) {
        let due = lock.withLock { frames.last.map { time - $0.time >= spacing } ?? true }
        guard due, let copy = Self.copy(image) else { return }
        lock.withLock {
            frames.append((time, copy))
            frames.removeAll { time - $0.time > keep }
        }
    }

    /// The newest copy taken at or before `cutoff`.
    func frame(atOrBefore cutoff: Double) -> CVPixelBuffer? {
        lock.withLock { frames.last { $0.time <= cutoff }?.image }
    }

    func forget() {
        lock.withLock { frames.removeAll() }
    }

    /// A deep copy in the same pixel format, plane by plane.
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            attributes,
            &out
        ) == kCVReturnSuccess, let copy = out else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let to = CVPixelBufferGetBaseAddressOfPlane(copy, plane)
                else { return nil }
                copyRows(
                    from: from, fromStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    to: to, toStride: CVPixelBufferGetBytesPerRowOfPlane(copy, plane),
                    rows: CVPixelBufferGetHeightOfPlane(source, plane)
                )
            }
        } else {
            guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(copy) else { return nil }
            copyRows(
                from: from, fromStride: CVPixelBufferGetBytesPerRow(source),
                to: to, toStride: CVPixelBufferGetBytesPerRow(copy),
                rows: CVPixelBufferGetHeight(source)
            )
        }
        return copy
    }

    private static func copyRows(from: UnsafeMutableRawPointer, fromStride: Int, to: UnsafeMutableRawPointer, toStride: Int, rows: Int) {
        let width = min(fromStride, toStride)
        for row in 0..<rows {
            memcpy(to + row * toStride, from + row * fromStride, width)
        }
    }
}
