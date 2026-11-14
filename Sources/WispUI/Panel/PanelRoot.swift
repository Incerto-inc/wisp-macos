import SwiftUI
import WispDomain

/// The whole menu-bar panel: one header and the current state below it.
public struct MenuBarPanel: View {
    @ObservedObject private var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: PanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(model: model)
                .padding(.bottom, Metrics.sectionGap)
            content
                .id(surfaceKey)
                .transition(.opacity)
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelBackground())
        .tint(Ink.text)
        .environmentObject(model.thumbnails)
        // Reduce Motion keeps a short fade (spec §5.4), only the longer ease goes away.
        .animation(reduceMotion ? .linear(duration: 0.12) : .easeInOut(duration: 0.22), value: surfaceKey)
    }

    @ViewBuilder
    private var content: some View {
        switch model.surface {
        case .permissions:
            PermissionsView(model: model)
        case .ready:
            if model.mode == .room {
                RoomView(model: model)
            } else {
                ReadyMeetingView(model: model)
            }
        case .choosing:
            ChoosingView(model: model)
        case .recording:
            RecordingView(model: model)
        case .detail(let meeting):
            DetailView(model: model, meeting: meeting)
        }
    }

    private var surfaceKey: String {
        switch model.surface {
        case .permissions: return "permissions-\(model.mode.rawValue)"
        case .ready: return "ready-\(model.mode.rawValue)"
        case .choosing: return "choosing"
        case .recording: return "recording"
        case .detail(let meeting): return "detail-\(meeting.id.folderName)"
        }
    }
}

/// Solid Ash/Ink surface over a light system blur; hairline edge; no glow.
struct PanelBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ZStack {
            shape.fill(.regularMaterial)
            shape.fill(Ink.panel.opacity(0.96))
        }
        .overlay(shape.strokeBorder(Ink.separator, lineWidth: Metrics.hairline))
    }
}
