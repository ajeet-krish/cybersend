import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Problems catalog list (UI overhaul): the fifth tab. A problem is a climb under another
// name, so this screen is the catalog surface for the same rows the quick log uses, with
// the detail the catalog needs (grade, gym, categories, photo, attempt history) rather than
// the quick log's one tap. Adding and editing reuse ClimbEditorView with the "problem" noun.
// The catalog spans every gym and narrows with the filter bar (gym, level, category, climb
// status) rather than following the logbook's selected gym, which is what makes the gym of a
// row and the gym filter worth showing.

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

            addCard

            if !store.gyms.isEmpty {
                filterBar
            }

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
            }

            if !store.allRows.isEmpty {
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
            store.refresh()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var addCard: some View {
        if !store.gyms.isEmpty {
            Card {
                NavigationLink(value: ProblemsRoute.newProblem) {
                    Row(title: "Add problem", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("problems.add")
            }
        } else {
            Card {
                EmptyState(
                    systemImage: "building.2",
                    title: "No gyms yet",
                    message: "Add a gym in Settings before adding problems."
                )
            }
            .accessibilityIdentifier("problems.no-gyms")
        }
    }

    // MARK: - Filters

    /// Four menu chips in a wrapping row: gym, level, category, and climb status. They did
    /// not fit one phone width in a scrolling strip, so the fourth filter (status) was
    /// hidden off screen; wrapping keeps all four visible and each chip still shows its
    /// current value so an active filter can be read without opening it.
    private var filterBar: some View {
        FlowLayout(spacing: 8) {
            Menu {
                Button("All gyms") { store.filterGymId = nil }
                ForEach(store.gyms) { gym in
                    Button(gym.name) { store.filterGymId = gym.id }
                }
            } label: {
                filterChip(store.gymFilterTitle, active: store.filterGymId != nil)
            }
            .accessibilityIdentifier("problems.filter.gym")

            Menu {
                Button("Any level") { store.filterLevelId = nil }
                ForEach(store.levelOptions) { option in
                    Button(option.label) { store.filterLevelId = option.id }
                }
            } label: {
                filterChip(store.levelFilterTitle, active: store.filterLevelId != nil)
            }
            .accessibilityIdentifier("problems.filter.level")

            Menu {
                Button("Any category") { store.filterCategory = nil }
                ForEach(climbCategories, id: \.self) { category in
                    Button(category.title) { store.filterCategory = category }
                }
            } label: {
                filterChip(store.categoryFilterTitle, active: store.filterCategory != nil)
            }
            .accessibilityIdentifier("problems.filter.category")

            Menu {
                ForEach(ClimbStatusFilter.allCases) { status in
                    Button(status.title) { store.filterStatus = status }
                }
            } label: {
                filterChip(store.filterStatus.title, active: store.filterStatus != .all)
            }
            .accessibilityIdentifier("problems.filter.status")
        }
        .accessibilityIdentifier("problems.filters")
    }

    private func filterChip(_ title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(active ? Theme.accentSolid : Theme.surfaceRaised)
        .foregroundStyle(active ? Theme.onAccent : Theme.primaryText)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var emptyState: some View {
        SectionTitle("Catalog")
        if store.hasActiveFilters {
            Card {
                EmptyState(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "No problems match",
                    message: "Clear the filters to see the rest of the catalog."
                )
                .accessibilityIdentifier("problems.empty.filtered")
                SecondaryButton("Clear filters") {
                    store.clearFilters()
                }
                .accessibilityIdentifier("problems.clear-filters")
            }
        } else {
            Card {
                EmptyState(
                    systemImage: "square.grid.2x2",
                    title: store.includeArchived ? "No problems here" : "No problems yet",
                    message: "A problem keeps its gym, grade, categories, photo, and the full history of every attempt on it."
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
}

/// One catalog row: photo thumbnail (or a grade tile when there is no photo), name, grade,
/// gym, categories, and the attempt rollup. Categories replace the free text notes preview
/// because they are what the catalog is scanned for. Archiving leaves the row in place when
/// archived problems are visible, with an Archived tag rather than a hidden state.
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
                    if let gymName = row.gymName {
                        Text(gymName)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("problems.row.\(row.id).gym")
                    }
                    if !climb.categories.isEmpty {
                        Text(climb.categories.map(\.title).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                            .accessibilityIdentifier("problems.row.\(row.id).categories")
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
                            .accessibilityIdentifier("problems.row.\(row.id).last-tried")
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
