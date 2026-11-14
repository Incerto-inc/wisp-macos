import SwiftUI
import WispDomain

/// Other Window…: the same panel becomes a thumbnail grid (Windows, Screens) or a list (Tabs).
/// Choosing returns to Ready. Everything shown comes from `model.pickerItems`.
struct ChoosingView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        let items = model.pickerItems
        VStack(alignment: .leading, spacing: 0) {
            InkSegmented(
                selection: $model.pickerTab,
                options: model.pickerTabs.map { ($0, Self.title(of: $0)) },
                fill: true
            )

            if model.pickerSearches {
                InkSearchField(text: $model.search, focused: $searchFocused)
                    .padding(.top, 8)
            }

            if model.pickerTab == .tabs {
                TabList(model: model, items: items)
                    .padding(.top, 8)
            } else if items.isEmpty {
                EmptyPickerText(text: emptyText)
            } else {
                grid(items)
            }
        }
        .onAppear { searchFocused = model.pickerSearches }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
    }

    private static func title(of tab: PanelModel.PickerTab) -> String {
        switch tab {
        case .windows: return "Windows"
        case .tabs: return "Tabs"
        case .screens: return "Screens"
        }
    }

    private var emptyText: String {
        if model.pickerTab == .screens { return "No screens to record." }
        return model.search.isEmpty ? "No windows to record." : "No windows match “\(model.search)”."
    }

    private func grid(_ items: [CaptureSource]) -> some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(items) { source in
                    SourceCard(
                        source: source,
                        title: source.kind == .screen ? source.title : CaptureSourceLabel.title(source),
                        selected: (model.pickerHighlightID ?? model.selectedID) == source.id,
                        accessibilityDetail: SourceDetail.accessibilityText(source),
                        action: { model.choose(source) },
                        detail: { SourceDetail(source: source) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.automatic)
        .frame(height: gridHeight(count: items.count))
        .padding(.top, 10)
    }

    /// Two columns; tiles are ~150pt tall. Shows up to three rows, then scrolls.
    private func gridHeight(count: Int) -> CGFloat {
        let tile: CGFloat = 150
        let rows = CGFloat(min(3, max(1, (count + 1) / 2)))
        return rows * tile + (rows - 1) * 6 + 2
    }
}

/// "In call" for a source in a call, else its subtitle ("App", "host", "App · Other Desktop").
struct SourceDetail: View {
    let source: CaptureSource

    var body: some View {
        if Self.isInCall(source) {
            InCallLabel()
        } else {
            Text(CaptureSourceLabel.subtitle(source)).font(.wispCaption).foregroundStyle(Ink.secondary)
        }
    }

    static func isInCall(_ source: CaptureSource) -> Bool {
        MeetingDetector.signal(for: source)?.isInCall == true
    }

    static func accessibilityText(_ source: CaptureSource) -> String {
        let detail = isInCall(source) ? "\(CaptureSourceLabel.appName(source)), In call" : CaptureSourceLabel.subtitle(source)
        // Tab rows show the browser only as an icon; VoiceOver hears its name.
        if source.kind == .tab, !isInCall(source) { return "\(detail), \(CaptureSourceLabel.appName(source)) tab" }
        return detail
    }
}

private struct EmptyPickerText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.wispCaptionLarge)
            .foregroundStyle(Ink.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

// MARK: - Tabs

/// Browser tabs as rows (titles matter more than pictures), then one row per browser whose
/// tabs Wisp may not read yet.
private struct TabList: View {
    @ObservedObject var model: PanelModel
    let items: [CaptureSource]

    private static let rowHeight: CGFloat = 40
    private static let rowGap: CGFloat = 2
    private static let visibleRows = 7

    var body: some View {
        let browsers = model.browsersWithoutTabAccess
        VStack(alignment: .leading, spacing: 0) {
            if !items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: Self.rowGap) {
                            ForEach(items) { source in
                                TabRow(
                                    source: source,
                                    selected: (model.pickerHighlightID ?? model.selectedID) == source.id,
                                    action: { model.choose(source) }
                                )
                                .id(source.id)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: listHeight(count: items.count))
                    .onChange(of: model.pickerHighlightID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            } else if !model.search.isEmpty {
                EmptyPickerText(text: "No tabs match “\(model.search)”.")
            } else if browsers.isEmpty {
                EmptyPickerText(text: "No tabs to record.")
            }

            if !browsers.isEmpty {
                if !items.isEmpty {
                    HairlineDivider().padding(.vertical, 6).padding(.horizontal, 8)
                }
                ForEach(browsers) { browser in
                    TabAccessRow(browser: browser) {
                        Task { await model.requestTabAccess(bundleIdentifier: browser.bundleIdentifier) }
                    }
                }
            }
        }
    }

    private func listHeight(count: Int) -> CGFloat {
        let rows = CGFloat(min(Self.visibleRows, max(1, count)))
        return rows * Self.rowHeight + (rows - 1) * Self.rowGap
    }
}

/// Browser icon, the tab's title, and "host · Browser" or "In call"; a check when selected.
private struct TabRow: View {
    let source: CaptureSource
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SourceIcon(source: source, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CaptureSourceLabel.title(source))
                        .font(.wispBody)
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    SourceDetail(source: source)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if selected { SelectionCheck() }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected || hovering ? Ink.fill2 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [CaptureSourceLabel.title(source), SourceDetail.accessibilityText(source), selected ? "selected" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "Show Safari tabs" (asks macOS once) or "Allow Safari in Settings" (after a refusal).
private struct TabAccessRow: View {
    let browser: BrowserTabStatus
    let action: () -> Void
    @State private var hovering = false

    private var denied: Bool { browser.access == .denied }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AppIcon(bundleIdentifier: browser.bundleIdentifier, size: 16)
                    .opacity(0.85)
                Text(denied ? "Allow \(browser.name) in Settings" : "Show \(browser.name) tabs")
                    .font(.wispLink)
                    .foregroundStyle(hovering ? Ink.text : Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: denied ? "arrow.up.forward" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: Metrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Ink.fill2 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
