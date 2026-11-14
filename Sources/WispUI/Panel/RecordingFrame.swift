import AppKit
import CoreGraphics
import WispApplication
import WispDomain

/// Converts a target's CoreGraphics rectangle into the overlay window's AppKit frame.
enum RecordingFrameGeometry {
    /// Stroke width of the frame; windows get the frame just outside their edge.
    static let strokeWidth: CGFloat = 3

    static func overlayFrame(cgRect: CGRect, primaryScreenHeight: CGFloat, isDisplay: Bool) -> CGRect {
        let flipped = CGRect(
            x: cgRect.minX,
            y: primaryScreenHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
        return isDisplay ? flipped : flipped.insetBy(dx: -strokeWidth, dy: -strokeWidth)
    }
}

/// While recording, outlines what is being recorded — like a screen-share border — in vermillion.
/// The frame is Wisp's own window: screen recordings exclude Wisp, and `sharingType = .none`
/// keeps it out of other apps' screen sharing too.
@MainActor
public final class RecordingFrameController {
    private let locator: CaptureTargetLocating
    private var overlay: NSPanel?
    private var frameView: FrameView?
    private var tracking: Task<Void, Never>?

    public init(locator: CaptureTargetLocating) {
        self.locator = locator
    }

    public func show(for id: CaptureSourceID) {
        hide()
        tracking = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let frame = await self.locator.frame(of: id)
                if Task.isCancelled { return }
                self.apply(frame)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func hide() {
        tracking?.cancel()
        tracking = nil
        overlay?.orderOut(nil)
    }

    private func apply(_ target: CaptureTargetFrame?) {
        guard let target else {
            overlay?.orderOut(nil)
            return
        }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let rect = RecordingFrameGeometry.overlayFrame(cgRect: target.rect, primaryScreenHeight: primaryHeight, isDisplay: target.isDisplay)
        let panel = overlay ?? makeOverlay()
        frameView?.isDisplay = target.isDisplay
        if panel.frame != rect {
            panel.setFrame(rect, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func makeOverlay() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = FrameView()
        panel.contentView = view
        overlay = panel
        frameView = view
        return panel
    }
}

private final class FrameView: NSView {
    var isDisplay = false {
        didSet { if oldValue != isDisplay { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = RecordingFrameGeometry.strokeWidth
        let rect = bounds.insetBy(dx: width / 2, dy: width / 2)
        let radius: CGFloat = isDisplay ? 0 : 12
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = width
        Ink.nsColor(.vermillion, alpha: 0.95).setStroke()
        path.stroke()
    }
}
