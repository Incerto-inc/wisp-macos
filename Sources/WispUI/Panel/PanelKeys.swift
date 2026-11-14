import Foundation

/// Keys the panel reacts to, already decoded from AppKit events by the app shell.
public enum PanelKey: Equatable, Sendable {
    case escape
    case returnKey
    case left
    case right
    case up
    case down
    /// ⌘ plus a character ("." stops, "f" searches).
    case command(Character)
}

/// What the shell should do with the key after the panel looked at it.
public enum PanelKeyResult: Equatable, Sendable {
    /// The panel used it; swallow the event.
    case handled
    /// Not the panel's; let AppKit deliver it (text fields, menus).
    case passThrough
    /// Escape on the top level: close the panel.
    case hidePanel
}

extension PanelModel {
    /// The panel's keyboard rules. `editingText` is true while a text field has focus; the shell
    /// handles an input method that is composing (it gets every key) before calling this.
    public func handle(_ key: PanelKey, editingText: Bool) -> PanelKeyResult {
        let selectable = surface == .choosing || (surface == .ready && mode == .meeting)
        switch key {
        case .escape:
            if isRenaming {
                isRenaming = false // cancels the rename, not the whole view
            } else if surface == .choosing, !search.isEmpty {
                search = ""
            } else if surface == .choosing || isDetail {
                back()
            } else {
                return .hidePanel
            }
            return .handled
        case .returnKey:
            guard surface == .choosing else { return .passThrough }
            chooseSelected()
            return .handled
        case .left, .right:
            // In a text field, left and right move the caret.
            guard !editingText, selectable else { return .passThrough }
            moveSelection(dx: key == .left ? -1 : 1, dy: 0)
            return .handled
        case .up, .down:
            guard surface == .choosing else { return .passThrough }
            moveSelection(dx: 0, dy: key == .up ? -1 : 1)
            return .handled
        case .command("."):
            guard surface == .recording else { return .passThrough }
            Task { await stopRecording() }
            return .handled
        case .command(let character) where character == "f" || character == "F":
            guard surface == .choosing else { return .passThrough }
            focusSearch()
            return .handled
        case .command:
            return .passThrough
        }
    }
}
