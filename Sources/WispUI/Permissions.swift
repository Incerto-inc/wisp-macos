import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// Screen Recording + Microphone permission helpers for the menu-bar UX.
@MainActor
public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case unknown
}

/// Stable identity shown in System Settings and copy-paste instructions.
public struct WispAppIdentity: Sendable, Equatable {
    public let displayName: String
    public let bundleIdentifier: String
    public let bundlePath: String
    public let canonicalPath: String
    public let isCanonicalInstall: Bool

    public static let canonicalBundlePath = "/Applications/Wisp.app"
    public static let expectedBundleIdentifier = "tech.incerto.wisp.mac"

    /// One-line paste target for System Settings “+”.
    public var pathToAllow: String {
        if FileManager.default.fileExists(atPath: canonicalPath) {
            return canonicalPath
        }
        return bundlePath
    }
}

@MainActor
public enum WispPermissions {
    /// Truth source for the panel checklist. System Settings can show a Wisp.app row as ON
    /// for an older build (a stale code signature) while this returns false.
    nonisolated public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Full quit + reopen so TCC grants applied in Settings take effect for this process.
    public static func quitAndRelaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        // Fallback if openApplication callback is delayed/fails: still quit so user can reopen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.terminate(nil)
        }
    }

    nonisolated public static func microphoneGranted() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        default: false
        }
    }

    public static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func currentAppIdentity() -> WispAppIdentity {
        let bundle = Bundle.main
        let path = bundle.bundlePath
        let id = bundle.bundleIdentifier ?? WispAppIdentity.expectedBundleIdentifier
        let display =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Wisp"
        let canonical = WispAppIdentity.canonicalBundlePath
        return WispAppIdentity(
            displayName: display,
            bundleIdentifier: id,
            bundlePath: path,
            canonicalPath: canonical,
            isCanonicalInstall: (path as NSString).standardizingPath == canonical
        )
    }

    public static func copyPathToPasteboard(_ identity: WispAppIdentity? = nil) {
        let id = identity ?? currentAppIdentity()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(id.pathToAllow, forType: .string)
    }

    /// Opens System Settings → Privacy & Security → Screen & System Audio Recording.
    /// Tries the Ventura+ PrivacySecurity extension URL first, then the legacy Security pane.
    public static func openScreenRecordingSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    /// Opens System Settings → Privacy & Security → Microphone.
    public static func openMicrophoneSettings() {
        openPrivacyPane(anchor: "Privacy_Microphone")
    }

    /// One intentional path: open the first missing privacy pane (Screen, then Mic).
    public static func openSettingsForMissingPermissions(
        screenOK: Bool,
        micOK: Bool
    ) {
        if !screenOK {
            openScreenRecordingSettings()
        } else if !micOK {
            openMicrophoneSettings()
        }
    }

    private static func openPrivacyPane(anchor: String) {
        // Prefer modern Settings extension (Ventura+); fall back to legacy Security pane id.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        // Last resort: Privacy & Security root (user still sees the list).
        if let root = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(root)
        }
    }
}

/// What the panel needs to know about TCC; injectable so the state machine is testable.
public protocol PermissionChecking: Sendable {
    var screenGranted: Bool { get }
    var microphoneGranted: Bool { get }
}

public struct LivePermissions: PermissionChecking {
    public init() {}
    public var screenGranted: Bool { WispPermissions.screenRecordingGranted() }
    public var microphoneGranted: Bool { WispPermissions.microphoneGranted() }
}
