import Foundation

/// Where `system.m4a` comes from — independent of what the video shows.
public enum AudioSource: Sendable, Equatable, Hashable {
    case application(bundleIdentifier: String, name: String)
    case allApplications

    public var displayName: String {
        switch self {
        case .application(_, let name):
            return AppName.friendly(name)
        case .allApplications:
            return "All apps"
        }
    }
}

public enum AudioSourcePolicy {
    /// The in-call meeting app when there is one; otherwise every app's sound.
    /// Meetings in a browser (Meet, or any meeting tab) play audio from helper processes
    /// ScreenCaptureKit does not list separately, so they record every app rather than risk
    /// losing the other side.
    public static func automatic(inCallMeeting: CaptureSource?) -> AudioSource {
        if let meeting = inCallMeeting,
           meeting.kind == .tab || MeetingDetector.signal(for: meeting)?.app == .meet
        {
            return .allApplications
        }
        guard let meeting = inCallMeeting,
              let bundle = meeting.bundleIdentifier,
              !bundle.isEmpty
        else { return .allApplications }
        return .application(bundleIdentifier: bundle, name: meeting.applicationName ?? bundle)
    }
}
