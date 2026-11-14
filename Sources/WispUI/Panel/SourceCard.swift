import AppKit
import SwiftUI
import WispDomain

/// Real app icons from Launch Services, cached per bundle id.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let cached = cache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleIdentifier] = icon
        return icon
    }
}

/// An app's icon at `size`; a neutral window glyph when the app cannot be found.
struct AppIcon: View {
    let bundleIdentifier: String?
    var size: CGFloat = 16

    var body: some View {
        if let icon = AppIconCache.icon(for: bundleIdentifier) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: size * 0.75))
                .foregroundStyle(Ink.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// A display glyph for screens; the owning app's icon (the browser's, for tabs) otherwise.
struct SourceIcon: View {
    let source: CaptureSource
    var size: CGFloat = 16

    var body: some View {
        if source.kind == .screen {
            Image(systemName: "display")
                .font(.system(size: size * 0.8, weight: .regular))
                .foregroundStyle(Ink.secondary)
                .frame(width: size, height: size)
        } else {
            AppIcon(bundleIdentifier: source.bundleIdentifier, size: size)
        }
    }
}

/// 16:10 preview of a window or screen. Without a picture (none yet, or a tab that is not the one
/// its window shows) it shows the app icon — never another tab's picture.
struct SourceThumbnail: View {
    let source: CaptureSource
    /// The picture to show; `source.previewID` unless the caller knows better (a recording that moved).
    let previewID: CaptureSourceID?
    /// Short state under the icon when there is no picture ("Tab not showing").
    var placeholderLabel: String?
    @EnvironmentObject private var thumbnails: ThumbnailStore

    init(source: CaptureSource) {
        self.source = source
        self.previewID = source.previewID
    }

    init(source: CaptureSource, previewID: CaptureSourceID?, placeholderLabel: String? = nil) {
        self.source = source
        self.previewID = previewID
        self.placeholderLabel = placeholderLabel
    }

    var body: some View {
        Rectangle()
            .fill(Ink.fill2)
            .aspectRatio(Metrics.thumbAspect, contentMode: .fit)
            .overlay {
                if let image = thumbnails.image(for: previewID) {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 7) {
                        SourceIcon(source: source, size: 30).opacity(0.9)
                        if let placeholderLabel {
                            Text(placeholderLabel)
                                .font(.wispCaption)
                                .foregroundStyle(Ink.secondary)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
                    .strokeBorder(Ink.separator, lineWidth: Metrics.hairline)
            )
    }
}

/// A selectable source: thumbnail, app icon + name, and one line of detail.
struct SourceCard<Detail: View>: View {
    let source: CaptureSource
    let title: String
    let selected: Bool
    var accessibilityDetail: String
    let action: () -> Void
    @ViewBuilder var detail: () -> Detail
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                SourceThumbnail(source: source)
                    .overlay(alignment: .topTrailing) {
                        if selected { SelectionCheck().padding(5) }
                    }
                HStack(spacing: 6) {
                    SourceIcon(source: source)
                    Text(title)
                        .font(.wispTileName)
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.top, 7)
                .padding(.horizontal, 3)
                detail()
                    .lineLimit(1)
                    .padding(.leading, 25)
                    .padding(.top, 1)
                    .padding(.trailing, 3)
            }
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 7, trailing: 4))
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(selected || hovering ? Ink.fill2 : Ink.fill1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(selected ? Ink.selection : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, accessibilityDetail, selected ? "selected" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

extension SourceCard where Detail == Text {
    init(source: CaptureSource, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) {
        self.init(source: source, title: title, selected: selected, accessibilityDetail: subtitle, action: action) {
            Text(subtitle).font(.wispCaption).foregroundStyle(Ink.secondary)
        }
    }
}
