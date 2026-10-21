import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Problems catalog list (UI overhaul): the fifth tab. A problem is a climb under another
// name, so this screen is the catalog surface for the same rows the quick log uses, with
// the detail the catalog needs (grade, details, photo, attempt history) rather than the
// quick log's one tap. Adding and editing reuse ClimbEditorView with the "problem" noun.

struct ProblemsCatalogView: View {
    let services: AppServices

    @EnvironmentObject private var logbook: LogbookStore
    @EnvironmentObject private var thumbnails: ClimbThumbnailsModel
    @StateObject private var store: ProblemCatalogStore

    init(services: AppServices) {
        self.services = services
        _store = StateObject(wrappedValue: ProblemCatalogStore(repos: services.repos))
    }

    var body: some View {
        Screen {
            if let message = store.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("problems.error")
            }

            gymPicker

            if store.rows.isEmpty {
                emptyState
            } else {
                SectionTitle("Catalog")
                ForEach(store.rows) { row in
                    NavigationLink(value: ProblemsRoute.problemDetail(climbId: row.id)) {
                        ProblemCard(row: row, thumbnailURL: thumbnails.thumbURL(for: row.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("problems.row.\(row.id)")
                }

                Card {
                    Toggle("Show archived problems", isOn: $store.includeArchived)
                        .tint(Theme.accentSolid)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityIdentifier("problems.show-archived")
                }
            }
        }
        .accessibilityIdentifier("problems.screen")
        .navigationTitle("Problems")
        .onAppear {
            thumbnails.refresh()
            store.refresh(gymId: logbook.selectedGymId)
        }
        .onChange(of: logbook.selectedGymId) { _ in
            store.refresh(gymId: logbook.selectedGymId)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var gymPicker: some View {
        if logbook.gyms.isEmpty {
            Card {
                EmptyState(
                    systemImage: "building.2",
                    title: "No gyms yet",
                    message: "Add a gym in Settings before adding problems."
                )
            }
            .accessibilityIdentifier("problems.no-gyms")
        } else {
            Card {
                // A Menu rather than a menu style Picker: the picker's value label wraps to
                // two lines for a long gym name and overlaps the row below, so the row lays
                // the name out itself with one line and an explicit chevron.
                HStack(spacing: 12) {
                    Text("Gym")
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(logbook.gyms) { gym in
                            Button {
                                logbook.selectGym(gym.id)
                            } label: {
                                if gym.id == logbook.selectedGymId {
                                    Label(gym.name, systemImage: "checkmark")
                                } else {
                                    Text(gym.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(logbook.selectedGym?.name ?? "Select gym")
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(Theme.accent)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("problems.gym")
                }
                Divider()
                    .overlay(Theme.separator)
                    .padding(.vertical, 6)
                NavigationLink(value: ProblemsRoute.newProblem) {
                    Row(title: "Add problem", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("problems.add")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        SectionTitle("Catalog")
        Card {
            EmptyState(
                systemImage: "square.grid.2x2",
                title: store.includeArchived ? "No problems here" : "No problems yet",
                message: "A problem keeps its grade, details, photo, and the full history of every attempt on it."
            )
            .accessibilityIdentifier("problems.empty")
        }
        // The add row lives in the header card, so the empty state only explains what a
        // problem holds and points at it.
        Text("Use Add problem above to start the catalog.")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// One catalog row: photo thumbnail (or a grade tile when there is no photo), name, grade,
/// details preview, and the attempt rollup. Archiving leaves the row in place when archived
/// problems are visible, with an Archived tag rather than a hidden state.
struct ProblemCard: View {
    let row: ProblemRow
    let thumbnailURL: URL?

    private var climb: Climb { row.climb }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(2)
                            .accessibilityIdentifier("problems.row.\(row.id).name")
                        Spacer(minLength: 4)
                        if let grade = row.gradeLabel {
                            Text(grade)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.accentSolid)
                                .clipShape(Capsule())
                                .accessibilityIdentifier("problems.row.\(row.id).grade")
                        }
                    }
                    if let notes = climb.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                            .accessibilityIdentifier("problems.row.\(row.id).details")
                    }
                    HStack(spacing: 8) {
                        if row.summary.isSent {
                            tag("Sent", color: Theme.success)
                        }
                        if climb.isArchived {
                            tag("Archived", color: Theme.tertiaryText)
                        }
                        Text(DisplayText.attemptCount(row.summary.attemptCount))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("problems.row.\(row.id).attempts")
                    }
                    if let last = row.summary.lastAttemptAt {
                        Text("Last tried \(DisplayDate.string(from: last))")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
        .opacity(climb.isArchived ? 0.7 : 1)
    }

    private var title: String {
        if let name = climb.name, !name.isEmpty {
            return name
        }
        return row.gradeLabel.map { "Untitled \($0)" } ?? "Untitled problem"
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let url = thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    photoPlaceholder
                }
            } else {
                photoPlaceholder
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var photoPlaceholder: some View {
        ZStack {
            Theme.surfaceRaised
            Image(systemName: "figure.climbing")
                .font(.title3)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}
