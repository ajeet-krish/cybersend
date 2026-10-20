import SwiftUI

// Standard screen scaffold: a scrolling, grouped background container every tab and
// detail screen shares.

struct Screen<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(Theme.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.screenBackground.ignoresSafeArea())
    }
}
