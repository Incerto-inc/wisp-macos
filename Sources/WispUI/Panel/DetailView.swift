import SwiftUI
import WispDomain

/// A recording opened from Recent, inside the same panel.
struct DetailView: View {
    @ObservedObject var model: PanelModel
    let meeting: Meeting
    @StateObject private var playback = SyncedPlaybackController()
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isRenaming {
                HStack(spacing: 8) {
                    TextField("Title", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.wispBody)
                        .foregroundStyle(Ink.text)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Ink.fill2))
                        .focused($titleFocused)
                        .onSubmit(commitRename)
                    Button("Save", action: commitRename)
                        .buttonStyle(PillButtonStyle())
                }
                .padding(.bottom, 10)
                .onAppear {
                    draft = meeting.title
                    titleFocused = true
                }
            }

            if let files = model.detailFiles {
                Group {
                    if files.video != nil {
                        AVPlayerViewRepresentable(player: playback.videoPlayer)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    } else {
                        AVPlayerViewRepresentable(player: playback.primaryAudioPlayer)
                            .frame(height: 56)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Ink.separator, lineWidth: Metrics.hairline))

                Text(metaLine)
                    .font(.wispMono(10.5))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .padding(.top, 9)
                    .padding(.horizontal, 2)

                if files.video != nil, files.mic != nil || files.system != nil {
                    VStack(spacing: 8) {
                        if files.mic != nil {
                            TrackRow(label: "Microphone", systemName: "mic.fill", muted: $playback.micMuted, volume: $playback.micVolume)
                        }
                        if files.system != nil {
                            TrackRow(label: "System", systemName: "speaker.wave.2.fill", muted: $playback.systemMuted, volume: $playback.systemVolume)
                        }
                    }
                    .padding(.top, 10)
                }
            }

            HairlineDivider()
                .padding(.horizontal, -Metrics.padding)
                .padding(.top, 12)
            HStack {
                InkLinkButton(title: "Show in Finder") { Task { await model.reveal(meeting) } }
                Spacer()
                if model.confirmingDelete {
                    Button("Delete") { Task { await model.delete(meeting) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.text)
                    Button("Cancel") { model.confirmingDelete = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                } else {
                    InkLinkButton(title: "Delete…") { model.confirmingDelete = true }
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 2)
        }
        .onAppear { if let files = model.detailFiles { playback.load(files: files) } }
        .onDisappear { playback.tearDown() }
    }

    private var metaLine: String {
        let when = meeting.startedAt.formatted(date: .abbreviated, time: .shortened)
        var parts = [when]
        if let ended = meeting.endedAt { parts.append(RecentFormat.duration(ended.timeIntervalSince(meeting.startedAt))) }
        if let source = meeting.sourceLabel, !source.isEmpty, source != meeting.title { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    private func commitRename() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.isRenaming = false
        guard !title.isEmpty, title != meeting.title else { return }
        Task { await model.rename(meeting, to: title) }
    }
}

private struct TrackRow: View {
    let label: String
    let systemName: String
    @Binding var muted: Bool
    @Binding var volume: Float

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemName).font(.system(size: 11)).foregroundStyle(Ink.secondary).frame(width: 16)
                Text(label).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            .frame(width: 104, alignment: .leading)
            Button {
                muted.toggle()
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(muted ? Ink.tertiary : Ink.secondary)
                    .frame(width: 18, height: Metrics.minHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? "Unmute \(label)" : "Mute \(label)")
            Slider(value: Binding(get: { Double(volume) }, set: { volume = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .tint(Ink.text)
                .disabled(muted)
                .accessibilityLabel("\(label) volume")
        }
    }
}
