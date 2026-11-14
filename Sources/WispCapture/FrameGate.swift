import Foundation

/// Whether video frames are written. Closed while a recorded tab is hidden: the stream keeps
/// running and the writer's timeline is untouched, so the video simply holds its last frame.
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool { lock.withLock { open } }

    func set(open newValue: Bool) {
        lock.withLock { open = newValue }
    }
}
