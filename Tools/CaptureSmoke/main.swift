import AppKit
import AVFoundation
import Foundation
import WispApplication
import WispCapture
import WispDomain
import WispPersistence

/// Real-hardware contract checks for the capture adapter (needs Screen Recording + Mic for this runner).
///
///   capture-smoke --list                         recordable windows/displays from live SCK (expects ≤ 60 windows, real display names)
///   capture-smoke --tabs                         browsers Wisp could read tabs from, with access and counts only
///                                                (never titles or URLs; never asks for access or switches tabs)
///   capture-smoke [--play] [--audio-app <bundle>] [--expect-silent-system]
///                                                4 s of main display video + mic + system audio
///     --play                    plays a sound from another process (afplay) during capture
///     --audio-app <bundle>      record system audio from that app only (unknown bundle → falls back to all apps)
///     --expect-silent-system    fail unless system.m4a stays silent (afplay is not the chosen app)
///     --retarget                hold frames for 1.2 s, then move the video to the frontmost window
///     --late-video              hold frames for the first 11 s (a hidden tab), then show; tracks must stay aligned
///   capture-smoke --crash-after <s>              record the main display, then die with SIGKILL after <s> seconds
///   capture-smoke --inspect <dir>                duration and playability of each track in a recording folder
@main
struct CaptureSmoke {
    static func main() async {
        _ = NSApplication.shared // window-server connection for NSScreen names in CLI context
        let args = CommandLine.arguments
        if args.contains("--list") {
            await list()
            return
        }
        if let seconds = value(after: "--crash-after", in: args).flatMap(Double.init) {
            await crash(after: seconds)
            return
        }
        if let dir = value(after: "--inspect", in: args) {
            await inspect(URL(fileURLWithPath: dir))
            return
        }
        if args.contains("--tabs") {
            await tabs()
            return
        }
        if args.contains("--locate") {
            await locate()
            return
        }
        if args.contains("--thumbs") {
            await thumbs(outDir: value(after: "--thumbs", in: args))
            return
        }
        await record(
            audioApp: value(after: "--audio-app", in: args),
            play: args.contains("--play"),
            expectSilentSystem: args.contains("--expect-silent-system"),
            retarget: args.contains("--retarget"),
            lateVideo: args.contains("--late-video")
        )
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - --crash-after / --inspect

    /// A recording that never stops cleanly, as after a crash or power loss.
    private static func crash(after seconds: Double) async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-capture-smoke-\(UUID().uuidString)", isDirectory: true)
        let files = LocalMeetingFileStore(root: root)
        do {
            let raw = try await SCKCaptureSourceListing().listShareableSources()
            guard let screen = CaptureCandidates.screens(from: raw).first else { exit(1) }
            let dir = try files.ensureMeetingDirectory(for: MeetingID())
            let pipeline = SCKCapturePipeline()
            try await pipeline.start(meetingID: MeetingID(), video: screen.id, audio: .allApplications, directory: dir)
            print("ARTIFACT_DIR=\(dir.path)")
            fflush(stdout)
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(1))
                let sizes = TrackKind.allCases.map { track -> String in
                    let bytes = (try? dir.appendingPathComponent(track.fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return "\(track.rawValue)=\(bytes)"
                }
                let others = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .filter { name in !TrackKind.allCases.contains { $0.fileName == name } }
                print("SIZES " + sizes.joined(separator: " ") + " other=\(others.count)")
                fflush(stdout)
            }
            if ProcessInfo.processInfo.environment["WISP_SMOKE_STOP_INSTEAD"] != nil {
                let counts = try await pipeline.stop()
                print("STOPPED video=\(counts.video) mic=\(counts.mic) system=\(counts.system)")
                exit(0)
            }
            kill(getpid(), SIGKILL)
        } catch {
            fputs("crash-after failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func inspect(_ dir: URL) async {
        for track in TrackKind.allCases {
            let url = dir.appendingPathComponent(track.fileName)
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let seconds = await duration(of: url)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print(String(format: "TRACK %@ bytes=%d playable=%@ duration=%.2f", track.rawValue, bytes, playable ? "yes" : "no", seconds))
        }
    }

    // MARK: - --tabs

    /// Reads every browser the terminal may already automate. Prints counts, never content.
    private static func tabs() async {
        let reader = AppleScriptBrowserTabs()
        let browsers = await reader.runningBrowsers()
        guard let raw = try? await SCKCaptureSourceListing().listShareableSources() else {
            print("TABS_FAIL listing failed (Screen Recording permission?)")
            exit(1)
        }
        let windows = CaptureCandidates.windows(from: raw, ownBundleIdentifier: nil)
        print("BROWSERS \(browsers.count)")
        var failed = false
        for browser in browsers {
            guard browser.access == .granted else {
                print("BROWSER \(browser.bundleIdentifier) access=\(browser.access)")
                continue
            }
            let started = ContinuousClock.now
            do {
                let snapshot = try await reader.snapshot(bundleIdentifier: browser.bundleIdentifier)
                let elapsed = ContinuousClock.now - started
                let matched = BrowserWindowMatcher.match(snapshot, windows: windows)
                let sources = BrowserTabs.sources(from: [snapshot], windows: windows)
                let listed = CaptureCandidates.tabs(from: sources)
                let tabCount = snapshot.windows.reduce(0) { $0 + $1.tabs.count }
                let privateTabs = snapshot.windows.filter(\.isPrivate).reduce(0) { $0 + $1.tabs.count }
                let meetings = listed.filter { MeetingDetector.signal(for: $0) != nil }.count
                let withBounds = snapshot.windows.filter { $0.bounds != nil }.count
                print(
                    "BROWSER \(browser.bundleIdentifier) access=granted windows=\(snapshot.windows.count) withBounds=\(withBounds) "
                        + "matched=\(matched.count) tabs=\(tabCount) privateTabs=\(privateTabs) listed=\(listed.count) "
                        + "active=\(listed.filter { $0.tab?.isActive == true }.count) meetings=\(meetings) "
                        + "readMs=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)"
                )
                if matched.count < snapshot.windows.filter({ !$0.isPrivate }).count {
                    print("NOTE \(browser.bundleIdentifier): some windows could not be matched to a recordable window")
                }
            } catch {
                failed = true
                print("BROWSER \(browser.bundleIdentifier) access=granted READ_FAIL \(error)")
            }
        }
        print(failed ? "TABS_FAIL" : "TABS_OK")
        if failed { exit(1) }
    }

    // MARK: - --list

    private static func list() async {
        do {
            let raw = try await SCKCaptureSourceListing().listShareableSources()
            let windows = CaptureCandidates.windows(from: raw, ownBundleIdentifier: nil)
            let screens = CaptureCandidates.screens(from: raw)
            print("RAW=\(raw.count) WINDOWS=\(windows.count) SCREENS=\(screens.count)")
            for screen in screens { print("SCREEN \(screen.title)") }
            for window in windows {
                let meeting = MeetingDetector.signal(for: window).map { $0.isInCall ? " [in call]" : " [meeting app]" } ?? ""
                print("WINDOW \(CaptureSourceLabel.subtitle(window)) z=\(window.zOrder.map(String.init) ?? "-")\(meeting)")
            }
            let namedScreens = !screens.isEmpty && screens.allSatisfy { $0.title != "Display" }
            guard windows.count <= 60, namedScreens else {
                print("LIST: FAIL (expected ≤ 60 recordable windows and named displays)")
                exit(3)
            }
            print("LIST: PASS")
        } catch {
            fputs("LIST: ERROR \(error)\n", stderr)
            exit(1)
        }
    }

    // MARK: - --locate

    /// Where the frontmost recordable window and the main display are on screen (CG global coordinates).
    private static func locate() async {
        do {
            let raw = try await SCKCaptureSourceListing().listShareableSources()
            let window = CaptureCandidates.windows(from: raw, ownBundleIdentifier: nil).first(where: \.isOnScreen)
            let screen = CaptureCandidates.screens(from: raw).first
            let locator = CGTargetLocator()
            var ok = true
            for source in [window, screen].compactMap({ $0 }) {
                let frame = await locator.frame(of: source.id)
                print("LOCATE \(source.id.raw) \(CaptureSourceLabel.subtitle(source)) → \(frame.map { "\($0.rect) display=\($0.isDisplay)" } ?? "nil")")
                if frame == nil || frame!.rect.width < 100 { ok = false }
            }
            print(ok ? "LOCATE: PASS" : "LOCATE: FAIL")
            exit(ok ? 0 : 3)
        } catch {
            fputs("LOCATE: ERROR \(error)\n", stderr)
            exit(1)
        }
    }

    // MARK: - --thumbs <dir>

    /// Thumbnails for the first recordable windows and every display; writes PNGs when a dir is given.
    private static func thumbs(outDir: String?) async {
        do {
            let raw = try await SCKCaptureSourceListing().listShareableSources()
            let picks = Array(CaptureCandidates.windows(from: raw, ownBundleIdentifier: nil).prefix(4)) + CaptureCandidates.screens(from: raw)
            let provider = SCKThumbnailProvider()
            var made = 0
            for source in picks {
                let started = Date()
                let image = await provider.thumbnail(for: source.id, maxPixelSize: 480)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("THUMB \(source.id.raw) \(CaptureSourceLabel.subtitle(source)) → \(image.map { "\($0.width)x\($0.height)" } ?? "nil") in \(ms) ms")
                guard let image else { continue }
                made += 1
                if let outDir {
                    let rep = NSBitmapImageRep(cgImage: image)
                    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(source.id.raw.replacingOccurrences(of: ":", with: "-")).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                guard max(image.width, image.height) <= 480 else {
                    print("THUMBS: FAIL (long edge over 480 px)")
                    exit(3)
                }
            }
            print(made > 0 ? "THUMBS: PASS (\(made)/\(picks.count))" : "THUMBS: FAIL (no thumbnails)")
            exit(made > 0 ? 0 : 3)
        } catch {
            fputs("THUMBS: ERROR \(error)\n", stderr)
            exit(1)
        }
    }

    // MARK: - record

    private static func record(audioApp: String?, play: Bool, expectSilentSystem: Bool, retarget: Bool, lateVideo: Bool) async {
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        print("microphone authorized: \(micOK)")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-capture-smoke-\(UUID().uuidString)", isDirectory: true)
        let files = LocalMeetingFileStore(root: root)
        let pipeline = SCKCapturePipeline()
        let audio: AudioSource = audioApp.map { .application(bundleIdentifier: $0, name: $0) } ?? .allApplications
        print("AUDIO_SOURCE=\(audio)")

        do {
            let raw = try await SCKCaptureSourceListing().listShareableSources()
            guard let screen = CaptureCandidates.screens(from: raw).first else {
                fputs("No display to capture\n", stderr)
                exit(1)
            }
            print("VIDEO_SOURCE=\(screen.id.raw) — \(screen.title)")

            let meetingID = MeetingID()
            let dir = try files.ensureMeetingDirectory(for: meetingID)

            if play {
                Task.detached {
                    for _ in 0..<3 {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        let player = Process()
                        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                        player.arguments = ["-v", "0.4", "/System/Library/Sounds/Glass.aiff"]
                        try? player.run()
                        player.waitUntilExit()
                    }
                }
            }

            let window = CaptureCandidates.windows(from: raw, ownBundleIdentifier: nil)
                .filter(\.isOnScreen)
                .min { ($0.zOrder ?? .max) < ($1.zOrder ?? .max) }
            try await pipeline.start(meetingID: meetingID, video: screen.id, audio: audio, directory: dir)
            if lateVideo { try await pipeline.updateVideo(target: screen.id, live: false) }
            var levelMax: Float = 0
            let steps = lateVideo ? 130 : 40
            for step in 0..<steps {
                try await Task.sleep(nanoseconds: 100_000_000)
                levelMax = max(levelMax, await pipeline.currentLevels().system)
                if retarget, step == 12 {
                    try await pipeline.updateVideo(target: screen.id, live: false)
                    print("RETARGET held frames")
                }
                if retarget, step == 24, let window {
                    try await pipeline.updateVideo(target: window.id, live: true)
                    print("RETARGET moved to \(window.id.raw)")
                }
                if lateVideo, step == 110 {
                    try await pipeline.updateVideo(target: screen.id, live: true)
                    print("LATE_VIDEO frames resumed at 11 s")
                }
            }
            let health = await pipeline.health()
            print("HEALTH stopped=\(health.stoppedTracks.map(\.rawValue).sorted())")
            let counts = try await pipeline.stop()
            print(String(format: "SYSTEM_LEVEL_MAX=%.3f", levelMax))

            print("video=\(counts.video) mic=\(counts.mic) system=\(counts.system)")
            let systemPeak = peak(of: dir.appendingPathComponent(TrackKind.system.fileName))
            print(String(format: "SYSTEM_PEAK=%.4f", systemPeak))
            let durations = await (
                duration(of: dir.appendingPathComponent(TrackKind.video.fileName)),
                duration(of: dir.appendingPathComponent(TrackKind.system.fileName)),
                duration(of: dir.appendingPathComponent(TrackKind.mic.fileName))
            )
            print(String(format: "DURATIONS video=%.3f system=%.3f mic=%.3f", durations.0, durations.1, durations.2))
            print("ARTIFACT_DIR=\(dir.path)")

            var failed = false
            if !health.stoppedTracks.isEmpty { print("HEALTH: FAIL (a track reported stopped)"); failed = true }
            if counts.video <= 0 { print("VIDEO: FAIL"); failed = true } else { print("VIDEO: PASS") }
            print("MIC: \(counts.mic > 0 ? "PASS" : "EMPTY_OR_DENIED")")
            if abs(durations.0 - durations.1) > 0.1 || abs(durations.0 - durations.2) > 0.35 {
                print("ALIGN: FAIL (tracks do not share one timeline: video vs system ≤ 0.1 s, vs mic ≤ 0.35 s)")
                failed = true
            } else {
                print("ALIGN: PASS")
            }
            if expectSilentSystem {
                if systemPeak > 0.01 { print("SYSTEM: FAIL (expected silence — another app's sound leaked in)"); failed = true }
                else { print("SYSTEM: PASS (silent as expected)") }
            } else if play {
                if systemPeak <= 0.01 { print("SYSTEM: FAIL (played sound was not captured)"); failed = true }
                else { print("SYSTEM: PASS (captured played sound)") }
            } else {
                print("SYSTEM: \(counts.system > 0 ? "PASS" : "EMPTY")")
            }
            exit(failed ? 2 : 0)
        } catch {
            fputs("CaptureSmoke failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func duration(of url: URL) async -> Double {
        guard let time = try? await AVURLAsset(url: url).load(.duration) else { return 0 }
        return time.seconds
    }

    /// Peak absolute sample value (0…1) of an audio file; 0 when unreadable or empty.
    private static func peak(of url: URL) -> Float {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData
        else { return 0 }
        var maxValue: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) {
                maxValue = max(maxValue, abs(channels[c][i]))
            }
        }
        return maxValue
    }
}
