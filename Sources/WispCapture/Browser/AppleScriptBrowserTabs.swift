import AppKit
import CoreServices
import Foundation
import WispApplication
import WispDomain

/// Reads browser tabs through each browser's scripting dictionary (JavaScript for Automation).
///
/// macOS asks the user once per browser (Privacy & Security → Automation). Only
/// `requestAccess` may show that prompt; everything else checks first and reads only
/// browsers that are already allowed. Nothing read here is logged.
public struct AppleScriptBrowserTabs: BrowserTabReading {
    private let runner: OSAScriptRunner

    public init(timeout: Duration = .seconds(2)) {
        runner = OSAScriptRunner(timeout: timeout)
    }

    public func runningBrowsers() async -> [BrowserTabStatus] {
        SupportedBrowsers.all.compactMap { entry -> BrowserTabStatus? in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleIdentifier).first,
                  !app.isTerminated,
                  let access = BrowserAccessStatus.access(from: Self.permission(for: entry.bundleIdentifier, ask: false))
            else { return nil }
            return BrowserTabStatus(
                bundleIdentifier: entry.bundleIdentifier,
                name: app.localizedName ?? entry.bundleIdentifier,
                access: access
            )
        }
    }

    public func requestAccess(bundleIdentifier: String) async -> BrowserTabAccess {
        // The call blocks until the user answers the prompt: keep it off the main thread and
        // off the cooperative pool.
        let status = await withCheckedContinuation { continuation in
            DispatchQueue(label: "tech.incerto.wisp.browser-access").async {
                continuation.resume(returning: Self.permission(for: bundleIdentifier, ask: true))
            }
        }
        return BrowserAccessStatus.access(from: status) ?? .notDetermined
    }

    public func snapshot(bundleIdentifier: String) async throws -> BrowserSnapshot {
        guard let family = SupportedBrowsers.family(for: bundleIdentifier),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { throw BrowserScriptError.browserNotRunning }
        let data = try await runner.run(BrowserScripts.snapshot(family), arguments: [bundleIdentifier])
        guard let snapshot = try BrowserSnapshotParser.parse(
            data,
            bundleIdentifier: bundleIdentifier,
            name: app.localizedName ?? bundleIdentifier
        ) else { throw BrowserScriptError.browserNotRunning }
        return snapshot
    }

    public func show(_ tab: BrowserTabKey) async throws {
        guard let family = SupportedBrowsers.family(for: tab.bundleIdentifier),
              !NSRunningApplication.runningApplications(withBundleIdentifier: tab.bundleIdentifier).isEmpty
        else { throw BrowserScriptError.browserNotRunning }
        _ = try await runner.run(BrowserScripts.show(family), arguments: [tab.bundleIdentifier, tab.tabKey])
    }

    /// `AEDeterminePermissionToAutomateTarget` for any event to the browser.
    static func permission(for bundleIdentifier: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleIdentifier.utf8)
        let created = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
}
