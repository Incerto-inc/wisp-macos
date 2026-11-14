import AppKit
import SwiftUI
import WispDomain

struct PanelHeader: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        switch model.surface {
        case .choosing:
            TitledHeader(title: "Choose What to Record", back: model.back) { EmptyView() }
        case .detail(let meeting):
            TitledHeader(title: meeting.title, back: model.back) {
                Menu {
                    Button("Rename…") { model.isRenaming = true }
                    Button("Show in Finder") { Task { await model.reveal(meeting) } }
                    Divider()
                    Button("Delete…") { model.confirmingDelete = true }
                } label: {
                    MoreGlyph()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        default:
            MainHeader(model: model)
        }
    }
}

private struct MainHeader: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.text)
                .accessibilityHidden(true)
            Text("Wisp")
                .font(.wispTitle)
                .tracking(-0.13)
                .foregroundStyle(Ink.text)
            Spacer(minLength: 8)
            if model.surface == .recording {
                TimerLabel(elapsed: model.elapsed)
            } else {
                InkSegmented(
                    selection: Binding(get: { model.mode }, set: { mode in Task { await model.setMode(mode) } }),
                    options: [(CaptureMode.meeting, "Meeting"), (CaptureMode.room, "Room")]
                )
                .accessibilityLabel("Recording mode")
            }
            Menu {
                Button("Open Recordings Folder") { model.openRecordingsFolder() }
                Button("Privacy & Security Settings…") { model.openPrivacySettings() }
                Divider()
                Button(model.surface == .recording ? "Stop Recording and Quit" : "Quit Wisp") { NSApp.terminate(nil) }
            } label: {
                MoreGlyph()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .frame(height: 26)
    }
}

private struct MoreGlyph: View {
    @State private var hovering = false

    var body: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(hovering ? Ink.text : Ink.secondary)
            .frame(width: Metrics.minHit, height: Metrics.minHit)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct TitledHeader<Trailing: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        ZStack {
            Text(title)
                .font(.wispTitle)
                .foregroundStyle(Ink.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 210)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: back) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back").font(.wispBody)
                    }
                    .foregroundStyle(hovering ? Ink.text : Ink.secondary)
                    .frame(height: Metrics.minHit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .keyboardShortcut(.cancelAction)
                Spacer()
                trailing()
            }
        }
        .frame(height: 26)
    }
}

struct TimerLabel: View {
    let elapsed: TimeInterval

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Ink.vermillion).frame(width: 7, height: 7)
            Text(Self.format(elapsed))
                .font(.wispMono(13, weight: .semibold))
                .foregroundStyle(Ink.vermillion)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(Self.format(elapsed))")
    }

    static func format(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded(.down)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
