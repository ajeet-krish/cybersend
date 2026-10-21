import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import Foundation

// Composition root (docs/decisions.md, 2026-10-20 M2: ObservableObject per-feature stores;
// docs/architecture.md M2 app layer). One AppEnvironment is built at launch by
// AppBootstrap and injected into the view tree; views and stores never open the database
// themselves (repositories only, US-13). The GRDB writer never appears here: the
// Repositories keep the connection alive, so app sources never import GRDB (review
// 2026-10-20, GRDB dependency hygiene; ios/App/AppServices.swift carries what views need).

/// The objects the app tree depends on. Sendable values only cross off the main actor;
/// the stores stay on the main actor by design (Swift 6, iOS 16 floor).
@MainActor
struct AppEnvironment {
    /// Application Support/CyberSend storage root (db/, photos/, videos/, backups/,
    /// exports/ live under it).
    let documentDirectory: URL
    /// The only SQL surface (US-13).
    let repos: Repositories
    /// Migration outcome of this launch; kept for the About screen and diagnostics.
    let migration: MigrationRunResult
    /// Writer bound restore and import entry points for the settings screen (M2 Task 5).
    let backupProcedures: BackupProcedures
    /// Photo file storage and the launch sweep entry point (M3), built from the same
    /// document directory so the composition root stays the only wiring place.
    let media: MediaServices
    let variant: BuildVariant
    /// Resolved flag values: xcconfig compile time defaults merged with settings overrides.
    let flags: FlagValues
    let stores: AppStores
}
