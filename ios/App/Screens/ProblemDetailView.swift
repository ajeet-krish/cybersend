import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Problem detail (UI overhaul): the catalog's per problem view. Photo, grade, details, and
// the complete attempt history, plus edit and archive. It reuses ClimbEditorView for the
// edit form so a problem has exactly one editor, and it never deletes: archiving keeps the
// history that this screen exists to show.

struct ProblemDetailView: View {
    let climbId: String
    let services: AppServices

    @EnvironmentObject private var logbook: LogbookStore
    @EnvironmentObject private var thumbnails: ClimbThumbnailsModel
    @StateObject private var store: ProblemDetailStore
    @State private var actionError: String?
    @State private var showHoldStats = false

    init(climbId: String, services: AppServices) {
        self.climbId = climbId
        self.services = services
        _store = StateObject(wrappedValue: ProblemDetailStore(repos: services.repos, climbId: climbId))
    }

    var body: some View {
        Screen {
            if let message = actionError ?? store.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("problem.error")
            }

            if let climb = store.climb {
                header(climb)
                holdStatsRow
                notes(climb)
                history
                manage(climb)
            }
        }
        .accessibilityIdentifier("problem.screen")
        .navigationTitle(store.climb?.name ?? "Problem")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showHoldStats) {
            HoldStatsSheet(
                holds: store.holds,
                roleCounts: store.holdRoleCounts,
                photoURL: store.photo.flatMap { photoURL($0) }
            )
        }
        .onAppear {
            store.refresh()
            thumbnails.refresh()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ climb: Climb) -> some View {
        if let photo = store.photo, let url = photoURL(photo) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.surfaceRaised)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
            .accessibilityIdentifier("problem.photo")
        }

        Card {
            if let gymName = store.gymName {
                Text(gymName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .accessibilityIdentifier("problem.gym")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(climb.name ?? "Untitled problem")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityIdentifier("problem.name")
                Spacer(minLength: 4)
                if let grade = store.gradeLabel {
                    Text(grade)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.accentSolid)
                        .clipShape(Capsule())
                        .accessibilityIdentifier("problem.grade")
                }
            }
            HStack(spacing: 10) {
                if let angle = climb.angleDeg {
                    Text("\(Int(angle)) degrees")
                        .accessibilityIdentifier("problem.angle")
                }
                if let color = climb.colorCircuit, !color.isEmpty {
                    Text(color.capitalized)
                        .accessibilityIdentifier("problem.color")
                }
                if climb.isArchived {
                    Text("Archived")
                        .foregroundStyle(Theme.warning)
                        .accessibilityIdentifier("problem.archived")
                }
                Spacer(minLength: 8)
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)

            if !climb.categories.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(climb.categories, id: \.self) { category in
                        Chip(category.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
                .accessibilityIdentifier("problem.categories")
            }
        }
    }

    // MARK: - Hold stats

    /// Read only hold stats. Tagging itself only lives in the problem editor, so the detail
    /// screen reports what is tagged rather than opening the canvas.
    private var holdStatsRow: some View {
        Card {
            Button {
                showHoldStats = true
            } label: {
                Row(
                    title: "View hold stats",
                    detail: store.holds.isEmpty ? "No holds tagged" : "\(store.holds.count) holds",
                    systemImage: "hand.tap"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("problem.holds")
        }
    }

    // MARK: - Notes

    private func notes(_ climb: Climb) -> some View {
        Group {
            SectionTitle("Notes")
            Card {
                if let notes = climb.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityIdentifier("problem.details")
                } else {
                    Text("No details yet. Edit this problem to add beta, style, or anything worth remembering.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("problem.details.empty")
                }
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var history: some View {
        SectionTitle("History")
        Card {
            if store.attempts.isEmpty {
                Text("No attempts yet. Log one from an open session and it shows up here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("problem.history.empty")
            } else {
                Text(historySummary)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("problem.history.summary")
                Divider()
                    .overlay(Theme.separator)
                    .padding(.vertical, 6)
                ForEach(Array(store.attempts.enumerated()), id: \.element.id) { index, attempt in
                    if index > 0 {
                        Divider()
                            .overlay(Theme.separator)
                            .padding(.vertical, 6)
                    }
                    historyRow(attempt, index: index)
                }
            }
        }
    }

    private var historySummary: String {
        let sends = store.sendCount
        let total = store.attempts.count
        let sendText = sends == 0 ? "Not sent yet" : (sends == 1 ? "Sent once" : "Sent \(sends) times")
        return "\(sendText), \(DisplayText.attemptCount(total))"
    }

    private func historyRow(_ attempt: Attempt, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(DisplayText.outcomeTitle(attempt.outcome))
                .font(.caption.weight(.semibold))
                .foregroundStyle(attempt.outcome.themeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(attempt.outcome.themeColor.opacity(0.15))
                .clipShape(Capsule())
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayDate.string(from: attempt.attemptedAt))
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityIdentifier("problem.history.\(index).date")
                if let notes = attempt.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("problem.history.\(index).notes")
                }
            }
            Spacer(minLength: 8)
            if let rpe = attempt.rpe {
                Text("RPE \(rpe)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("problem.history.\(index).rpe")
            }
        }
    }

    // MARK: - Manage

    private func manage(_ climb: Climb) -> some View {
        Group {
            SectionTitle("Manage")
            Card {
                NavigationLink(value: ProblemsRoute.editProblem(climbId: climb.id)) {
                    Row(title: "Edit problem", systemImage: "pencil")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("problem.edit")

                Divider()
                    .overlay(Theme.separator)
                    .padding(.vertical, 6)

                SecondaryButton(climb.isArchived ? "Unarchive problem" : "Archive problem") {
                    toggleArchive()
                }
                .padding(.top, 10)
                .accessibilityIdentifier("problem.archive")
                Text("Archiving keeps every attempt. Unarchive to bring it back to the catalog.")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Helpers

    private func photoURL(_ photo: Photo) -> URL? {
        let uri = photo.uri
        return try? services.media.storage.url(relativeURI: uri)
    }

    private func toggleArchive() {
        do {
            try store.setArchived(!store.isArchived)
            actionError = nil
            logbook.refresh()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

}

// Read only hold stats (UI overhaul): what is tagged on this problem, by role and by
// position. Tagging itself stays in the problem editor, so this sheet reports and never
// edits.
private struct HoldStatsSheet: View {
    let holds: [Hold]
    let roleCounts: [(title: String, count: Int)]
    let photoURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Screen {
                if let photoURL {
                    AsyncImage(url: photoURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                            .fill(Theme.surfaceRaised)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                    .accessibilityIdentifier("problem.holds.photo")
                }

                if holds.isEmpty {
                    Card {
                        EmptyState(
                            systemImage: "hand.tap",
                            title: "No holds tagged",
                            message: "Edit the problem to tag the holds on this wall photo."
                        )
                    }
                    .accessibilityIdentifier("problem.holds.empty")
                } else {
                    Card {
                        ForEach(Array(roleCounts.enumerated()), id: \.offset) { index, entry in
                            if index > 0 {
                                Divider()
                                    .overlay(Theme.separator)
                                    .padding(.vertical, 4)
                            }
                            HStack {
                                Text(entry.title)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.primaryText)
                                Spacer(minLength: 8)
                                Text("\(entry.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .accessibilityIdentifier("problem.holds.count.\(entry.title.lowercased())")
                        }
                    }

                    SectionTitle("Tagged holds")
                    Text("Position is percent across, then percent down the photo.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Card {
                        ForEach(Array(holds.enumerated()), id: \.element.id) { index, hold in
                            if index > 0 {
                                Divider()
                                    .overlay(Theme.separator)
                                    .padding(.vertical, 4)
                            }
                            Row(
                                title: "Hold \(index + 1)",
                                detail: "\(roleTitle(hold.role)) · \(percent(hold.xNorm)), \(percent(hold.yNorm))",
                                systemImage: "circle.dashed"
                            )
                        }
                    }
                }
            }
            .navigationTitle("Hold stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func roleTitle(_ role: HoldRole?) -> String {
        switch role {
        case .start: return "Start"
        case .intermediate: return "Intermediate"
        case .top: return "Top"
        case nil: return "Unassigned"
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
