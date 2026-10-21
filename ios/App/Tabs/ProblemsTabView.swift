import CyberSendDomain
import SwiftUI

// Problems tab (UI overhaul): the typed NavigationStack for the catalog. Create and edit
// reuse ClimbEditorView, so the stack also registers LogbookRoute.tagging: the shared
// editor links to that route for hold tagging, and without the destination the link would
// silently do nothing inside this stack.

struct ProblemsTabView: View {
    @Environment(\.appServices) private var services

    var body: some View {
        NavigationStack {
            if let services {
                ProblemsCatalogView(services: services)
                    .navigationDestination(for: ProblemsRoute.self) { route in
                        problemsDestination(route, services: services)
                    }
                    .navigationDestination(for: LogbookRoute.self) { route in
                        logbookDestination(route, services: services)
                    }
            } else {
                Screen {
                    EmptyState(
                        systemImage: "exclamationmark.triangle",
                        title: "Problems unavailable",
                        message: "The app services did not load."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func problemsDestination(_ route: ProblemsRoute, services: AppServices) -> some View {
        switch route {
        case .problemDetail(let climbId):
            ProblemDetailView(climbId: climbId, services: services)
        case .newProblem:
            ClimbEditorView(climbId: "new", services: services, noun: "problem")
        case .editProblem(let climbId):
            ClimbEditorView(climbId: climbId, services: services, noun: "problem")
        case .tagging(let climbId):
            TaggingView(climbId: climbId, services: services)
        }
    }

    @ViewBuilder
    private func logbookDestination(_ route: LogbookRoute, services: AppServices) -> some View {
        switch route {
        case .tagging(let climbId):
            TaggingView(climbId: climbId, services: services)
        case .climbDetail, .gymDetail:
            RoutePendingView(routeDescription: route.pendingDescription)
        }
    }
}
