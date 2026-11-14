import SwiftUI
import WispDomain

/// Recording: what is being captured, whether sound is arriving, and Stop.
struct RecordingView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let source = model.recordingSource {
                SourceThumbnail(
                    source: source,
                    previewID: model.recordingPreviewID,
                    placeholderLabel: model.videoTarget?.isLive == false ? "Tab not showing" : nil
                )
                    .overlay(alignment: .topLeading) { RecBadge().padding(7) }
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .strokeBorder(Ink.vermillion.opacity(0.65), lineWidth: 1.5)
                    )
                HStack(spacing: 6) {
                    SourceIcon(source: source)
                    Text(source.kind == .screen ? "Entire Screen" : CaptureSourceLabel.title(source))
                        .font(.wispTitle)
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                }
                .padding(.top, 9)
                .padding(.horizontal, 2)
                Text("Recording video, \(model.recordingAudio?.displayName ?? "system") audio and microphone")
                    .font(.wispCaption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
                    .padding(.leading, 24)
                    .padding(.top, 2)
            } else {
                HStack(spacing: 10) {
                    IconTile(systemName: "mic.fill")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Room recording").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.text)
                        Text(model.inputDeviceName).font(.wispCaption).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    RecBadge()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Ink.fill1))
            }

            VStack(spacing: 9) {
                MeterRow(label: "Microphone", value: model.levels.mic) {
                    Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(Ink.secondary).frame(width: 16)
                }
                if model.recordingSource != nil {
                    MeterRow(label: model.recordingAudio?.displayName ?? "System", value: model.levels.system) {
                        audioIcon
                    }
                    if model.silentAudio, model.stoppedTracksText == nil {
                        InlineNotice(text: "No sound from \(model.recordingAudio?.displayName ?? "the meeting") for 30 s. Is it muted?")
                    }
                }
                // Meeting and Room alike: a track that stopped matters more than silence.
                if let stopped = model.stoppedTracksText {
                    InlineNotice(text: stopped)
                }
            }
            .padding(.top, 12)

            Button("Stop Recording") { Task { await model.stopRecording() } }
                .buttonStyle(StopButtonStyle())
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var audioIcon: some View {
        if case .application(let bundle, _) = model.recordingAudio, let icon = AppIconCache.icon(for: bundle) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(Ink.secondary).frame(width: 16)
        }
    }
}

private struct MeterRow<Icon: View>: View {
    let label: String
    let value: Float
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                icon()
                Text(label).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            .frame(width: 112, alignment: .leading)
            LevelBar(value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

struct RecBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Ink.onVermillion).frame(width: 5, height: 5)
            Text("REC").font(.wispMono(10, weight: .bold))
        }
        .foregroundStyle(Ink.onVermillion)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: Metrics.badgeRadius, style: .continuous).fill(Ink.vermillionButton))
        .accessibilityLabel("Recording")
    }
}

struct IconTile: View {
    let systemName: String

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Ink.fill2)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.text)
            }
            .accessibilityHidden(true)
    }
}
