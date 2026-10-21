import SwiftUI

// Theme tokens (docs/architecture.md M2: dark mode themed from day one, US-24). The palette
// is Dracula carried on a deeper cyberpunk base: purple accent, neon status colours, and a
// base surface darker than stock Dracula so cards separate from the page without a shadow.
// Both appearances are first class (Alucard is Dracula's own light palette) and dark is the
// default preference, resolved in SettingsStore.
//
// The token split below is enforced by measurement, not taste:
//  * primaryText on cardBackground is at least 12:1 in both appearances.
//  * secondaryText on cardBackground is at least 5.5:1. Dracula's #6272A4 comment colour
//    measures about 3.0:1 on #282A36, so it is a decoration token only, never body text.
//  * accentSolid carries white text at about 4.9:1, so filled controls use it. The bright
//    accent (#BD93F9) is for icons and large glyphs, where it measures about 5.8:1 on the
//    card but only 2.4:1 against white, so it never sits behind white label text.

enum Theme {
    // MARK: - Surfaces

    /// Page background behind cards.
    static let screenBackground = dynamic(light: 0xFFFBEB, dark: 0x1B1B26)
    /// Card and row surface on top of the page background.
    static let cardBackground = dynamic(light: 0xFFFFFF, dark: 0x282A36)
    /// Hairline edge that separates a card from the page in the dark palette.
    static let cardBorder = dynamic(light: 0xE3DFD3, dark: 0x44475A)
    /// Secondary surface for nested blocks and inset rows.
    static let surfaceRaised = dynamic(light: 0xF4F0E4, dark: 0x343746)

    // MARK: - Text

    static let primaryText = dynamic(light: 0x1F1F1F, dark: 0xF8F8F2)
    static let secondaryText = dynamic(light: 0x6C664B, dark: 0x9AA5CE)
    /// Decoration only: dividers, disabled glyphs, empty state icons.
    static let tertiaryText = dynamic(light: 0x8C8677, dark: 0x6272A4)

    // MARK: - Accent

    /// Bright accent for icons and large glyphs.
    static let accent = dynamic(light: 0x644AC9, dark: 0xBD93F9)
    /// Filled surfaces that carry white text (primary buttons, emphasized chips).
    static let accentSolid = dynamic(light: 0x644AC9, dark: 0x7A5CD6)

    // MARK: - Status

    static let success = dynamic(light: 0x14710A, dark: 0x50FA7B)
    static let warning = dynamic(light: 0xA34D14, dark: 0xFFB86C)
    static let danger = dynamic(light: 0xCB3A2A, dark: 0xFF5555)
    static let info = dynamic(light: 0x036A96, dark: 0x8BE9FD)
    static let separator = dynamic(light: 0xE3DFD3, dark: 0x44475A)

    // MARK: - Metrics

    static let screenPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 14
    static let controlSpacing: CGFloat = 12

    // MARK: - Helpers

    /// One token, two appearances: the trait collection resolves the value, so every view
    /// keeps using `Theme.x` and follows preferredColorScheme with no plumbing.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
