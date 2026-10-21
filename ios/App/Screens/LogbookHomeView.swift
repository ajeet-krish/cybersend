import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Logbook home (M2 Task 4, US-8 to US-12): the session card, gym chips with the persisted
// default selection (settings key settingsKeyDefaultGymID), and the quick log climb list
// that pushes the open session screen with the climb preselected. Quick log budget
// (docs/architecture.md M2): from the home screen an attempt costs at most 4 taps, the
// same flow the QuickLogSmokeTests tap accounting encodes.

struct LogbookHomeView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var store: LogbookStore
    @EnvironmentObject private var thumbnails: ClimbThumbnailsModel

    @State private var actionError: String?
    @State private var offerOpenExisting = false

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

            SectionTitle("Gym")
            gymCard

            SectionTitle("Quick log")
            quickLogCard
        }
        .accessibilityIdentifier("logbook.screen")
        .onAppear {
            store.refresh()
            thumbnails.refresh()
        }
    }

    // MARK: - Session card

    @ViewBuilder
    private var sessionCard: some View {
        Card {
            if let session = store.openSession {
                Row(title: "Session in progress", detail: "Started \(DisplayDate.string(from: session.startedAt))")
                Chip("Open", emphasized: true)
                    .accessibilityIdentifier("logbook.session.badge")
            } else {
                EmptyState(
                    systemImage: "figure.climbing",
                    title: "No open session",
                    message: "Start a session at your gym to begin logging attempts."
                )
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

    // MARK: - Gym chips

    @ViewBuilder
    private var gymCard: some View {
        Card {
            if store.gyms.isEmpty {
                EmptyState(
                    systemImage: "building.2",
                    title: "No gyms yet",
                    message: "Add a gym to attach sessions and climbs to it."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.gyms) { gym in
                            let selected = gym.id == store.selectedGymId
                            Button {
                                store.selectGym(gym.id)
                            } label: {
                                Chip(gym.name, emphasized: selected)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("logbook.gym.chip.\(gym.id)")
                            .accessibilityLabel(gym.name)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                }
            }
            NavigationLink(value: LogbookRoute.gyms) {
                Row(title: "Manage gyms", systemImage: "building.2")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("logbook.manage-gyms")
        }
    }

    // MARK: - Quick log climbs

    @ViewBuilder
    private var quickLogCard: some View {
        Card {
            if store.quickLogClimbs.isEmpty {
                EmptyState(
                    systemImage: "figure.climbing",
                    title: "No quick log climbs",
                    message: "Active, not archived climbs of the selected gym appear here."
                )
            } else {
                ForEach(store.quickLogClimbs) { climb in
                    let title = DisplayText.climbTitle(climb, systems: store.gradeSystems)
                    NavigationLink(value: LogbookRoute.climbDetail(climbId: climb.id)) {
                        HStack(spacing: 10) {
                            climbThumbnail(climb.id)
                            Text(title)
                                .foregroundStyle(Theme.primaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("logbook.climb.row.\(climb.id)")
                    .accessibilityLabel(title)
                }
            }
            NavigationLink(value: LogbookRoute.climbDetail(climbId: "new")) {
                Row(title: "Add climb", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("logbook.add-climb")
            NavigationLink(value: LogbookRoute.grades) {
                Row(title: "Grade schemes", systemImage: "chart.line.uptrend.xyaxis")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("logbook.grade-schemes")
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
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
        }
    }

    private func startSession() {
        do {
            let session = try store.startSession()
            actionError = nil
            offerOpenExisting = false
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
