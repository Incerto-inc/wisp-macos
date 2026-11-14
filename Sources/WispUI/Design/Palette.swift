import AppKit
import SwiftUI

/// Ash & Ink tokens (spec §5.4). Warm neutrals for everything; vermillion only for recording.
enum InkToken: CaseIterable {
    case panel
    case text
    case secondary
    case tertiary
    case vermillion
    case vermillionButton
    case onVermillion
    case segmentOn

    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }
    }

    func rgb(dark: Bool, highContrast: Bool = false) -> RGB {
        switch (self, dark) {
        case (.panel, true): return RGB(0x1E1D1B)
        case (.panel, false): return RGB(0xECEAE5)
        case (.text, true): return RGB(highContrast ? 0xEFEDE8 : 0xDEDBD4)
        case (.text, false): return RGB(highContrast ? 0x111110 : 0x22211F)
        case (.secondary, true): return RGB(highContrast ? 0xC6C2BA : 0x95918A)
        case (.secondary, false): return RGB(highContrast ? 0x45423D : 0x68645D)
        case (.tertiary, true): return RGB(0x66625C)
        case (.tertiary, false): return RGB(0x9C978F)
        case (.vermillion, true): return RGB(0xF0603F)
        case (.vermillion, false): return RGB(0xC23D20)
        case (.vermillionButton, true): return RGB(0xC9432A)
        case (.vermillionButton, false): return RGB(0xC23D20)
        case (.onVermillion, _): return RGB(0xFBF8F3)
        case (.segmentOn, true): return RGB(0x3A3835)
        case (.segmentOn, false): return RGB(0xF8F7F4)
        }
    }
}

enum Ink {
    static let panel = dynamic(.panel)
    static let text = dynamic(.text)
    static let secondary = dynamic(.secondary)
    static let tertiary = dynamic(.tertiary)
    static let vermillion = dynamic(.vermillion)
    static let vermillionButton = dynamic(.vermillionButton)
    static let onVermillion = dynamic(.onVermillion)
    static let segmentOn = dynamic(.segmentOn)

    /// Fills and lines are the text colour at low opacity, so they stay warm in both appearances.
    static let fill1 = textAlpha(dark: 0.05, light: 0.045)
    static let fill2 = textAlpha(dark: 0.09, light: 0.08)
    static let fill3 = textAlpha(dark: 0.15, light: 0.12)
    static let separator = textAlpha(dark: 0.10, light: 0.12, highContrast: 0.28)
    static let selection = text
    static let checkGlyph = panel

    static func nsColor(_ token: InkToken, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let (dark, highContrast) = Self.traits(appearance)
            let rgb = token.rgb(dark: dark, highContrast: highContrast)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
        }
    }

    private static func dynamic(_ token: InkToken) -> Color {
        Color(nsColor: nsColor(token))
    }

    private static func textAlpha(dark: CGFloat, light: CGFloat, highContrast: CGFloat? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (isDark, isHighContrast) = Self.traits(appearance)
            let rgb = InkToken.text.rgb(dark: isDark, highContrast: isHighContrast)
            let alpha = isHighContrast ? (highContrast ?? (isDark ? dark : light) * 1.6) : (isDark ? dark : light)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
        })
    }

    private static func traits(_ appearance: NSAppearance) -> (dark: Bool, highContrast: Bool) {
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        switch match {
        case .darkAqua: return (true, false)
        case .accessibilityHighContrastDarkAqua: return (true, true)
        case .accessibilityHighContrastAqua: return (false, true)
        default: return (false, false)
        }
    }
}
