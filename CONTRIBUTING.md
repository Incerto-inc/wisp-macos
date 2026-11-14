# Contributing

Thanks for helping. Bug reports, fixes and small focused pull requests are all welcome. For a
larger change, open an issue first so we can agree on the approach. For security problems,
follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Build and run

You need macOS 14 or later and Xcode 16.4 or later (Swift 6). There are no third-party
dependencies.

```bash
swift build                    # every target, debug
swift test                     # all unit tests; no permissions or display needed
./Scripts/package-app.sh       # release .app, installed as /Applications/Wisp.app
WISP_SKIP_APPLICATIONS_INSTALL=1 ./Scripts/package-app.sh   # build .build/Wisp.app only
```

Run the app from the `.app` bundle. `swift run Wisp` works, but macOS then gives the
permissions to your terminal.

**Signing and permissions.** macOS remembers Screen Recording, Microphone and Automation
permission per code signature. `package-app.sh` signs with the first "Apple Development"
certificate in your keychain (set `WISP_CODESIGN_IDENTITY` to choose another). Without one it
signs ad-hoc, and macOS forgets the permissions on every rebuild. A free Apple Developer
account gives you an Apple Development certificate through Xcode.

**Icons.** `Scripts/make-icon.sh` and `Scripts/make-tray-icon.sh` regenerate the app icon and
the menu-bar glyph; both need ImageMagick (`magick`).

## How we work

- **Test first.** Write a failing test, watch it fail, write the smallest code that passes,
  then tidy up. Every domain rule (what is recordable, ordering, meeting detection, outcomes,
  tab matching) has a unit test in `Tests/WispDomainTests`. Service behaviour is tested in
  `Tests/WispApplicationTests` with fakes for the ports and real temporary folders.
- **Fakes only at the ports.** Use real objects elsewhere. Nothing in `swift test` may need a
  permission, a display or the network.
- **Keep the layers.** `WispDomain` imports Foundation only. ScreenCaptureKit types stay inside
  `WispCapture`. Business rules go in the domain or `RecordingService`, not in views or
  `main.swift`. See [ARCHITECTURE.md](ARCHITECTURE.md).
- **No new dependencies** without discussing it in an issue first.
- **Nothing leaves the Mac.** Wisp makes no network requests. Do not log window titles, tab
  titles or addresses.

## Style

- Swift 6 language mode with strict concurrency. `swift build` must produce no warnings.
- Match the surrounding code: 4-space indentation, `///` comments that say why, small types
  with descriptive names. An `@unchecked Sendable` needs a comment saying what makes it safe.
- UI copy is short and plain. Buttons and titles use title case as macOS does ("Start
  Recording"). The panel is 360 points wide: labels, not explanations.
- The look is "Ash & Ink" (`Sources/WispUI/Design`): warm greys for everything, vermilion
  only for what is being recorded, no other accent colours, and no pure white or pure black
  text. Use the tokens in `Palette.swift` and `Metrics.swift` rather than literal colours or
  sizes; text contrast is pinned by tests in both appearances.
- Commit messages: a short summary line in the imperative, then why the change was needed.

## Checking the panel: `panel-snapshots`

```bash
swift run panel-snapshots /tmp/wisp-snaps
```

Renders every panel state in dark and light appearance to PNG files, offscreen (no window
appears). The states and their sample data are fixtures in `Tools/PanelSnapshots/main.swift`;
add one when you add a state. For UI changes, compare the images before and after and attach
the relevant ones to your pull request. The README screenshots in `docs/images/` come from this
tool (`01-ready-meeting`, `04-choosing`, `12-choosing-tabs`, `06-recording`), and so do the
website's (`site/images/`, rendered with `PANEL_SNAPSHOT_TRANSPARENT=1`).

## Driving the installed app from scripts

For checks against the real app, Wisp listens for a few distributed notifications
(`tech.incerto.wisp.mac.qa.showPanel`, `.hidePanel`, `.previewFrame`, `.openFirstMeeting`). They are
off by default, because any process on the Mac can post them. Turn them on with
`defaults write tech.incerto.wisp.mac WispQAHooks -bool true` and relaunch Wisp (or run it with
`WISP_QA=1`); turn them off again with `defaults delete tech.incerto.wisp.mac WispQAHooks`.

## Checking real capture: `capture-smoke`

`capture-smoke` runs the capture code against the real ScreenCaptureKit. It needs Screen
Recording and Microphone permission for your terminal, so it is not part of `swift test` or CI.
Run the relevant checks when you change anything in `WispCapture`.

```bash
swift run capture-smoke --list            # recordable windows and displays, with display names
swift run capture-smoke --tabs            # browsers Wisp could read tabs from: access and counts only
swift run capture-smoke --play            # 4 s of display + mic + system audio, with a sound playing
swift run capture-smoke --play --audio-app com.apple.finder --expect-silent-system
                                          # system audio limited to one app
swift run capture-smoke --retarget        # hold frames, then move the video to another window
swift run capture-smoke --late-video      # video starts 11 s late; tracks must stay aligned
swift run capture-smoke --crash-after 13   # record, then SIGKILL itself; prints ARTIFACT_DIR
swift run capture-smoke --inspect <dir>   # duration and playability of each track (all three should play)
swift run capture-smoke --thumbs /tmp/thumbs   # thumbnails for the picker
```

`--tabs` never prints tab titles or addresses, never asks for access and never switches tabs.

## The website

`site/` is the project website: static HTML and CSS with no build step and nothing loaded
from other servers. Open `site/index.html` (and `site/ja/index.html`) in a browser to preview
it. The panel images come from `PANEL_SNAPSHOT_TRANSPARENT=1 swift run panel-snapshots <dir>`.
Pushing changes under `site/` to `main` publishes it with GitHub Pages once the repository is
public (`.github/workflows/pages.yml`).

## Continuous integration

`.github/workflows/ci.yml` runs `swift build` and `swift test` on GitHub's macOS runners with
the oldest supported Xcode (16.4) and the current one, and checks that `package-app.sh` builds
a valid, ad-hoc signed app without installing it.
