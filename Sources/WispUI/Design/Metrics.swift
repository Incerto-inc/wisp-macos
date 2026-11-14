import SwiftUI

/// Layout constants (spec §5.4). Radii nest: panel 16 → card 10 → thumbnail 6 → badge 4.
enum Metrics {
    static let panelWidth: CGFloat = 360
    static let padding: CGFloat = 12
    static let gap: CGFloat = 8
    static let sectionGap: CGFloat = 12
    static let panelRadius: CGFloat = 16
    static let cardRadius: CGFloat = 10
    static let thumbRadius: CGFloat = 6
    static let badgeRadius: CGFloat = 4
    static let rowHeight: CGFloat = 30
    static let buttonHeight: CGFloat = 32
    static let minHit: CGFloat = 24
    static let hairline: CGFloat = 0.5
    static let thumbAspect: CGFloat = 16.0 / 10.0
}

extension Font {
    static let wispHeadline = Font.system(size: 15, weight: .semibold)
    static let wispTitle = Font.system(size: 13, weight: .semibold)
    static let wispBody = Font.system(size: 13)
    static let wispTileName = Font.system(size: 12, weight: .semibold)
    static let wispCaption = Font.system(size: 11)
    static let wispCaptionLarge = Font.system(size: 11.5)
    static let wispSection = Font.system(size: 11, weight: .semibold)
    static let wispLink = Font.system(size: 12, weight: .medium)

    static func wispMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
