import SwiftUI
import WispDomain

/// Ready (Room): the microphone that will record, Start, Recent.
struct RoomView: View {
    @ObservedObject var model: PanelModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Record").padding(.bottom, 7)
            Menu {
                Button("Sound Settings…") { model.openSoundSettings() }
            } label: {
                HStack(spacing: 10) {
                    IconTile(systemName: "mic.fill")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.inputDeviceName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                        Text("Records the room. No screen.")
                            .font(.wispCaption)
                            .foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(hovering ? Ink.fill2 : Ink.fill1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Microphone: \(model.inputDeviceName)")

            Button("Start Recording") { Task { await model.startRecording() } }
                .buttonStyle(RecordButtonStyle())
                .disabled(!model.canStart)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 12)

            if let message = model.inlineError ?? model.notice {
                InlineNotice(text: message).padding(.top, 8)
            }

            RecentSection(model: model).padding(.top, 12)
        }
    }
}

/// First run / missing grants. Plain words, one action per missing permission.
struct PermissionsView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Before you record")
                .font(.wispHeadline)
                .tracking(-0.15)
                .foregroundStyle(Ink.text)
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            Text(model.mode == .room
                ? "Wisp needs your microphone. Recordings stay on this Mac."
                : "Wisp needs two permissions. Recordings stay on this Mac.")
                .font(.wispCaptionLarge)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .padding(.top, 3)

            VStack(spacing: 0) {
                if model.mode == .meeting {
                    PermissionRow(
                        systemName: "display",
                        title: "Screen & System Audio",
                        detail: "To record the meeting window and its sound",
                        granted: model.screenGranted
                    ) { model.requestScreenPermission() }
                    HairlineDivider()
                }
                PermissionRow(
                    systemName: "mic.fill",
                    title: "Microphone",
                    detail: "To record your voice",
                    granted: model.micGranted
                ) { Task { await model.requestMicrophonePermission() } }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Ink.fill1))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .padding(.top, 12)

            if model.mode == .meeting, !model.screenGranted {
                Text("macOS asks you to reopen Wisp after you allow screen recording.")
                    .font(.wispCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.top, 10)
                if model.needsRelaunch {
                    Button("Reopen Wisp") { model.relaunch() }
                        .buttonStyle(NeutralCapsuleButtonStyle())
                        .padding(.top, 10)
                }
            }

            InkLinkButton(title: "Having trouble? Read the guide", chevron: true) { model.openPermissionsGuide() }
                .padding(.top, 10)
                .padding(.leading, 2)
        }
    }
}

private struct PermissionRow: View {
    let systemName: String
    let title: String
    let detail: String
    let granted: Bool
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: systemName)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.text)
                Text(detail).font(.wispCaption).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Allow…", action: allow).buttonStyle(PillButtonStyle())
            }
        }
        .padding(10)
        .accessibilityElement(children: .combine)
    }
}
