import CyberSendDomain
import SwiftUI

// Logbook tab shell (M2 Task 3): the open session card, gyms, and recent sessions read
// through the placeholder LogbookTabStore. Task 4 replaces the store with the Features
// logbook store and fills in the gyms, grades, and climb screens behind LogbookRoute.

struct LogbookTabView: View {
    @EnvironmentObject private var store: LogbookTabStore

    var body: some View {
        NavigationStack {
            Screen {
                if let message = store.lastErrorMessage {
                    ErrorNote(message)
                }

                SectionTitle("Open session")
                Card {
                    if let session = store.openSession {
                        Row(title: "Session in progress", detail: "Started \(Self.shortDate(from: session.startedAt))")
                        Chip("Open", emphasized: true)
                    } else {
                        EmptyState(
                            systemImage: "figure.climbing",
                            title: "No open session",
                            message: "Start a session at your gym to begin logging attempts."
                        )
                    }
                }

                SectionTitle("Gyms")
                Card {
                    if store.gyms.isEmpty {
                        EmptyState(
                            systemImage: "building.2",
                            title: "No gyms yet",
                            message: "Add a gym to attach sessions and climbs to it."
                        )
                    } else {
                        ForEach(store.gyms) { gym in
                            NavigationLink(value: LogbookRoute.gymDetail(gymId: gym.id)) {
                                Row(title: gym.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                SectionTitle("Recent sessions")
                Card {
                    if store.recentSessions.isEmpty {
                        EmptyState(
                            systemImage: "calendar",
                            title: "No sessions yet",
                            message: "Your logged sessions will appear here."
                        )
                    } else {
                        ForEach(store.recentSessions, id: \.session.id) { summary in
                            NavigationLink(value: SessionsRoute.sessionDetail(sessionId: summary.session.id)) {
                                Row(
                                    title: Self.shortDate(from: summary.session.startedAt),
                                    detail: summary.attemptCount == 1 ? "1 attempt" : "\(summary.attemptCount) attempts"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Logbook")
            .navigationDestination(for: LogbookRoute.self) { route in
                RoutePendingView(routeDescription: route.pendingDescription)
            }
            .navigationDestination(for: SessionsRoute.self) { route in
                RoutePendingView(routeDescription: route.pendingDescription)
            }
            .onAppear { store.refresh() }
        }
    }

    private static func shortDate(from isoText: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoText) else { return isoText }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}

/// Placeholder destination for routes whose screens land in M2 Task 4 and later. Keeps the
/// typed route seam real (navigation compiles and renders) without stub screens.
struct RoutePendingView: View {
    let routeDescription: String

    var body: some View {
        Screen {
            EmptyState(
                systemImage: "hammer",
                title: "Coming in M2",
                message: "\(routeDescription) arrives with the logbook screens."
            )
        }
        .navigationTitle("Coming in M2")
    }
}

extension LogbookRoute {
    var pendingDescription: String {
        switch self {
        case .gyms: return "Gym management"
        case .grades: return "Grade schemes"
        case .gymDetail: return "Gym detail"
        case .climbDetail: return "Climb detail"
        }
    }
}

extension SessionsRoute {
    var pendingDescription: String {
        switch self {
        case .sessionDetail: return "Session detail and quick log"
        }
    }
}
