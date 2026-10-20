import SwiftUI

// Sessions history screen (M2 Task 4, US-22.1): reverse chronological sessions with gym
// name (archived gyms muted, US-8.4), date, RPE, attempt count, and the in progress
// badge, up to the 1000 session scroll budget. Rows push the session screen
// (SessionsRoute.sessionDetail). A lazy List keeps large histories scrolling smoothly
// (US-22.4).

struct SessionsHistoryView: View {
    @EnvironmentObject private var store: SessionsHistoryStore

    var body: some View {
        List {
            if let message = store.lastErrorMessage {
                ErrorNote(message)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("history.error")
            }
            if store.rows.isEmpty {
                EmptyState(
                    systemImage: "calendar",
                    title: "No sessions yet",
                    message: "Sessions you log at a gym will be listed here."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(store.rows) { row in
                    rowLink(row)
                }
            }
        }
        .accessibilityIdentifier("history.screen")
        .navigationTitle("Sessions")
        .onAppear {
            store.refresh()
        }
    }

    private func rowLink(_ row: SessionsHistoryStore.Row) -> some View {
        NavigationLink(value: SessionsRoute.sessionDetail(sessionId: row.sessionId, climbId: nil)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.gymName)
                        .font(.body)
                        .foregroundStyle(row.isGymArchived ? Theme.secondaryText : Theme.primaryText)
                        .accessibilityIdentifier("\(row.id).gym")
                    Text(DisplayDate.string(from: row.startedAt))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("\(row.id).date")
                    if let rpe = DisplayText.rpe(row.rpe) {
                        Text(rpe)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("\(row.id).rpe")
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if row.isOpen {
                        Chip("Open", emphasized: true)
                            .accessibilityIdentifier("\(row.id).badge")
                    }
                    Text(DisplayText.attemptCount(row.attemptCount))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("\(row.id).attempts")
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(row.id)
    }
}
