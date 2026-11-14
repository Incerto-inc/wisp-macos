# Ambient / Room mode

Leave the laptop in a physical room and record surrounding conversation (offline meetings). **No screen capture.** Mic-only continuous session.

## Where it lives

Integrated as **Room** vs **Meeting** in the existing `wisp-macos` menu-bar app (same binary, shared Microphone TCC). A separate `wisp-ambient` app was skipped so permissions UX stays one place.

| Mode | Capture | Permissions | Disk |
| --- | --- | --- | --- |
| **Meeting** | SCK video + mic + system | Screen + Mic | `~/Movies/Wisp-macos/<uuid>/` |
| **Room** | Mic only (`MicOnlyAmbientPipeline`) | Mic only | `~/Movies/Wisp-macos/ambient/<uuid>/mic.m4a` |

Both modes share `index.json` at `~/Movies/Wisp-macos/index.json`. Rows carry `mode: "meeting" | "room"`.

## Architecture (hexagonal)

```
WispUI (Meeting | Room picker)
    → RecordingService.start / startRoom / stop
        → CapturePipeline (meeting)  or  AmbientMicPipeline (room)
        → MeetingRepository + MeetingFileStore (mode-aware paths)
WispDomain: CaptureMode, MeetingOutcome.fromAmbientMicBytes
```

- Domain owns outcome rules (Room succeeds iff `mic` bytes > 0).
- Application owns mutual exclusion (one session at a time across modes).
- `MicOnlyAmbientPipeline` (in `WispCapture`) is the Room adapter: the same `MicrophoneTrack` as meeting recordings (AAC, written in 10 s fragments so a long session survives a crash). Prefers stereo when the default input reports ≥2 channels; otherwise mono. Prefer an **omnidirectional / stereo** USB or laptop mic for room coverage (documented guidance — no auto device picker in MVP).

## How to run

```bash
cd wisp-macos
./Scripts/package-app.sh
open /Applications/Wisp.app
```

1. Click the menu-bar Wisp icon.
2. Pick **Room** in the **Meeting | Room** switch.
3. Allow the microphone if macOS asks → **Start Recording** → leave the laptop in the room → **Stop Recording**.
4. The session appears under **Recent**: click it to play `mic.m4a`, or use **Show in Finder** (it lives under `ambient/`).

Dev without packaging: `swift run Wisp` (TCC may attach to Terminal).

## Tests

```bash
swift test --filter MeetingOutcome
swift test --filter CaptureMode
swift test --filter RecordingService
```

## Out of scope (MVP+)

- Separate `~/Movies/Wisp-ambient` root (optional later)
- Auto-select omni hardware / multi-mic mix
- Background wake / sleep-proof long sessions
- Whisper / Drive upload
