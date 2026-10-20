import CyberSendData
import CyberSendDomain
import Foundation

// Sessions tab history store (M2 Task 4, US-22.1): reverse chronological sessions joined
// with their gym name, RPE, attempt count, and open badge, up to the 1000 session scroll
// budget (docs/requirements.md US-22.4). This store lives app side because the Features
// LogbookStore caps its history query at 500 rows for the logbook tab; repositories are
// called synchronously on the main actor and the screen refreshes on appear.

@MainActor
final class SessionsHistoryStore: ObservableObject {
    /// One history row: a session summary joined with its gym for display.
    struct Row: Identifiable, Equatable {
        /// Position based identifier ("history.row.0" is the newest session) so screens
        /// and UI tests can address a row without depending on generated UUIDs.
        let id: String
        let sessionId: String
        let gymName: String
        /// Archived gyms stay in history but render muted (US-8.4).
        let isGymArchived: Bool
        let startedAt: String
        let rpe: Int?
        let attemptCount: Int
        let isOpen: Bool
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var lastErrorMessage: String?

    private let repos: Repositories

    init(repos: Repositories) {
        self.repos = repos
        refresh()
    }

    func refresh() {
        do {
            let summaries = try repos.sessions.list(limit: 1000)
            var gymsById: [String: Gym] = [:]
            for gym in try repos.gyms.list(includeArchived: true) {
                gymsById[gym.id] = gym
            }
            rows = summaries.enumerated().map { index, summary in
                let gym = gymsById[summary.session.gymId]
                return Row(
                    id: "history.row.\(index)",
                    sessionId: summary.session.id,
                    gymName: gym?.name ?? "Unknown gym",
                    isGymArchived: gym?.isArchived ?? false,
                    startedAt: summary.session.startedAt,
                    rpe: summary.session.rpe,
                    attemptCount: summary.attemptCount,
                    isOpen: isSessionOpen(summary.session)
                )
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
