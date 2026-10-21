import SwiftUI

// Full width prominent action (primary path on a screen).

struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        // The solid accent keeps the white label above 4.9:1 contrast.
        .tint(Theme.accentSolid)
        .controlSize(.large)
    }
}
