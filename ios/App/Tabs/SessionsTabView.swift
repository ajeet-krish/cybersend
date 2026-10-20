import SwiftUI

// Sessions tab shell (M2 Task 3): reverse chronological history rows from the placeholder
// SessionsTabStore. Task 4 wires the Features session store and SessionDetailStore behind
// SessionsRoute.

struct SessionsTabView: View {
    @EnvironmentObject private var store: SessionsTabStore

    var body: some View {
        NavigationStack {
            Screen {
                if let message = store.lastErrorMessage {
                    ErrorNote(message)
                }

                SectionTitle("History")
                Card {
                    if store.rows.isEmpty {
                        EmptyState(
                            systemImage: "calendar",
                            title: "No sessions yet",
                            message: "Sessions you log at a gym will be listed here."
                        )
                    } else {
                        ForEach(store.rows) { row in
                            NavigationLink(value: SessionsRoute.sessionDetail(sessionId: row.id)) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.title)
                                            .font(.body)
                                            .foregroundStyle(Theme.primaryText)
                                        Text(row.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                    Spacer(minLength: 8)
                                    if row.isOpen {
                                        Chip("Open", emphasized: true)
                                    } else if row.attemptCount > 0 {
                                        Text(row.attemptCount == 1 ? "1 attempt" : "\(row.attemptCount) attempts")
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionsRoute.self) { route in
                RoutePendingView(routeDescription: route.pendingDescription)
            }
            .onAppear { store.refresh() }
        }
    }
}
