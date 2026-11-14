import SwiftUI
import WispDomain

/// Ready (Meeting): the two likely targets, Other Window, audio, Start, Recent.
struct ReadyMeetingView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Record") {
                if model.choices != nil, model.choices?.inCallMeeting == nil {
                    Text("No meeting detected")
                        .font(.wispCaption)
                        .foregroundStyle(Ink.secondary)
                }
            }
            .padding(.bottom, 7)

            if let choices = model.choices {
                HStack(alignment: .top, spacing: Metrics.gap) {
                    card(choices.primary, choices: choices)
                    if let secondary = choices.secondary {
                        card(secondary, choices: choices)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            } else {
                Text("Nothing to record yet. Open the window you want, then reopen Wisp.")
                    .font(.wispCaptionLarge)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
            }

            InkLinkButton(title: "Other Window", chevron: true) { model.showPicker() }
                .padding(.top, 9)
                .padding(.leading, 3)
                .disabled(model.candidates == .empty)

            AudioRow(model: model).padding(.top, 10)

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

    @ViewBuilder
    private func card(_ source: CaptureSource, choices: RecordChoices) -> some View {
        let selected = model.selectedID == source.id
        let isMeeting = source.id == choices.inCallMeeting?.id
        if source.kind == .screen {
            let subtitle = choices.inCallMeeting == nil ? source.title : "When you present"
            SourceCard(source: source, title: "Entire Screen", subtitle: subtitle, selected: selected) {
                model.select(source.id)
            }
        } else if isMeeting {
            SourceCard(
                source: source,
                title: CaptureSourceLabel.title(source),
                selected: selected,
                accessibilityDetail: SourceDetail.accessibilityText(source),
                action: { model.select(source.id) },
                detail: { InCallLabel() }
            )
        } else {
            SourceCard(
                source: source,
                title: CaptureSourceLabel.title(source),
                subtitle: CaptureSourceLabel.subtitle(source),
                selected: selected
            ) {
                model.select(source.id)
            }
        }
    }
}
