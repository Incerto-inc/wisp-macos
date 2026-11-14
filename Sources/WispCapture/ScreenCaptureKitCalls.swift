import CoreGraphics
import ScreenCaptureKit

/// A value handed across concurrency domains on our word that it is not shared afterwards.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// ScreenCaptureKit's async calls, made from a nonisolated context. Older SDKs (Xcode 16) do not
/// mark `SCShareableContent` or `CGImage` as Sendable, so an actor cannot receive them straight
/// from the framework; these wrappers let every supported Xcode compile the same code. The
/// results are used by the one caller that asked for them.
enum ScreenCaptureKitCalls {
    static func shareableContent() async throws -> UncheckedSendable<SCShareableContent> {
        UncheckedSendable(value: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))
    }

    /// The filter and configuration are made for this one picture and not touched again.
    static func screenshot(
        _ request: UncheckedSendable<(filter: SCContentFilter, configuration: SCStreamConfiguration)>
    ) async throws -> UncheckedSendable<CGImage> {
        let (filter, configuration) = request.value
        return UncheckedSendable(value: try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
    }
}
