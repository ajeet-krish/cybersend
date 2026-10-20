import SwiftUI

// Semantic theme colors (docs/architecture.md M2: dark mode themed from day one, US-24).
// System adaptive colors keep light and dark appearances correct without duplicating hex
// values; the accent comes from the AccentColor asset set which defines both appearances.

enum Theme {
    /// Grouped screen background (adapts to light, dark, and increased contrast).
    static let screenBackground = Color(uiColor: .systemGroupedBackground)
    /// Card and row surfaces on top of the grouped background.
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let separator = Color(uiColor: .separator)
    static let warning = Color.orange
    static let accent = Color.accentColor

    static let screenPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let controlSpacing: CGFloat = 12
}
