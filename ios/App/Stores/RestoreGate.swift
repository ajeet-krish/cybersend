import CyberSendFeatures
import Foundation
import SwiftUI

// The destructive confirmation gate in front of every restore path (M2 Task 5, docs/
// reviews.md M1 review obligation: no path may call restoreBackup without an explicit
// confirmation dialog). The flow has three steps: a row button requests an action, the
// destructive confirmation dialog confirms it, and the restore or import work executes
// only through confirmed(_:run:), which refuses to run while nothing is confirmed. The
// gate is order independent (docs/reviews.md M2 review, import follow-through finding):
// the dialog button calls confirm(_:) with its explicit request, and cancel() clears
// only a request that is still waiting for its dialog, so the isPresented false write
// that follows a confirm button action can never erase a confirmation before the file
// picker returns. RestoreGateTests prove the gate; the settings restore smoke proves
// the dialog appears and the cancel path leaves data unchanged.

@MainActor
final class RestoreGate: ObservableObject {
    /// The destructive actions the settings screen gates.
    enum Request: Equatable {
        /// Restore the newest local backup (US-15.3).
        case restoreNewestBackup
        /// Pick a file and import it (US-16).
        case importFile
    }

    /// The request waiting for its confirmation dialog. Nil when no dialog should show.
    @Published private(set) var pending: Request?

    /// The request the destructive dialog confirmed and that its follow up work has not
    /// consumed yet (the file picker can land after the confirmation returns).
    private var confirmedRequest: Request?

    /// Step 1: a row button asks to run a destructive action; the dialog shows next. A
    /// new request also abandons any confirmation its work never consumed (for example a
    /// cancelled file picker), so a stale confirmation can never leak into a later run.
    func request(_ request: Request) {
        pending = request
        confirmedRequest = nil
    }

    /// The dialog was dismissed without confirming (cancel button or tap outside). Only
    /// a still pending request clears here: once confirm(_:) has run, pending is nil and
    /// the dismissal write that follows the button action is a no-op, so the
    /// confirmation survives until its work consumes it.
    func cancel() {
        pending = nil
    }

    /// Step 2: the destructive dialog button confirms the request its dialog is showing.
    /// A confirmation for a request that is not pending changes nothing.
    func confirm(_ request: Request) {
        guard pending == request else { return }
        confirmedRequest = request
        pending = nil
    }

    /// Step 3: the only way destructive work runs. Returns the work output, or nil when
    /// the request was cancelled or never confirmed; in the nil case the work closure is
    /// not called at all, so a restore can never run without its confirmation. Each
    /// confirmation is consumed exactly once.
    @discardableResult
    func confirmed<Output>(_ request: Request, run work: () throws -> Output) rethrows -> Output? {
        guard confirmedRequest == request else { return nil }
        confirmedRequest = nil
        return try work()
    }

    /// True while the dialog for the request should be visible.
    func isPending(_ request: Request) -> Bool {
        pending == request
    }
}

/// The post dialog pipeline behind the settings restore and import rows: a dialog button
/// confirms on the gate, and this handler reaches BackupStore only through the gate, so
/// RestoreGate stays the single path to restoreBackup and importFile. The import handler
/// is the seam the app tests drive with a fixture file URL, because the system document
/// picker cannot run inside XCTest (docs/reviews.md M2 review, import follow-through
/// finding: the import path needs coverage without driving the picker).
@MainActor
struct SettingsDataActions {
    let backup: BackupStore
    let gate: RestoreGate

    /// The destructive dialog confirmed the restore; only now may BackupStore reach the
    /// restore entry point (docs/reviews.md M1 review obligation). The work runs inside
    /// the dialog button action.
    func confirmRestore() throws -> ImportReport? {
        gate.confirm(.restoreNewestBackup)
        return try gate.confirmed(.restoreNewestBackup, run: { try backup.restoreNewestBackup() })
    }

    /// The destructive dialog confirmed the import; the file picker opens next and the
    /// import runs only for the confirmed request.
    func confirmImport() {
        gate.confirm(.importFile)
    }

    /// The file picker returned; the import runs only while the confirmed request has
    /// not been consumed (a dismissal write after the confirm button action cannot erase
    /// it, see RestoreGate.cancel).
    func performImport(at url: URL) throws -> ImportReport? {
        try gate.confirmed(.importFile, run: { try backup.importFile(at: url) })
    }
}
