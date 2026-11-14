import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WispApplication
import WispDomain
import WispUI

/// Renders every panel state in dark and light appearance to PNG, offscreen (no window is ever shown).
///
///   swift run panel-snapshots <output-dir>
@main
@MainActor
enum PanelSnapshots {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "panel-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for (name, state) in Fixtures.states() {
            for dark in [true, false] {
                let file = out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                render(state, dark: dark, to: file)
            }
        }
        print("wrote \(Fixtures.states().count * 2) snapshots to \(out.path)")
    }

    static func render(_ state: PanelPreviewState, dark: Bool, to url: URL) {
        let model = PanelModel(
            recording: RecordingService(
                sources: NoListing(), pipeline: NoPipeline(), ambient: NoAmbient(), meetings: NoRepo(), files: NoFiles()
            ),
            thumbnails: nil,
            permissions: Granted(),
            mediaRoot: FileManager.default.temporaryDirectory,
            startsTicks: false
        )
        model.applyPreview(state)

        // PANEL_SNAPSHOT_TRANSPARENT=1 leaves out the backdrop (for the website, which supplies its own).
        let transparent = ProcessInfo.processInfo.environment["PANEL_SNAPSHOT_TRANSPARENT"] == "1"
        let root = ZStack(alignment: .topTrailing) {
            if transparent {
                Color.clear
            } else {
                LinearGradient(
                colors: dark
                    ? [Color(red: 0.16, green: 0.155, blue: 0.15), Color(red: 0.07, green: 0.067, blue: 0.063)]
                    : [Color(red: 0.85, green: 0.835, blue: 0.81), Color(red: 0.73, green: 0.71, blue: 0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
                )
            }
            MenuBarPanel(model: model).padding(20)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 1200)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let height = ceil(hosting.fittingSize.height)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: max(200, height))
        window.setContentSize(hosting.frame.size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// MARK: - Fixtures

@MainActor
enum Fixtures {
    static let zoom = CaptureSource(id: CaptureSourceID("window:1"), kind: .window, title: "Zoom Meeting", applicationName: "zoom.us", bundleIdentifier: "us.zoom.xos", zOrder: 2)
    static let meet = CaptureSource(id: CaptureSourceID("window:2"), kind: .window, title: "Meet – abc-defg-hij", applicationName: "Google Chrome", bundleIdentifier: "com.google.Chrome", isOnScreen: false)
    static let keynote = CaptureSource(id: CaptureSourceID("window:3"), kind: .window, title: "Q4 Roadmap.key", applicationName: "Keynote", bundleIdentifier: "com.apple.iWork.Keynote", zOrder: 0)
    static let notion = CaptureSource(id: CaptureSourceID("window:4"), kind: .window, title: "議事録 – Notion", applicationName: "Notion", bundleIdentifier: "notion.id", zOrder: 1)
    static let slack = CaptureSource(id: CaptureSourceID("window:5"), kind: .window, title: "#product – Slack", applicationName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", zOrder: 3)
    static let terminal = CaptureSource(id: CaptureSourceID("window:6"), kind: .window, title: "wisp-macos — zsh", applicationName: "Terminal", bundleIdentifier: "com.apple.Terminal", zOrder: 4)
    static let longTitle = CaptureSource(id: CaptureSourceID("window:7"), kind: .window, title: "2026年度 第3四半期 全社ロードマップ説明会（最終版・社外秘）", applicationName: "Keynote", bundleIdentifier: "com.apple.iWork.Keynote", zOrder: 0)
    static let display = CaptureSource(id: CaptureSourceID("screen:1"), kind: .screen, title: "Built-in Retina Display")

    // Browser tabs: one Chrome window whose shown tab is a document; the Meet call is in the background.
    static let chromeBundle = "com.google.Chrome"
    static let chromeFrame = CaptureRect(x: 0, y: 25, width: 1280, height: 800)
    static let chromeWindow = CaptureSource(
        id: CaptureSourceID("window:20"), kind: .window, title: "Q4 Roadmap – Google Docs",
        applicationName: "Google Chrome", bundleIdentifier: chromeBundle,
        size: CaptureSize(width: chromeFrame.width, height: chromeFrame.height), zOrder: 0, frame: chromeFrame
    )
    static let chromeSnapshot = BrowserSnapshot(bundleIdentifier: chromeBundle, name: "Google Chrome", windows: [
        BrowserWindowSnapshot(
            key: "1", index: 1, title: chromeWindow.title, bounds: chromeFrame, isPrivate: false, activeTabKey: "2",
            tabs: [
                BrowserTabSnapshot(key: "1", title: "Meet – abc-defg-hij", url: "https://meet.google.com/abc-defg-hij"),
                BrowserTabSnapshot(key: "2", title: "Q4 Roadmap – Google Docs", url: "https://docs.google.com/document/d/1x"),
                BrowserTabSnapshot(key: "3", title: "Pull requests · Incerto-inc/wisp-macos", url: "https://github.com/Incerto-inc/wisp-macos/pulls"),
                BrowserTabSnapshot(key: "4", title: "2026年度 第3四半期 全社ロードマップ説明会（最終版・社外秘）– Notion", url: "https://www.notion.so/acme/roadmap"),
                BrowserTabSnapshot(key: "5", title: "Inbox (3) – Gmail", url: "https://mail.google.com/mail/u/0/#inbox"),
            ]
        ),
    ])
    static let tabs = CaptureCandidates.tabs(from: BrowserTabs.sources(from: [chromeSnapshot], windows: [chromeWindow]))
    static let meetTab = tabs[0]
    static let tabAccess = [
        BrowserTabStatus(bundleIdentifier: chromeBundle, name: "Google Chrome", access: .granted),
        BrowserTabStatus(bundleIdentifier: "com.apple.Safari", name: "Safari", access: .notDetermined),
        BrowserTabStatus(bundleIdentifier: "company.thebrowser.Browser", name: "Arc", access: .denied),
    ]

    static let meetings: [Meeting] = {
        let now = Date()
        return [
            Meeting(title: "Weekly sync", status: .completed, startedAt: now.addingTimeInterval(-90_000), endedAt: now.addingTimeInterval(-87_480), sourceLabel: "Zoom Meeting"),
            Meeting(title: "Design review", status: .completed, startedAt: now.addingTimeInterval(-260_000), endedAt: now.addingTimeInterval(-258_920), sourceLabel: "Meet – abc-defg-hij"),
            Meeting(title: "Room · Nov 13 14:02", status: .completed, startedAt: now.addingTimeInterval(-300_000), endedAt: now.addingTimeInterval(-296_100), sourceLabel: "Room mic", mode: .room),
        ]
    }()

    static var thumbs: [CaptureSourceID: CGImage] {
        [
            zoom.id: Art.gallery(tiles: 4, background: 0x0E0E10),
            meet.id: Art.gallery(tiles: 2, background: 0x202124, controls: true),
            keynote.id: Art.slide(),
            longTitle.id: Art.slide(),
            notion.id: Art.document(),
            slack.id: Art.chat(),
            terminal.id: Art.terminal(),
            display.id: Art.desktop(),
            chromeWindow.id: Art.document(),
        ]
    }

    static func states() -> [(String, PanelPreviewState)] {
        func ordered(_ windows: [CaptureSource]) -> [CaptureSource] {
            CaptureCandidates.windows(from: windows, ownBundleIdentifier: nil)
        }
        let all = CaptureCandidateSet(windows: ordered([zoom, keynote, notion, slack, terminal, meet]), screens: [display])
        var list: [(String, PanelPreviewState)] = []

        var ready = PanelPreviewState(surface: .ready)
        ready.candidates = all
        ready.meetings = meetings
        ready.thumbnails = thumbs
        list.append(("01-ready-meeting", ready))

        var noMeeting = ready
        noMeeting.candidates = CaptureCandidateSet(windows: ordered([keynote, notion, slack]), screens: [display])
        list.append(("02-ready-no-meeting", noMeeting))

        var long = ready
        long.candidates = CaptureCandidateSet(windows: ordered([zoom, longTitle]), screens: [display])
        long.pinned = longTitle
        long.selectedID = longTitle.id
        long.inlineError = "That window is no longer available. Pick another one."
        list.append(("03-ready-long-title-error", long))

        var choosing = ready
        choosing.surface = .choosing
        list.append(("04-choosing", choosing))

        var searching = ready
        searching.surface = .choosing
        searching.search = "ke"
        list.append(("05-choosing-search", searching))

        var recording = ready
        recording.surface = .recording
        recording.recordingSource = zoom
        recording.recordingAudio = .application(bundleIdentifier: "us.zoom.xos", name: "zoom.us")
        recording.elapsed = 754
        recording.levels = CaptureLevels(mic: 0.58, system: 0.34)
        list.append(("06-recording", recording))

        var silent = recording
        silent.recordingSource = keynote
        silent.levels = CaptureLevels(mic: 0.5, system: 0)
        silent.silentAudio = true
        list.append(("07-recording-silent", silent))
        var stopped = recording
        stopped.levels = CaptureLevels(mic: 0.5, system: 0.3)
        stopped.stoppedTracks = [.video]
        list.append(("15-recording-capture-stopped", stopped))

        var room = ready
        room.mode = .room
        list.append(("08-room", room))

        var permissions = PanelPreviewState(surface: .permissions)
        permissions.screenGranted = false
        permissions.micGranted = true
        permissions.needsRelaunch = true
        list.append(("09-permissions", permissions))

        var detail = ready
        detail.surface = .detail(meetings[0])
        detail.detailFiles = RecordingFiles(
            video: URL(fileURLWithPath: "/nonexistent/video.mov"),
            mic: URL(fileURLWithPath: "/nonexistent/mic.m4a"),
            system: URL(fileURLWithPath: "/nonexistent/system.m4a")
        )
        list.append(("10-detail", detail))

        // Browser tabs. The Meet tab is in a call but not the tab its window shows.
        let withTabs = CaptureCandidateSet(
            windows: ordered([chromeWindow, keynote, notion, slack]),
            screens: [display],
            tabs: tabs,
            tabAccess: tabAccess
        )
        var tabReady = ready
        tabReady.candidates = withTabs
        list.append(("11-ready-background-tab", tabReady))

        var tabList = tabReady
        tabList.surface = .choosing
        tabList.pickerTab = .tabs
        list.append(("12-choosing-tabs", tabList))

        var tabSearch = tabList
        tabSearch.search = "figma"
        list.append(("13-choosing-tabs-no-match", tabSearch))

        var tabHidden = tabReady
        tabHidden.surface = .recording
        tabHidden.recordingSource = meetTab
        tabHidden.recordingAudio = .allApplications
        tabHidden.videoTarget = VideoTarget(source: chromeWindow.id, isLive: false)
        tabHidden.elapsed = 1_312
        tabHidden.levels = CaptureLevels(mic: 0.42, system: 0.28)
        list.append(("14-recording-tab-hidden", tabHidden))
        return list
    }
}

// MARK: - Fake window art (thumbnails)

enum Art {
    private static func context() -> CGContext {
        CGContext(data: nil, width: 480, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func fill(_ ctx: CGContext, _ hex: UInt32, _ rect: CGRect, radius: CGFloat = 0) {
        ctx.setFillColor(color(hex))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    static func gallery(tiles: Int, background: UInt32, controls: Bool = false) -> CGImage {
        let ctx = context()
        fill(ctx, background, CGRect(x: 0, y: 0, width: 480, height: 300))
        let palette: [UInt32] = [0x3D4A5C, 0x4B3F5E, 0x3B5A4C, 0x5A4A3B]
        if tiles == 4 {
            for i in 0..<4 {
                let x = CGFloat(i % 2) * 232 + 12
                let y = CGFloat(i / 2) * 140 + 12
                fill(ctx, palette[i], CGRect(x: x, y: y, width: 224, height: 132), radius: 6)
            }
        } else {
            fill(ctx, palette[0], CGRect(x: 14, y: 54, width: 270, height: 232), radius: 6)
            fill(ctx, palette[3], CGRect(x: 294, y: 54, width: 172, height: 232), radius: 6)
            if controls {
                for i in 0..<4 {
                    fill(ctx, i == 2 ? 0xEA4335 : 0x3C4043, CGRect(x: 178 + CGFloat(i) * 32, y: 16, width: i == 2 ? 36 : 24, height: 20), radius: 10)
                }
            }
        }
        return ctx.makeImage()!
    }

    static func slide() -> CGImage {
        let ctx = context()
        fill(ctx, 0x2B2B2E, CGRect(x: 0, y: 0, width: 480, height: 300))
        fill(ctx, 0xFAFAFA, CGRect(x: 48, y: 30, width: 384, height: 240), radius: 3)
        fill(ctx, 0x1D1D1F, CGRect(x: 80, y: 206, width: 220, height: 26), radius: 2)
        for (i, w) in [300, 250, 200].enumerated() {
            fill(ctx, 0xC7C7CC, CGRect(x: 80, y: 160 - CGFloat(i) * 30, width: CGFloat(w), height: 12), radius: 2)
        }
        return ctx.makeImage()!
    }

    static func document() -> CGImage {
        let ctx = context()
        fill(ctx, 0xFFFFFF, CGRect(x: 0, y: 0, width: 480, height: 300))
        fill(ctx, 0x1D1D1F, CGRect(x: 52, y: 238, width: 220, height: 24), radius: 2)
        for i in 0..<6 {
            fill(ctx, 0xD1D1D6, CGRect(x: 52, y: 196 - CGFloat(i) * 30, width: CGFloat([376, 340, 360, 300, 350, 220][i]), height: 11), radius: 2)
        }
        return ctx.makeImage()!
    }

    static func chat() -> CGImage {
        let ctx = context()
        fill(ctx, 0x1A1D21, CGRect(x: 0, y: 0, width: 480, height: 300))
        fill(ctx, 0x3F0E40, CGRect(x: 0, y: 0, width: 120, height: 300))
        for i in 0..<6 {
            fill(ctx, 0x3A3D42, CGRect(x: 144, y: 250 - CGFloat(i) * 42, width: CGFloat(i % 2 == 0 ? 300 : 220), height: 14), radius: 3)
        }
        return ctx.makeImage()!
    }

    static func terminal() -> CGImage {
        let ctx = context()
        fill(ctx, 0x111214, CGRect(x: 0, y: 0, width: 480, height: 300))
        for i in 0..<7 {
            fill(ctx, i % 2 == 0 ? 0x2F8F4E : 0x55575C, CGRect(x: 28, y: 260 - CGFloat(i) * 36, width: CGFloat(i % 2 == 0 ? 180 : 330), height: 12), radius: 2)
        }
        return ctx.makeImage()!
    }

    static func desktop() -> CGImage {
        let ctx = context()
        let colors = [color(0x5A6F9E), color(0x232A40), color(0x12141B)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 480, y: 0), options: [])
        fill(ctx, 0x0E0E10, CGRect(x: 36, y: 110, width: 220, height: 150), radius: 5)
        fill(ctx, 0xF5F5F5, CGRect(x: 210, y: 40, width: 230, height: 150), radius: 5)
        return ctx.makeImage()!
    }
}

// MARK: - Inert ports (the preview state drives everything)

private struct NoListing: CaptureSourceListing {
    func listShareableSources() async throws -> [CaptureSource] { [] }
}

private struct NoPipeline: CapturePipeline {
    func start(meetingID: MeetingID, video: CaptureSourceID, audio: AudioSource, directory: URL, startsLive: Bool) async throws {}
    func updateVideo(target: CaptureSourceID, live: Bool) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 0, mic: 0, system: 0) }
    func currentLevels() async -> CaptureLevels { .silent }
}

private struct NoAmbient: AmbientMicPipeline {
    func start(meetingID: MeetingID, directory: URL) async throws {}
    func stop() async throws -> TrackByteCounts { TrackByteCounts(video: 0, mic: 0, system: 0) }
    func currentLevels() async -> CaptureLevels { .silent }
}

private actor NoRepo: MeetingRepository {
    func insert(_ meeting: Meeting) async throws {}
    func update(_ meeting: Meeting) async throws {}
    func fetch(id: MeetingID) async throws -> Meeting? { nil }
    func listRecent(limit: Int) async throws -> [Meeting] { [] }
    func delete(id: MeetingID) async throws {}
}

private struct NoFiles: MeetingFileStore {
    func meetingDirectory(for id: MeetingID) throws -> URL { FileManager.default.temporaryDirectory }
    func ensureMeetingDirectory(for id: MeetingID) throws -> URL { FileManager.default.temporaryDirectory }
    func removeMeetingDirectory(for id: MeetingID) throws {}
    func directory(for id: MeetingID, mode: CaptureMode) throws -> URL { FileManager.default.temporaryDirectory }
    func ensureDirectory(for id: MeetingID, mode: CaptureMode) throws -> URL { FileManager.default.temporaryDirectory }
}

private struct Granted: PermissionChecking {
    var screenGranted: Bool { true }
    var microphoneGranted: Bool { true }
}
