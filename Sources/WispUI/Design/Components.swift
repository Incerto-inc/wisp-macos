import SwiftUI

// MARK: - Buttons

/// Vermillion capsule: the only coloured control. "Start Recording" style actions.
struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            Circle().fill(Ink.onVermillion).frame(width: 9, height: 9)
            configuration.label
                .font(.wispTitle)
                .foregroundStyle(Ink.onVermillion)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.buttonHeight)
        .background(Capsule().fill(Ink.vermillionButton.opacity(configuration.isPressed ? 0.82 : 1)))
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
    }
}

/// Neutral capsule with a vermillion stop square — "Stop Recording".
struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Ink.vermillion).frame(width: 9, height: 9)
            configuration.label
                .font(.wispTitle)
                .foregroundStyle(Ink.text)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.buttonHeight)
        .background(Capsule().fill(configuration.isPressed ? Ink.fill3 : Ink.fill2))
        .overlay(Capsule().strokeBorder(Ink.separator, lineWidth: Metrics.hairline))
        .contentShape(Capsule())
    }
}

/// Full-width neutral capsule without the stop square ("Reopen Wisp").
struct NeutralCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.wispTitle)
            .foregroundStyle(Ink.text)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.buttonHeight)
            .background(Capsule().fill(configuration.isPressed ? Ink.fill3 : Ink.fill2))
            .overlay(Capsule().strokeBorder(Ink.separator, lineWidth: Metrics.hairline))
            .contentShape(Capsule())
    }
}

/// Small filled capsule in the text colour ("Allow…").
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Ink.panel)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(Ink.text.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

/// Text-only action in the secondary colour that brightens on hover ("Other Window ›", "Show All").
struct InkLinkButton: View {
    let title: String
    var chevron: Bool = false
    var font: Font = .wispLink
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .font(font)
            .foregroundStyle(hovering ? Ink.text : Ink.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 24pt round icon button (⋯, folder, trash).
struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 14
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(hovering ? Ink.text : Ink.secondary)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
                .background(Circle().fill(hovering ? Ink.fill2 : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Controls

/// Capsule segmented control in Ash & Ink (system segmented controls would bring their own blue/gray).
struct InkSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var fill: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Ink.text : Ink.secondary)
                        .padding(.horizontal, 11)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: 20)
                        .background(
                            Capsule()
                                .fill(selected ? Ink.segmentOn : .clear)
                                .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 1, y: 0.5)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Ink.fill2))
    }
}

struct InkSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Ink.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Ink.text)
                .focused(focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Ink.fill2))
    }
}

// MARK: - Small pieces

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.wispSection)
                .foregroundStyle(Ink.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 2)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Monochrome level bar (0…1).
struct LevelBar: View {
    let value: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.fill2)
                Capsule()
                    .fill(Ink.text.opacity(0.7))
                    .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.1), value: value)
        .accessibilityHidden(true)
    }
}

/// Filled check in the text colour with a panel-coloured glyph.
struct SelectionCheck: View {
    var body: some View {
        ZStack {
            Circle().fill(Ink.selection)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Ink.checkGlyph)
        }
        .frame(width: 17, height: 17)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
        .accessibilityHidden(true)
    }
}

struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(Ink.separator).frame(height: Metrics.hairline)
    }
}

/// One-sentence problem shown under the element it concerns (no red banners).
struct InlineNotice: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Ink.text)
            Text(text)
                .font(.wispCaption)
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Ink.fill2))
        .accessibilityElement(children: .combine)
    }
}

/// "● In call" — a small text-coloured dot, never green.
struct InCallLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Ink.text).frame(width: 6, height: 6)
            Text("In call")
        }
        .font(.wispCaption)
        .foregroundStyle(Ink.secondary)
    }
}
