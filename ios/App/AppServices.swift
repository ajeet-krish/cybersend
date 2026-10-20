import CyberSendData
import CyberSendFeatures
import Foundation
import SwiftUI

// Sendable services the view tree needs to build per screen stores (SessionDetailView owns
// one SessionDetailStore per session screen) and to trigger backup, restore, and import
// (docs/architecture.md M2: session close writes an automatic backup; the settings screen
// restores behind a destructive confirmation). Views read this from the SwiftUI
// environment and hand it to store initializers; they never call repositories themselves
// (stores only, US-13).

struct AppServices: Sendable {
    /// The repository set over the device database.
    let repos: Repositories
    /// Application Support/CyberSend storage root for the backup entry points.
    let documentDirectory: URL
    /// The writer bound restore and import entry points, built at bootstrap where the
    /// database writer lives so app sources never import GRDB (review 2026-10-20, GRDB
    /// dependency hygiene). Every settings path reaches them only through the destructive
    /// confirmation dialog (docs/reviews.md M1 review obligation).
    let backupProcedures: BackupProcedures
}

/// The database writer bound backup operations, packaged so app sources never name a
/// GRDB type. Bootstrap builds the live pair against the device writer; injected opener
/// tests use `unavailable(_:)` for flows that never restore.
struct BackupProcedures: Sendable {
    /// Restores a .cybersend archive atomically (US-15.3, US-16.3).
    let restoreArchive: @Sendable (Data) throws -> ImportReport
    /// Imports a full JSON export payload through the same staged transaction (US-16).
    let importPayload: @Sendable (String) throws -> ImportReport

    /// A placeholder that fails every entry point with a plain message; only for tests
    /// whose injected opener has no writer to restore against.
    static func unavailable(_ message: String) -> BackupProcedures {
        BackupProcedures(
            restoreArchive: { _ in throw BackupProceduresUnavailableError(message) },
            importPayload: { _ in throw BackupProceduresUnavailableError(message) }
        )
    }
}

/// Error from the `unavailable(_:)` placeholder procedures.
struct BackupProceduresUnavailableError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct AppServicesKey: EnvironmentKey {
    static let defaultValue: AppServices? = nil
}

extension EnvironmentValues {
    /// The composition services injected once at the root. Nil only in previews or tests
    /// that do not build per screen stores; destinations render a pending placeholder then.
    var appServices: AppServices? {
        get { self[AppServicesKey.self] }
        set { self[AppServicesKey.self] = newValue }
    }
}
