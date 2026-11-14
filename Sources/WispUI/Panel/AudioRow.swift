import SwiftUI
import WispDomain

/// "Zoom + MacBook Pro Microphone" — where the two audio tracks come from; the menu changes the app side.
struct AudioRow: View {
    @ObservedObject var model: PanelModel
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Record sound from") {
                // A meeting in a browser tab plays through helper processes, so only All apps records it.
                if let meeting = model.choices?.inCallMeeting, meeting.kind != .tab, let bundle = meeting.bundleIdentifier {
                    let appAudio = AudioSource.application(bundleIdentifier: bundle, name: meeting.applicationName ?? bundle)
                    Toggle("Meeting app (\(appAudio.displayName))", isOn: Binding(
                        get: { model.effectiveAudio == appAudio },
                        set: { _ in model.audioOverride = appAudio }
                    ))
                }
                Toggle("All apps", isOn: Binding(
                    get: { model.effectiveAudio == .allApplications },
                    set: { _ in model.audioOverride = .allApplications }
                ))
            }
            Divider()
            Button("Sound Settings…") { model.openSoundSettings() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 14)
                (Text(model.effectiveAudio.displayName).foregroundStyle(Ink.text)
                    + Text("  +  ").foregroundStyle(Ink.secondary)
                    + Text(model.inputDeviceName).foregroundStyle(Ink.text))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Ink.fill2 : Ink.fill1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Audio: \(model.effectiveAudio.displayName) and \(model.inputDeviceName)")
    }
}
