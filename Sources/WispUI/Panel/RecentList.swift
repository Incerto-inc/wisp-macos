import SwiftUI
import WispDomain

struct RecentSection: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineDivider().padding(.horizontal, -Metrics.padding)
            SectionHeader(title: "Recent") {
                InkLinkButton(title: "Show All", font: .system(size: 11, weight: .medium)) {
                    model.openRecordingsFolder()
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            if model.meetings.isEmpty {
                Text("Recordings appear here.")
                    .font(.wispCaption)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, 4)
                    .frame(height: Metrics.rowHeight, alignment: .leading)
            } else {
                ForEach(model.meetings.prefix(3), id: \.id.raw) { meeting in
                    RecentRow(
                        meeting: meeting,
                        highlighted: model.highlightedMeetingID == meeting.id,
                        open: { Task { await model.openDetail(meeting) } },
                        reveal: { Task { await model.reveal(meeting) } },
                        delete: { Task { await model.delete(meeting) } }
                    )
                }
            }
        }
    }
}

private struct RecentRow: View {
    let meeting: Meeting
    let highlighted: Bool
    let open: () -> Void
    let reveal: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Ink.fill2)
                .frame(width: 34, height: 21)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                }
            Text(meeting.title)
                .font(.wispBody)
                .foregroundStyle(Ink.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if confirmDelete {
                Button("Delete") {
                    confirmDelete = false
                    delete()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Ink.text)
                Button("Cancel") { confirmDelete = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.secondary)
            } else if hovering {
                IconButton(systemName: "folder", help: "Show in Finder", size: 13, action: reveal)
                IconButton(systemName: "trash", help: "Delete", size: 13) { confirmDelete = true }
            } else {
                Text(RecentFormat.meta(for: meeting))
                    .font(.wispMono(10.5))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: Metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering || highlighted ? Ink.fill2 : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(meeting.title), \(RecentFormat.meta(for: meeting))")
        .accessibilityAction(named: "Open", open)
    }

    private var icon: String {
        switch meeting.status {
        case .failed, .interrupted: return "exclamationmark"
        case .recording: return "record.circle"
        case .completed: return meeting.mode == .room ? "waveform" : "play.fill"
        }
    }
}

enum RecentFormat {
    /// "Yesterday · 42 min", "Wed · 18 min", "Nov 3 · 1 h 05 min", "Failed".
    static func meta(for meeting: Meeting, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch meeting.status {
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .recording: return "Recording…"
        case .completed: break
        }
        let day = dayLabel(meeting.startedAt, now: now, calendar: calendar)
        guard let ended = meeting.endedAt else { return day }
        return "\(day) · \(duration(ended.timeIntervalSince(meeting.startedAt)))"
    }

    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }
}
