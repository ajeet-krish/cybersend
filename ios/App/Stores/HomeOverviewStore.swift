import CyberSendData
import CyberSendDomain
import Foundation

// Home overview store (UI overhaul): the three blocks under the session card. Recent
// sessions, recent climbs (most recently attempted first, per the product decision), and
// the consistency calendar. All reads happen on the main actor through repositories, and
// the calendar math uses the local calendar so a session at 23:50 lands on the day the
// climber remembers.

@MainActor
final class HomeOverviewStore: ObservableObject {
    struct RecentSession: Identifiable, Equatable {
        let sessionId: String
        let gymName: String
        let startedAt: String
        let rpe: Int?
        let attemptCount: Int
        let isOpen: Bool

        var id: String { sessionId }
    }

    struct RecentClimb: Identifiable, Equatable {
        let climbId: String
        let name: String
        let gradeLabel: String?
        let lastAttemptAt: String
        let lastOutcome: AttemptOutcome
        let attemptCount: Int

        var id: String { climbId }
    }

    /// One heatmap cell: the local day and how many sessions started on it.
    struct HeatmapDay: Identifiable, Equatable {
        let date: Date
        let count: Int
        let isFuture: Bool

        var id: Date { date }
    }

    /// 20 weeks of columns, seven rows each, Sunday first. Twenty weeks keeps 12 pt cells
    /// inside the card width on the smallest supported phone.
    static let heatmapWeeks = 20
    private static let recentLimit = 3

    @Published private(set) var recentSessions: [RecentSession] = []
    @Published private(set) var recentClimbs: [RecentClimb] = []
    @Published private(set) var heatmapColumns: [[HeatmapDay]] = []
    @Published private(set) var sessionsInHeatmapWindow = 0
    @Published private(set) var lastErrorMessage: String?

    private let repos: Repositories

    init(repos: Repositories) {
        self.repos = repos
        refresh()
    }

    func refresh(now: Date = Date(), calendar: Calendar = .current) {
        do {
            let summaries = try repos.sessions.list(limit: 500)
            let gymsById = Dictionary(
                (try repos.gyms.list(includeArchived: true)).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            recentSessions = summaries.prefix(Self.recentLimit).map { summary in
                RecentSession(
                    sessionId: summary.session.id,
                    gymName: gymsById[summary.session.gymId]?.name ?? "Unknown gym",
                    startedAt: summary.session.startedAt,
                    rpe: summary.session.rpe,
                    attemptCount: summary.attemptCount,
                    isOpen: isSessionOpen(summary.session)
                )
            }

            let systems = try repos.grades.listSystems()
            recentClimbs = try recentClimbs(limit: Self.recentLimit, systems: systems)
            buildHeatmap(summaries: summaries, now: now, calendar: calendar)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Recent climbs

    /// The most recently attempted climbs, one row each. Walks recent attempts newest first
    /// and keeps the first occurrence of each climb, so a climb tried twice today does not
    /// take two of the three slots.
    private func recentClimbs(limit: Int, systems: [GradeSystem]) throws -> [RecentClimb] {
        var seen: Set<String> = []
        var climbsById: [String: Climb] = [:]
        var rows: [RecentClimb] = []
        for attempt in try repos.attempts.listRecent(limit: 60) {
            guard seen.insert(attempt.climbId).inserted else { continue }
            let climb: Climb
            if let cached = climbsById[attempt.climbId] {
                climb = cached
            } else if let loaded = try repos.climbs.get(id: attempt.climbId) {
                climbsById[attempt.climbId] = loaded
                climb = loaded
            } else {
                continue
            }
            rows.append(RecentClimb(
                climbId: climb.id,
                name: climb.name ?? "Untitled problem",
                gradeLabel: DisplayText.grade(climb, systems: systems),
                lastAttemptAt: attempt.attemptedAt,
                lastOutcome: attempt.outcome,
                attemptCount: try repos.attempts.countByClimb(climbId: climb.id)
            ))
            if rows.count == limit { break }
        }
        return rows
    }

    // MARK: - Heatmap

    private func buildHeatmap(summaries: [SessionSummary], now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        // Weekday components are 1 based with Sunday first; the grid rows use the same
        // order so the top row is always Sunday.
        let todayRow = calendar.component(.weekday, from: today) - 1
        guard let currentWeekStart = calendar.date(byAdding: .day, value: -todayRow, to: today),
              let windowStart = calendar.date(
                byAdding: .weekOfYear,
                value: -(Self.heatmapWeeks - 1),
                to: currentWeekStart
              )
        else {
            heatmapColumns = []
            sessionsInHeatmapWindow = 0
            return
        }

        var counts: [Date: Int] = [:]
        for summary in summaries {
            guard let date = parseISO(summary.session.startedAt) else { continue }
            let day = calendar.startOfDay(for: date)
            guard day >= windowStart, day <= today else { continue }
            counts[day, default: 0] += 1
        }
        sessionsInHeatmapWindow = counts.values.reduce(0, +)

        var columns: [[HeatmapDay]] = []
        columns.reserveCapacity(Self.heatmapWeeks)
        for week in 0..<Self.heatmapWeeks {
            var days: [HeatmapDay] = []
            for day in 0..<7 {
                guard let date = calendar.date(
                    byAdding: .day,
                    value: week * 7 + day,
                    to: windowStart
                ) else { continue }
                days.append(HeatmapDay(
                    date: date,
                    count: counts[date] ?? 0,
                    isFuture: date > today
                ))
            }
            columns.append(days)
        }
        heatmapColumns = columns
    }

    private func parseISO(_ text: String) -> Date? {
        if let date = HomeOverviewStore.fractionalFormatter.date(from: text) { return date }
        return HomeOverviewStore.plainFormatter.date(from: text)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
