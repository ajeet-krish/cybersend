import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Session screen (M2 Task 4), the quick log surface (docs/decisions.md 2026-10-20: quick
// log lives on the open session screen, port of app/session/[id].tsx).
//
// Open state (US-11, US-12): pick a climb, set an optional per attempt effort, tap an
// outcome and the tap saves; fail prompts for the fall hold with a skip (worst case 4 taps
// from the logbook home, enforced by the QuickLogSmokeTests tap accounting); flash is
// disabled once the selected
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
                    openSessionContent
                } else {
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
            store.refresh()
            if let initialClimbId {
                store.selectClimb(id: initialClimbId)
            }
            if store.selectedClimbId == nil {
                store.selectClimb(id: store.climbs.first?.id)
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
        SectionTitle("Climb")
        Card {
            if store.climbs.isEmpty {
                EmptyState(
                    systemImage: "figure.climbing",
                    title: "No quick log climbs",
                    message: "Add active, not archived climbs for this gym to log attempts against."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.climbs) { climb in
                            let selected = climb.id == store.selectedClimbId
                            Button {
                                store.selectClimb(climb)
                            } label: {
                                Chip(climb.name ?? "Climb", emphasized: selected)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("session.climb.chip.\(climb.name ?? climb.id)")
                            .accessibilityLabel(climb.name ?? "Climb")
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.climbs")

        SectionTitle("Log attempt")
        Card {
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
                    Text(openAttemptLabel(row.attempt))
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityIdentifier("session.attempt.\(row.index)")
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

    private func outcomeButton(_ outcome: AttemptOutcome) -> some View {
        Button {
            outcomeTapped(outcome)
        } label: {
            Text(DisplayText.outcomeTitle(outcome))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!outcomeEnabled(outcome))
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

    private func openAttemptLabel(_ attempt: Attempt) -> String {
        let climbName = climbName(for: attempt.climbId)
        var text = "#\(attempt.attemptNo) \(DisplayText.outcomeTitle(attempt.outcome)), \(climbName)"
        if let holdText = DisplayText.fallHoldTitle(fallOnHoldId: attempt.fallOnHoldId, holds: holdsForClimb(attempt.climbId)) {
            text += ", \(holdText)"
        }
        if let rpeText = DisplayText.rpe(attempt.rpe) {
            text += ", \(rpeText)"
        }
        return text
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
                        .textFieldStyle(.roundedBorder)
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
                        .textFieldStyle(.roundedBorder)
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
