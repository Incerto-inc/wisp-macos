import Foundation

/// The two sources offered up front in the panel: the likely target and one alternative.
public struct RecordChoices: Sendable, Equatable {
    public var primary: CaptureSource
    public var secondary: CaptureSource?
    /// The meeting window or tab that is in a call, if any — drives the default audio source.
    public var inCallMeeting: CaptureSource?

    public init(primary: CaptureSource, secondary: CaptureSource?, inCallMeeting: CaptureSource?) {
        self.primary = primary
        self.secondary = secondary
        self.inCallMeeting = inCallMeeting
    }

    /// - In a call: [meeting window, main screen].
    /// - No call: [main screen, frontmost on-screen window].
    /// - `pinned` (chosen via Other Window): [pinned, meeting or main screen].
    public static func make(candidates: CaptureCandidateSet, pinned: CaptureSource?) -> RecordChoices? {
        make(windows: candidates.windows, screens: candidates.screens, tabs: candidates.tabs, pinned: pinned)
    }

    /// An in-call meeting tab wins over the browser window that shows it.
    public static func make(
        windows: [CaptureSource],
        screens: [CaptureSource],
        tabs: [CaptureSource] = [],
        pinned: CaptureSource?
    ) -> RecordChoices? {
        let inCall = CaptureCandidateSet(windows: windows, screens: screens, tabs: tabs).inCallMeeting
        let mainScreen = screens.first

        if let pinned {
            let alternative = [inCall, mainScreen].compactMap { $0 }.first { $0.id != pinned.id }
            return RecordChoices(primary: pinned, secondary: alternative, inCallMeeting: inCall)
        }
        if let inCall {
            return RecordChoices(primary: inCall, secondary: mainScreen, inCallMeeting: inCall)
        }
        if let mainScreen {
            let frontmost = windows
                .filter(\.isOnScreen)
                .min { ($0.zOrder ?? .max) < ($1.zOrder ?? .max) }
            let secondary = frontmost ?? windows.first ?? screens.dropFirst().first
            return RecordChoices(primary: mainScreen, secondary: secondary, inCallMeeting: nil)
        }
        if let first = windows.first {
            return RecordChoices(primary: first, secondary: windows.dropFirst().first, inCallMeeting: nil)
        }
        return nil
    }
}
