import SwiftUI

// A settings style row: icon, title, optional trailing detail. Interactive rows wrap it in
// a Button or NavigationLink; plain rows render it directly.

struct Row: View {
    let title: String
    var detail: String?
    var systemImage: String?

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
            }
            Text(title)
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.body)
        .padding(.vertical, 2)
    }
}
