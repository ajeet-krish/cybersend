import SwiftUI

// Sessions tab (M2 Task 4): the typed NavigationStack for the session screen over the
// SessionsHistoryView, which reads the app side SessionsHistoryStore (US-22.1, reverse
// chronological history up to the 1000 session budget).

struct SessionsTabView: View {
    @Environment(\.appServices) private var services

    var body: some View {
        NavigationStack {
            SessionsHistoryView()
                .navigationDestination(for: SessionsRoute.self) { route in
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
    }
}
