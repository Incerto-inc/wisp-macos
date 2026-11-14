import CoreGraphics
import Testing
@testable import WispUI

@Suite("Recording frame geometry")
struct RecordingFrameGeometryTests {
    @Test("a window's frame sits just outside the window, flipped into AppKit coordinates")
    func windowOutset() {
        let frame = RecordingFrameGeometry.overlayFrame(
            cgRect: CGRect(x: 100, y: 50, width: 800, height: 600),
            primaryScreenHeight: 1000,
            isDisplay: false
        )
        // AppKit y = 1000 - (50 + 600) = 350, then outset by 3pt on every side.
        #expect(frame == CGRect(x: 97, y: 347, width: 806, height: 606))
    }

    @Test("a display's frame matches the display exactly")
    func displayExact() {
        let frame = RecordingFrameGeometry.overlayFrame(
            cgRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            primaryScreenHeight: 982,
            isDisplay: true
        )
        #expect(frame == CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    @Test("a display above-left of the main one keeps its position")
    func secondaryDisplay() {
        let frame = RecordingFrameGeometry.overlayFrame(
            cgRect: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
            primaryScreenHeight: 982,
            isDisplay: true
        )
        #expect(frame == CGRect(x: -1920, y: 982, width: 1920, height: 1080))
    }
}
