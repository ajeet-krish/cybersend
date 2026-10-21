import CyberSendDomain
import SwiftUI

// Logbook tab (M2 Task 4): the typed NavigationStack for the logbook and session routes
// over the real Features LogbookStore (docs/architecture.md M2 navigation, docs/
// decisions.md 2026-10-20 typed route enums per tab). Gym and grade scheme management
// live behind LogbookRoute; the session screen is reachable from this stack because the
// quick log climb rows push it.

struct LogbookTabView: View {
    @Environment(\.appServices) private var services
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let services {
                    LogbookHomeView(path: $path, services: services)
                } else {
                    Screen {
                        EmptyState(
                            systemImage: "exclamationmark.triangle",
                            title: "Logbook unavailable",
                            message: "The app services did not load."
                        )
                    }
                }
            }
                .navigationTitle("Logbook")
                .navigationDestination(for: LogbookRoute.self) { route in
                    switch route {
                    case .climbDetail(let climbId):
                        if let services {
                            ClimbEditorView(climbId: climbId, services: services)
                        } else {
                            RoutePendingView(routeDescription: route.pendingDescription)
                        }
                    case .gymDetail:
                        // Gym detail screens are outside the M2 scope (management
                        // happens on the gyms screen); the typed route stays registered
                        // so later tasks fill it in without navigation churn.
                        RoutePendingView(routeDescription: route.pendingDescription)
                    case .tagging(let climbId):
                        if let services {
                            TaggingView(climbId: climbId, services: services)
                        } else {
                            RoutePendingView(routeDescription: route.pendingDescription)
                        }
                    }
                }
                .navigationDestination(for: SessionsRoute.self) { route in
                    sessionDestination(route)
                }
        }
    }

    @ViewBuilder
    private func sessionDestination(_ route: SessionsRoute) -> some View {
        switch route {
        case .sessionDetail(let sessionId, let climbId):
            if let services {
                SessionDetailView(sessionId: sessionId, services: services, initialClimbId: climbId)
            } else {
                RoutePendingView(routeDescription: route.pendingDescription)
            }
        }
    }
}

/// Placeholder destination for routes whose screens land in a later task. Keeps the typed
/// route seam real (navigation compiles and renders) without stub screens.
struct RoutePendingView: View {
    let routeDescription: String

    var body: some View {
        Screen {
            EmptyState(
                systemImage: "hammer",
                title: "Coming soon",
                message: "\(routeDescription) arrives with a later M2 screen task."
            )
        }
        .accessibilityIdentifier("route.pending")
        .navigationTitle("Coming soon")
    }
}

extension LogbookRoute {
    var pendingDescription: String {
        switch self {
        case .gymDetail: return "Gym detail"
        case .climbDetail: return "Climb editor"
        case .tagging: return "Hold tagging"
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
