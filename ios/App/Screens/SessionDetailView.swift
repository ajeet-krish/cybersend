import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Session screen (M2 Task 4), the quick log surface (docs/decisions.md 2026-10-20: quick
// log lives on the open session screen, port of app/session/[id].tsx).
//
// Open state (US-11, US-12): pick a climb, set an optional per attempt effort, tap an
// outcome and the tap saves; fail prompts for the fall hold with a skip (worst case 5 taps
// from the logbook home when the climb changes, 3 when it is already selected, enforced by
// the QuickLogSmokeTests tap accounting); flash is disabled once the selected
// climb has an attempt this session (flash implies first attempt send, US-12.2); closing
// goes through the close sheet with an RPE stepper 1 to 10 and notes (US-11.1) and writes
// an automatic backup (docs/architecture.md backup hooks).
//
// Closed state (US-22): attempts grouped per climb with outcome and fall hold labels,
// edit (outcome and notes) and delete behind confirmation, delete session behind a
// destructive confirmation.

struct SessionDetailView: View {
    let sessionId: String
    let initialClimbId: String?
    let services: AppServices

    @EnvironmentObject private var logbook: LogbookStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: SessionDetailStore
    @StateObject private var transient = TransientNoticeModel()

    @State private var pendingFall: FallRequest?
    /// Effort for the next quick logged attempt. Nil means unrated, and a successful
    /// log clears it so each attempt starts blank rather than inheriting the last one.
    @State private var attemptRPE: Int?
    @State private var showCloseSheet = false
    @State private var editingAttempt: Attempt?
    @State private var pendingAttemptDelete: Attempt?
    @State private var confirmSessionDelete = false
    @State private var actionError: String?
    /// Inline climb editor: create a problem for this session's gym, or edit the selected
    /// one, without leaving the session screen.
    @State private var editorTarget: SessionClimbEditorTarget?

    init(sessionId: String, services: AppServices, initialClimbId: String? = nil) {
        self.sessionId = sessionId
        self.services = services
        self.initialClimbId = initialClimbId
        _store = StateObject(wrappedValue: SessionDetailStore(repos: services.repos, sessionId: sessionId))
    }

    var body: some View {
        Screen {
            if let message = actionError ?? store.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("session.error")
            }
            if let warning = transient.message {
                ErrorNote(warning)
                    .accessibilityIdentifier("session.warning")
            }
            if let session = store.session {
                header(session)
                if isSessionOpen(session) {
                    // Quick log first while the session is live: the outcome buttons must
                    // stay near the thumb at the wall. Media sits under the attempt list.
                    openSessionContent
                    SessionMediaSection(sessionId: session.id, services: services)
                } else {
                    // A closed session is the retroactive media path, so the gallery leads.
                    SessionMediaSection(sessionId: session.id, services: services)
                    closedSessionContent
                }
            } else {
                EmptyState(
                    systemImage: "calendar",
                    title: "Session not found",
                    message: "This session was deleted."
                )
            }
        }
        .accessibilityIdentifier("session.screen")
        .navigationTitle("Session")
        .onAppear {
            // A session starts with the climbs it already has attempts on, plus the climb the
            // quick log was opened for. With neither, the Add Climb button is the first move.
            store.refresh()
            if let initialClimbId {
                store.addClimb(id: initialClimbId)
            }
        }
        .sheet(item: $pendingFall) { request in
            FallHoldSheet(
                climbTitle: store.selectedClimb.map { DisplayText.climbTitle($0, systems: logbook.gradeSystems) } ?? "Climb",
                climbId: store.selectedClimbId ?? "",
                outcome: request.outcome,
                holds: holdsForSelectedClimb(),
                services: services
            ) { holdId in
                pendingFall = nil
                logAttempt(request.outcome, fallOnHoldId: holdId, rpe: request.rpe)
            }
        }
        .sheet(isPresented: $showCloseSheet) {
            CloseSessionSheet(existingRPE: store.session?.rpe, existingNotes: store.session?.notes) { rpe, notes in
                showCloseSheet = false
                closeSession(rpe: rpe, notes: notes)
            }
        }
        .sheet(item: $editorTarget) { target in
            NavigationStack {
                ClimbEditorView(
                    climbId: target.climbId,
                    services: services,
                    noun: "problem",
                    gymId: store.session?.gymId,
                    keepsOpenAfterCreate: true,
                    onSaved: { saved in
                        // The row exists the moment it is saved: refresh the quick log list
                        // and add the new or edited problem to the session, targeted for the
                        // next attempt.
                        store.refresh()
                        store.addClimb(saved)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            editorTarget = nil
                        }
                        .accessibilityIdentifier("climb.close")
                    }
                }
            }
        }
        .sheet(item: $editingAttempt) { attempt in
            EditAttemptSheet(
                attempt: attempt,
                climbId: attempt.climbId,
                holds: holdsForClimb(attempt.climbId),
                services: services
            ) { outcome, notes, fallOnHoldId, rpe in
                editingAttempt = nil
                updateAttempt(attempt, outcome: outcome, notes: notes, fallOnHoldId: fallOnHoldId, rpe: rpe)
            }
        }
        .confirmationDialog(
            "Delete this attempt?",
            isPresented: attemptDeleteBinding,
            presenting: pendingAttemptDelete
        ) { attempt in
            Button("Delete attempt", role: .destructive) {
                deleteAttempt(attempt)
            }
            Button("Cancel", role: .cancel) {}
        } message: { attempt in
            Text("Attempt \(attempt.attemptNo) is removed from this session.")
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $confirmSessionDelete
        ) {
            Button("Delete session", role: .destructive) {
                deleteSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session and every attempt in it are removed. This cannot be undone.")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ session: Session) -> some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.gym?.name ?? "Unknown gym")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityIdentifier("session.gym")
                    Text("Started \(DisplayDate.string(from: session.startedAt))")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("session.started")
                }
                Spacer(minLength: 8)
                if isSessionOpen(session) {
                    Chip("Open", emphasized: true)
                        .accessibilityIdentifier("session.badge")
                } else if let rpe = DisplayText.rpe(session.rpe) {
                    Chip(rpe, emphasized: true)
                        .accessibilityIdentifier("session.rpe")
                }
            }
            if let ended = session.endedAt {
                Text("Ended \(DisplayDate.string(from: ended))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("session.ended")
            }
            if let notes = session.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("session.notes")
            }
        }
    }

    // MARK: - Open session (quick log)

    @ViewBuilder
    private var openSessionContent: some View {
        // The climb list leads: each climb added to this session is a row (workout app
        // style), the selected one is the quick log target, and the three actions sit side
        // by side under it.
        SectionTitle("Climbs")
        if store.sessionClimbs.isEmpty {
            Card {
                EmptyState(
                    systemImage: "figure.climbing",
                    title: "No climbs yet",
                    message: "Add the climbs you are working on, then log attempts against them."
                )
                .accessibilityIdentifier("session.climbs.empty")
            }
        } else {
            ForEach(store.sessionClimbs) { climb in
                sessionClimbCard(climb)
            }
        }

        HStack(spacing: 10) {
            Menu {
                let available = availableClimbs
                if available.isEmpty {
                    Text("Every climb is already added")
                } else {
                    ForEach(available) { climb in
                        Button(climbTitle(climb)) {
                            store.addClimb(climb)
                        }
                    }
                }
            } label: {
                sessionActionLabel("Add Climb", systemImage: "plus")
            }
            .accessibilityIdentifier("session.climb.add")

            Button {
                if let climbId = store.selectedClimbId {
                    editorTarget = .edit(climbId)
                }
            } label: {
                sessionActionLabel(
                    "Edit Problem",
                    systemImage: "pencil",
                    enabled: store.selectedClimbId != nil
                )
            }
            .disabled(store.selectedClimbId == nil)
            .accessibilityIdentifier("session.climb.edit")

            Button {
                editorTarget = .new
            } label: {
                sessionActionLabel("New Problem", systemImage: "plus.square")
            }
            .accessibilityIdentifier("session.climb.new")
        }

        SectionTitle("Log attempt")
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(selectedClimbName)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityIdentifier("session.climb.target")
                Spacer(minLength: 8)
                if let grade = selectedClimbGrade {
                    Text(grade)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("session.climb.selected-grade")
                }
            }
            HStack(spacing: 10) {
                outcomeButton(.flash)
                outcomeButton(.send)
                outcomeButton(.fail)
            }
            Divider()
                .overlay(Theme.separator)
            HStack {
                Text("Effort")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                EffortPicker(rpe: $attemptRPE)
                    .accessibilityIdentifier("session.attempt-rpe")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.outcomes")

        SectionTitle("Attempts")
        Card {
            if recentAttempts.isEmpty {
                EmptyState(
                    systemImage: "list.number",
                    title: "No attempts yet",
                    message: "Tap an outcome to log your first attempt."
                )
            } else {
                Text(DisplayText.attemptCount(recentAttempts.count))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("session.attempts.count")
                ForEach(attemptRows(recentAttempts)) { row in
                    attemptRowLink(row, index: row.index)
                    if row.index < recentAttempts.count - 1 {
                        Divider()
                            .overlay(Theme.separator)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.attempt-list")

        PrimaryButton("Close session") {
            showCloseSheet = true
        }
        .accessibilityIdentifier("session.close")
    }

    /// One climb in the session: name, grade, categories, and how it has gone so far. The
    /// whole row selects the climb for the next attempt; a climb with no attempts can be
    /// removed, one with attempts cannot because its attempts are part of the session.
    private func sessionClimbCard(_ climb: Climb) -> some View {
        let selected = climb.id == store.selectedClimbId
        let attempts = store.group(forClimb: climb.id)?.attempts ?? []
        return Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.footnote)
                    .foregroundStyle(selected ? Theme.accent : Theme.tertiaryText)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    // The grade is the chip below, so the title stays the name alone.
                    Text(climb.name ?? "Untitled climb")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                        .accessibilityIdentifier(selected ? "session.climb.selected" : "session.climb.name.\(climb.id)")
                    HStack(spacing: 6) {
                        if let grade = DisplayText.grade(climb, systems: logbook.gradeSystems) {
                            Chip(grade)
                        }
                        if !climb.categories.isEmpty {
                            Text(climb.categories.map(\.title).joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .accessibilityIdentifier("session.climb.categories.\(climb.id)")
                        }
                    }
                    Text(climbProgress(attempts))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("session.climb.progress.\(climb.id)")
                }
                Spacer(minLength: 8)
                if attempts.isEmpty {
                    Button {
                        store.removeClimb(id: climb.id)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("session.climb.remove.\(climb.id)")
                    .accessibilityLabel("Remove \(climbTitle(climb)) from this session")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectClimb(climb)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("session.climb.row.\(climb.id)")
    }

    /// The disabled state is drawn here rather than left to `.disabled`: the label sets its
    /// own foregroundStyle, so a disabled action would otherwise still look active.
    private func sessionActionLabel(
        _ title: String,
        systemImage: String,
        enabled: Bool = true
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.surfaceRaised)
        .foregroundStyle(enabled ? Theme.accent : Theme.tertiaryText)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var availableClimbs: [Climb] {
        let added = Set(store.sessionClimbs.map(\.id))
        return store.climbs.filter { !added.contains($0.id) }
    }

    private func climbProgress(_ attempts: [Attempt]) -> String {
        guard !attempts.isEmpty else { return "Not tried yet" }
        guard let last = attempts.last else { return "Not tried yet" }
        let count = DisplayText.attemptCount(attempts.count)
        let sent = attempts.contains { $0.outcome == .send || $0.outcome == .flash }
        return "\(count) · \(DisplayText.outcomeTitle(last.outcome))\(sent ? " · Sent" : "")"
    }

    /// One attempt line, climb name first, then the result, effort, and fall details. Tapping
    /// the row opens the edit sheet while the session is open, so an attempt can be corrected
    /// on the spot (outcome, effort, fall hold, notes) instead of only after it closes.
    private func attemptRowLink(_ row: IndexedAttempt, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(openAttemptLabel(row.attempt))
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("session.attempt.\(index)")
            Button {
                editingAttempt = row.attempt
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session.attempt.\(index).edit")
            .accessibilityLabel("Edit attempt \(row.attempt.attemptNo)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingAttempt = row.attempt
        }
    }

    private var selectedClimbName: String {
        store.selectedClimb?.name ?? "Select climb"
    }

    private var selectedClimbGrade: String? {
        guard let climb = store.selectedClimb else { return nil }
        return DisplayText.grade(climb, systems: logbook.gradeSystems)
    }

    private func climbTitle(_ climb: Climb) -> String {
        DisplayText.climbTitle(climb, systems: logbook.gradeSystems)
    }

    /// Outcome coloured, not accent coloured: three equally purple buttons read as three
    /// identical primary actions and invite a mis tap, while the outcome colours match the
    /// badges on the attempt rows and in problem history. The soft tint keeps the label
    /// readable in both appearances (contrast is measured on the badge tint in
    /// docs/decisions.md).
    private func outcomeButton(_ outcome: AttemptOutcome) -> some View {
        let enabled = outcomeEnabled(outcome)
        return Button {
            outcomeTapped(outcome)
        } label: {
            Text(DisplayText.outcomeTitle(outcome))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(outcome.themeColor.opacity(enabled ? 0.18 : 0.06))
                .foregroundStyle(enabled ? outcome.themeColor : Theme.tertiaryText)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(outcome.themeColor.opacity(enabled ? 0.45 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("outcome.\(outcome.rawValue)")
    }

    // MARK: - Closed session (history detail)

    @ViewBuilder
    private var closedSessionContent: some View {
        SectionTitle("Attempts")
        if store.groups.isEmpty {
            Card {
                EmptyState(
                    systemImage: "list.number",
                    title: "No attempts",
                    message: "This session has no logged attempts."
                )
            }
        } else {
            ForEach(indexedGroups) { item in
                groupCard(item.group, index: item.index)
            }
        }

        SecondaryButton("Delete session") {
            confirmSessionDelete = true
        }
        .foregroundStyle(.red)
        .accessibilityIdentifier("session.delete")
    }

    private func groupCard(_ group: ClimbGroup, index: Int) -> some View {
        Card {
            Text(DisplayText.climbTitle(group.climb, systems: logbook.gradeSystems))
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .accessibilityIdentifier("session.group.\(index)")
            ForEach(attemptRows(group.attempts)) { row in
                HStack(spacing: 8) {
                    Button {
                        editingAttempt = row.attempt
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(row.attempt.attemptNo) \(DisplayText.outcomeTitle(row.attempt.outcome))")
                                .font(.subheadline)
                                .foregroundStyle(Theme.primaryText)
                                .accessibilityIdentifier("session.attempt.\(index).\(row.index).title")
                            if let holdText = DisplayText.fallHoldTitle(
                                fallOnHoldId: row.attempt.fallOnHoldId,
                                holds: holdsForClimb(group.climb.id)
                            ) {
                                Text(holdText)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .accessibilityIdentifier("session.attempt.\(index).\(row.index).hold")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("session.attempt.\(index).\(row.index).edit")
                    Button {
                        pendingAttemptDelete = row.attempt
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.warning)
                    }
                    .accessibilityIdentifier("session.attempt.\(index).\(row.index).delete")
                    .accessibilityLabel("Delete attempt \(row.attempt.attemptNo)")
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.group.card.\(index)")
    }

    // MARK: - State helpers

    /// Every attempt of the session, newest first (the open state attempt list).
    private var recentAttempts: [Attempt] {
        store.groups
            .flatMap(\.attempts)
            .sorted { $0.attemptedAt > $1.attemptedAt }
    }

    private struct IndexedAttempt: Identifiable {
        let index: Int
        let attempt: Attempt
        var id: String { attempt.id }
    }

    private struct IndexedGroup: Identifiable {
        let index: Int
        let group: ClimbGroup
        var id: String { group.id }
    }

    private var indexedGroups: [IndexedGroup] {
        store.groups.enumerated().map { index, group in
            IndexedGroup(index: index, group: group)
        }
    }

    private func attemptRows(_ attempts: [Attempt]) -> [IndexedAttempt] {
        attempts.enumerated().map { index, attempt in
            IndexedAttempt(index: index, attempt: attempt)
        }
    }

    /// Attempt text reading climb name first, then the result, effort, and fall hold, so a
    /// flat attempt list stays readable when the session works several problems.
    private func openAttemptLabel(_ attempt: Attempt) -> String {
        var parts = [
            climbName(for: attempt.climbId),
            "#\(attempt.attemptNo) \(DisplayText.outcomeTitle(attempt.outcome))",
        ]
        if let rpeText = DisplayText.rpe(attempt.rpe) {
            parts.append(rpeText)
        }
        if let holdText = DisplayText.fallHoldTitle(fallOnHoldId: attempt.fallOnHoldId, holds: holdsForClimb(attempt.climbId)) {
            parts.append(holdText)
        }
        return parts.joined(separator: " · ")
    }

    private func climbName(for climbId: String) -> String {
        if let climb = store.climbs.first(where: { $0.id == climbId }) {
            return climb.name ?? "Climb"
        }
        if let climb = store.groups.first(where: { $0.climb.id == climbId })?.climb {
            return climb.name ?? "Climb"
        }
        return "Climb"
    }

    private func holdsForClimb(_ climbId: String) -> [Hold] {
        store.climbHolds[climbId] ?? []
    }

    private func holdsForSelectedClimb() -> [Hold] {
        guard let climbId = store.selectedClimbId else { return [] }
        return holdsForClimb(climbId)
    }

    /// Flash is enabled only for the first attempt on the selected climb this session
    /// (US-12.2, flash implies first attempt send; the domain would reject a later flash).
    private var isFirstAttemptOnSelectedClimb: Bool {
        guard let selectedId = store.selectedClimbId else { return false }
        return store.groups.first(where: { $0.climb.id == selectedId })?.attempts.isEmpty ?? true
    }

    private func outcomeEnabled(_ outcome: AttemptOutcome) -> Bool {
        guard store.selectedClimbId != nil else { return false }
        guard outcome == .flash else { return true }
        return isFirstAttemptOnSelectedClimb
    }

    private var attemptDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingAttemptDelete != nil },
            set: { if !$0 { pendingAttemptDelete = nil } }
        )
    }

    // MARK: - Actions

    private func outcomeTapped(_ outcome: AttemptOutcome) {
        switch outcome {
        case .flash, .send:
            logAttempt(outcome, fallOnHoldId: nil, rpe: attemptRPE)
        case .fail:
            // The fall hold prompt: the climb's real holds from climb_holds (M3), with
            // the photo canvas when the climb has a photo; skip saves nil
            // (docs/decisions.md quick log decision).
            pendingFall = FallRequest(outcome: outcome, rpe: attemptRPE)
        }
    }

    private func logAttempt(_ outcome: AttemptOutcome, fallOnHoldId: String?, rpe: Int? = nil) {
        do {
            let warnings = try store.logAttempt(outcome: outcome, fallOnHoldId: fallOnHoldId, rpe: rpe)
            actionError = nil
            attemptRPE = nil
            logbook.refresh()
            if let first = warnings.first {
                transient.show(DisplayText.warningMessage(first))
            }
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func closeSession(rpe: Int?, notes: String?) {
        do {
            try store.closeSession(rpe: rpe, notes: notes)
            actionError = nil
            logbook.refresh()
            writeSessionCloseBackup()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    /// Session close backup hook (docs/architecture.md M2: session close and background
    /// trigger maybeWriteAutomaticBackup, keep 10). Off the main actor with Sendable
    /// values only, best effort: a backup failure never blocks the close, it surfaces as
    /// a transient warning notice.
    private func writeSessionCloseBackup() {
        let repos = services.repos
        let root = services.documentDirectory
        let notice = transient
        Task.detached(priority: .utility) {
            do {
                _ = try maybeWriteAutomaticBackup(repos: repos, documentDirectory: root, trigger: .sessionClose)
            } catch {
                await notice.show("Automatic backup failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateAttempt(
        _ attempt: Attempt,
        outcome: AttemptOutcome,
        notes: String?,
        fallOnHoldId: String?,
        rpe: Int?
    ) {
        do {
            try store.updateAttempt(
                id: attempt.id,
                outcome: .set(outcome),
                fallOnHoldId: .set(fallOnHoldId),
                notes: .set(notes),
                rpe: .set(rpe)
            )
            actionError = nil
            logbook.refresh()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func deleteAttempt(_ attempt: Attempt) {
        do {
            try store.deleteAttempt(id: attempt.id)
            pendingAttemptDelete = nil
            actionError = nil
            logbook.refresh()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func deleteSession() {
        do {
            try store.deleteSession()
            confirmSessionDelete = false
            actionError = nil
            logbook.refresh()
            dismiss()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }
}

/// Transient warning notices (repository warnings and the session close backup failure).
/// Main actor and therefore Sendable, so the detached backup task can surface a warning
/// without capturing the view. The token keeps an older timer from clearing a newer
/// message.
@MainActor
final class TransientNoticeModel: ObservableObject {
    @Published private(set) var message: String?

    private var token = 0

    func show(_ message: String) {
        token &+= 1
        let current = token
        self.message = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.token == current {
                self?.message = nil
            }
        }
    }
}

/// The fail tap that opened the fall hold sheet, carrying the effort already chosen
/// (item based presentation).
private struct FallRequest: Identifiable {
    let outcome: AttemptOutcome
    /// The effort dialled in before tapping Fail, carried through the fall hold sheet so
    /// the attempt is saved with both.
    let rpe: Int?
    var id: String { outcome.rawValue }
}

// MARK: - Fall hold sheet

// The M3 fall hold sheet lives in ios/App/Screens/FallHoldSheet.swift: real climb holds
// from climb_holds with role and ordinal labels, one tap per row, plus the read only
// photo canvas in selection mode when the climb has a wall photo.

// MARK: - Close session sheet

/// Close confirmation with the session RPE stepper (1 to 10, US-11.1) and notes. Closing
/// is idempotent in the repository (US-11.3).
struct CloseSessionSheet: View {
    let onClose: (Int?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rpe: Int
    @State private var notes: String

    init(existingRPE: Int?, existingNotes: String?, onClose: @escaping (Int?, String?) -> Void) {
        self.onClose = onClose
        _rpe = State(initialValue: existingRPE ?? 5)
        _notes = State(initialValue: existingNotes ?? "")
    }

    var body: some View {
        NavigationStack {
            Screen {
                SectionTitle("Session RPE")
                Card {
                    Stepper(value: $rpe, in: minRPE...maxRPE) {
                        HStack {
                            Text("RPE")
                            Spacer(minLength: 8)
                            Text("\(rpe)")
                                .foregroundStyle(Theme.secondaryText)
                                .accessibilityIdentifier("close.rpe.value")
                        }
                    }
                    .accessibilityIdentifier("close.rpe.stepper")
                    Text("Rate of perceived exertion from \(minRPE) to \(maxRPE).")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }

                SectionTitle("Notes")
                Card {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                        .themedField()
                        .accessibilityIdentifier("close.notes")
                }
            }
            .accessibilityIdentifier("close.sheet")
            .navigationTitle("Close session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("close.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close session") {
                        onClose(rpe, notes.isEmpty ? nil : notes)
                    }
                    .accessibilityIdentifier("close.confirm")
                }
            }
        }
    }
}

// MARK: - Edit attempt sheet

/// Edit an attempt's outcome, fall hold, and notes (US-22.3, M3 wires the fall hold
/// picker to the climb's real holds). Outcome and fall hold are revalidated against the
/// domain rules exactly like a fresh log; notes edit with patch semantics (clearing the
/// field clears the stored value). Sends never record a fall hold: the domain drops the
/// value with a warning, and the sheet says so up front.
/// Compact 1 to 10 effort picker shared by the quick log card and the edit sheet. A menu
/// keeps ten values to one tap without a row of ten chips, and the None case stays
/// explicit so an unrated attempt reads as a choice rather than a missing value.
struct EffortPicker: View {
    @Binding var rpe: Int?
    var title = "Effort"

    var body: some View {
        Picker(title, selection: $rpe) {
            Text("None").tag(Int?.none)
            ForEach(1...10, id: \.self) { value in
                Text("RPE \(value)").tag(Int?.some(value))
            }
        }
        .pickerStyle(.menu)
        .tint(Theme.accent)
    }
}

struct EditAttemptSheet: View {
    let attempt: Attempt
    let climbId: String
    let holds: [Hold]
    let services: AppServices
    let onSave: (AttemptOutcome, String?, String?, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var outcome: AttemptOutcome
    @State private var notes: String
    @State private var fallOnHoldId: String?
    @State private var rpe: Int?
    @State private var showFallSheet = false

    init(
        attempt: Attempt,
        climbId: String,
        holds: [Hold],
        services: AppServices,
        onSave: @escaping (AttemptOutcome, String?, String?, Int?) -> Void
    ) {
        self.attempt = attempt
        self.climbId = climbId
        self.holds = holds
        self.services = services
        self.onSave = onSave
        _outcome = State(initialValue: attempt.outcome)
        _notes = State(initialValue: attempt.notes ?? "")
        _fallOnHoldId = State(initialValue: attempt.fallOnHoldId)
        _rpe = State(initialValue: attempt.rpe)
    }

    var body: some View {
        NavigationStack {
            Screen {
                SectionTitle("Outcome")
                Card {
                    Picker("Outcome", selection: $outcome) {
                        ForEach(AttemptOutcome.allCases, id: \.self) { option in
                            Text(DisplayText.outcomeTitle(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("attempt.edit.outcome")
                }

                SectionTitle("Effort")
                Card {
                    HStack {
                        Text("Per climb RPE")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        EffortPicker(rpe: $rpe)
                            .accessibilityIdentifier("attempt.edit.rpe")
                    }
                }

                SectionTitle("Fall hold")
                Card {
                    Text(fallHoldTitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("attempt.edit.fall")
                    if holds.isEmpty {
                        Text("Tag holds on the climb photo to pick a fall hold.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("attempt.edit.fall.empty")
                    } else {
                        SecondaryButton("Choose fall hold") {
                            showFallSheet = true
                        }
                        .accessibilityIdentifier("attempt.edit.fall.choose")
                        if fallOnHoldId != nil {
                            Button("Clear fall hold", role: .destructive) {
                                fallOnHoldId = nil
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("attempt.edit.fall.clear")
                        }
                    }
                    if outcome == .flash || outcome == .send {
                        Text("Sends do not record a fall hold.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("attempt.edit.fall.send-note")
                    }
                }

                SectionTitle("Notes")
                Card {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                        .themedField()
                        .accessibilityIdentifier("attempt.edit.notes")
                }
            }
            .accessibilityIdentifier("attempt.edit.sheet")
            .navigationTitle("Edit attempt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("attempt.edit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(outcome, notes.isEmpty ? nil : notes, fallOnHoldId, rpe)
                    }
                    .accessibilityIdentifier("attempt.edit.save")
                }
            }
        }
        .sheet(isPresented: $showFallSheet) {
            FallHoldSheet(
                climbTitle: "Climb",
                climbId: climbId,
                outcome: outcome,
                holds: holds,
                services: services
            ) { holdId in
                showFallSheet = false
                fallOnHoldId = holdId
            }
        }
    }

    /// The current fall hold label, resolved against the climb's real holds.
    private var fallHoldTitle: String {
        DisplayText.fallHoldTitle(fallOnHoldId: fallOnHoldId, holds: holds) ?? "No fall hold"
    }
}

/// The inline climb editor target on the session screen (UI overhaul): a new problem for
/// this session's gym, or an edit of the selected one.
enum SessionClimbEditorTarget: Identifiable, Hashable {
    case new
    case edit(String)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let climbId): return climbId
        }
    }

    /// The climb id the editor loads: "new" is the create sentinel ClimbEditorView expects.
    var climbId: String {
        switch self {
        case .new: return "new"
        case .edit(let climbId): return climbId
        }
    }
}
