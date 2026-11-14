import AppKit
import SwiftUI

/// Status-item title while recording: a vermillion dot and the elapsed time in monospaced digits.
public enum MenuBarStatus {
    /// "12:34", "1:02:03".
    @MainActor
    public static func timeText(_ elapsed: TimeInterval) -> String {
        TimerLabel.format(elapsed)
    }

    @MainActor
    public static func title(elapsed: TimeInterval) -> NSAttributedString {
        title(text: timeText(elapsed))
    }

    @MainActor
    public static func title(text: String) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: " ●",
            attributes: [
                .foregroundColor: Ink.nsColor(.vermillion),
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .baselineOffset: 1,
            ]
        )
        title.append(NSAttributedString(
            string: " " + text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        ))
        return title
    }
}
