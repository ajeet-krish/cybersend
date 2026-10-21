import SwiftUI

// Small capsule label for statuses such as "Open" or a grade badge.

struct Chip: View {
    let text: String
    var emphasized = false

    init(_ text: String, emphasized: Bool = false) {
        self.text = text
        self.emphasized = emphasized
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // accentSolid, not accent: white on the bright accent measures 2.4:1, white on
            // the solid accent measures about 4.9:1.
            .background(emphasized ? Theme.accentSolid : Theme.separator.opacity(0.35))
            .foregroundStyle(emphasized ? Color.white : Theme.secondaryText)
            .clipShape(Capsule())
    }
}
