import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Logbook home (M2 Task 4, US-8 to US-12; UI overhaul): the session card, the session
// consistency calendar, and the two recent blocks (sessions, climbs). The quick log climb
// list and the gym chips moved out: climbs live in the Problems tab now, and the gym is
// chosen on the session card that needs it. Quick log budget (docs/architecture.md M2):
// from the home screen an attempt costs at most 5 taps, the same flow the
// QuickLogSmokeTests tap accounting encodes.

struct LogbookHomeView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var store: LogbookStore
    @EnvironmentObject private var thumbnails: ClimbThumbnailsModel
    @StateObject private var overview: HomeOverviewStore

    @State private var actionError: String?
    @State private var offerOpenExisting = false

    init(path: Binding<NavigationPath>, services: AppServices) {
        _path = path
        _overview = StateObject(wrappedValue: HomeOverviewStore(repos: services.repos))
    }

    var body: some View {
        Screen {
            if let message = actionError ?? store.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("logbook.error")
            }
            if offerOpenExisting, store.openSession != nil {
                SecondaryButton("Open existing session") {
                    openExistingSession()
                }
                .accessibilityIdentifier("logbook.open-existing")
            }

            SectionTitle("Session")
            sessionCard

            SectionTitle("Consistency")
            consistencyCard

            SectionTitle("Recent sessions")
            recentSessionsCard

            SectionTitle("Recent climbs")
            recentClimbsCard
        }
        .accessibilityIdentifier("logbook.screen")
        .onAppear {
            store.refresh()
            thumbnails.refresh()
            overview.refresh()
        }
    }

    // MARK: - Session card

    @ViewBuilder
    private var sessionCard: some View {
        Card {
            if let session = store.openSession {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Session in progress")
                            .font(.headline)
                            .foregroundStyle(Theme.primaryText)
                        Text("Started \(DisplayDate.string(from: session.startedAt))")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Chip("Open", emphasized: true)
                        .accessibilityIdentifier("logbook.session.badge")
                }
                .accessibilityIdentifier("logbook.session.in-progress")
            } else {
                HStack {
                    Text("Gym")
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 8)
                    gymMenu
                }
                Divider()
                    .overlay(Theme.separator)
                    .padding(.vertical, 6)
                Text("No open session")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text("Start a session at the selected gym to log attempts.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("logbook.session.card")

        if store.openSession != nil {
            PrimaryButton("Open session") {
                openExistingSession()
            }
            .accessibilityIdentifier("session.card.open")
        } else {
            PrimaryButton("Start session") {
                startSession()
            }
            .accessibilityIdentifier("logbook.start-session")
        }
    }

    @ViewBuilder
    private var gymMenu: some View {
        if store.gyms.isEmpty {
            Text("Add a gym in Settings")
                .font(.subheadline)
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityIdentifier("logbook.gym.none")
        } else {
            Menu {
                ForEach(store.gyms) { gym in
                    Button {
                        store.selectGym(gym.id)
                    } label: {
                        if gym.id == store.selectedGymId {
                            Label(gym.name, systemImage: "checkmark")
                        } else {
                            Text(gym.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(store.selectedGym?.name ?? "Select gym")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .accessibilityIdentifier("logbook.gym.select")
        }
    }

    // MARK: - Consistency

    @ViewBuilder
    private var consistencyCard: some View {
        Card {
            SessionHeatmap(columns: overview.heatmapColumns)
                .accessibilityIdentifier("home.heatmap")
            HStack(alignment: .firstTextBaseline) {
                Text("\(overview.sessionsInHeatmapWindow) sessions in the last \(HomeOverviewStore.heatmapWeeks) weeks")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("home.heatmap.summary")
                Spacer(minLength: 8)
                heatmapLegend
            }
            .padding(.top, 10)
        }
    }

    private var heatmapLegend: some View {
        HStack(spacing: 3) {
            Text("Less")
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiaryText)
            ForEach(0..<4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(heatmapColor(count: level))
                    .frame(width: 9, height: 9)
            }
            Text("More")
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiaryText)
        }
        .accessibilityHidden(true)
    }

    private func heatmapColor(count: Int) -> Color {
        switch count {
        case 0: return Theme.surfaceRaised
        case 1: return Theme.accent.opacity(0.45)
        case 2: return Theme.accent.opacity(0.75)
        default: return Theme.accent
        }
    }

    // MARK: - Recent sessions

    @ViewBuilder
    private var recentSessionsCard: some View {
        if overview.recentSessions.isEmpty {
            Card {
                EmptyState(
                    systemImage: "calendar",
                    title: "No sessions yet",
                    message: "Your last three sessions appear here once you start one."
                )
                .accessibilityIdentifier("home.sessions.empty")
            }
        } else {
            Card {
                ForEach(Array(overview.recentSessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        Divider()
                            .overlay(Theme.separator)
                            .padding(.vertical, 8)
                    }
                    NavigationLink(value: SessionsRoute.sessionDetail(sessionId: session.sessionId, climbId: nil)) {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.gymName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(1)
                                Text(DisplayDate.string(from: session.startedAt))
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer(minLength: 8)
                            if session.isOpen {
                                Chip("Open", emphasized: true)
                            } else if let rpe = DisplayText.rpe(session.rpe) {
                                Text(rpe)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Text(DisplayText.attemptCount(session.attemptCount))
                                .font(.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.session.\(index)")
                }
            }
        }
    }

    // MARK: - Recent climbs

    @ViewBuilder
    private var recentClimbsCard: some View {
        if overview.recentClimbs.isEmpty {
            Card {
                EmptyState(
                    systemImage: "figure.climbing",
                    title: "No climbs tried yet",
                    message: "Climbs you log an attempt on appear here, most recent first."
                )
                .accessibilityIdentifier("home.climbs.empty")
            }
        } else {
            Card {
                ForEach(Array(overview.recentClimbs.enumerated()), id: \.element.id) { index, climb in
                    if index > 0 {
                        Divider()
                            .overlay(Theme.separator)
                            .padding(.vertical, 8)
                    }
                    NavigationLink(value: LogbookRoute.climbDetail(climbId: climb.climbId)) {
                        HStack(alignment: .center, spacing: 10) {
                            climbThumbnail(climb.climbId)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(climb.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(1)
                                Text("Last \(DisplayText.outcomeTitle(climb.lastOutcome).lowercased()) \(DisplayDate.string(from: climb.lastAttemptAt))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer(minLength: 8)
                            if let grade = climb.gradeLabel {
                                Text(grade)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.onAccent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Theme.accentSolid)
                                    .clipShape(Capsule())
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.climb.\(index)")
                }
            }
        }
    }

    // MARK: - Actions

    /// The climb's photo thumbnail when it has one (M3, US-17): AsyncImage decodes off
    /// the main thread and the URL comes from the shared ClimbThumbnailsModel lookup,
    /// so rows cost one map read and the list keeps scrolling smoothly.
    @ViewBuilder
    private func climbThumbnail(_ climbId: String) -> some View {
        if let url = thumbnails.thumbURL(for: climbId) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
        }
    }

    private func startSession() {
        do {
            let session = try store.startSession()
            actionError = nil
            offerOpenExisting = false
            overview.refresh()
            path.append(SessionsRoute.sessionDetail(sessionId: session.id, climbId: nil))
        } catch let error as DomainValidationError {
            surfaceStartError(error)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Surfaces a start failure; the one open session rule gets an "Open existing
    /// session" action so the user can recover in one tap (docs/architecture.md M2).
    private func surfaceStartError(_ error: DomainValidationError) {
        if error.code == "open_session_exists" {
            // startSession already adopted the existing session into the store.
            store.refresh()
            actionError = nil
            offerOpenExisting = true
            return
        }
        actionError = error.message
        offerOpenExisting = false
    }

    private func openExistingSession() {
        store.refresh()
        guard let session = store.openSession else {
            actionError = "No open session found. Start a session to keep logging."
            offerOpenExisting = false
            return
        }
        actionError = nil
        offerOpenExisting = false
        path.append(SessionsRoute.sessionDetail(sessionId: session.id, climbId: nil))
    }
}

/// GitHub style consistency grid: one column per week, one row per weekday (Sunday at the
/// top), filled by how many sessions started that day. Future days in the current week are
/// drawn as holes so the calendar does not claim days that have not happened yet.
private struct SessionHeatmap: View {
    let columns: [[HomeOverviewStore.HeatmapDay]]

    private let cell: CGFloat = 12
    private let spacing: CGFloat = 3

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            weekdayLabels
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: spacing) {
                        ForEach(week) { day in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(day.isFuture ? Color.clear : color(for: day.count))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heatmapAccessibilityLabel)
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: spacing) {
            ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { label in
                Text(label)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 8, height: cell)
            }
        }
        .accessibilityHidden(true)
    }

    private func color(for count: Int) -> Color {
        switch count {
        case 0: return Theme.surfaceRaised
        case 1: return Theme.accent.opacity(0.45)
        case 2: return Theme.accent.opacity(0.75)
        default: return Theme.accent
        }
    }

    private var heatmapAccessibilityLabel: String {
        let total = columns.joined().filter { !$0.isFuture }.map(\.count).reduce(0, +)
        return "Session consistency, \(total) sessions in \(columns.count) weeks"
    }
}
