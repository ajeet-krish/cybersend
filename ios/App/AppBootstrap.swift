import CyberSendData
import CyberSendFeatures
import Foundation
import GRDB

// Launch state machine (docs/architecture.md, M2 app layer). AppBootstrap opens the device
// database, runs migrations, and maps failures to guidance states per US-7: a database
// created by a newer app version is refused with "update the app first" and no writes, and
// any other migration failure leaves the prior schema intact (the failed migration rolled
// back) and is surfaced with retry and restore guidance.

/// The state the root of the app renders. Equatable so app tests can assert transitions.
enum LaunchState: Equatable {
    case loading
    case ready
    case newerDatabase(databaseVersion: Int, appVersion: Int)
    case migrationFailed(message: String)
}

/// The build variant for the running compilation, selected by the SWIFT_ACTIVE_
/// COMPILATION_CONDITIONS values in ios/Config/*.xcconfig. Unknown or absent conditions
/// fall back to development, matching readBuildVariant's tolerance.
#if DEVELOPMENT
let appBuildVariant: BuildVariant = .development
#elseif INTERNAL
let appBuildVariant: BuildVariant = .internalBuild
#elseif RELEASE
let appBuildVariant: BuildVariant = .release
#else
let appBuildVariant: BuildVariant = .development
#endif

/// Composition bootstrap: opens the database and, on success, builds the AppEnvironment.
/// The database opener is injectable so launch state tests can exercise the newer database
/// mapping and failure paths against the same code the app runs (port of the TypeScript
/// bootstrap in app/_layout.tsx).
@MainActor
struct AppBootstrap {
    typealias DatabaseOpener = (URL) throws -> (writer: any DatabaseWriter, migration: MigrationRunResult)

    /// Storage root: Application Support/CyberSend (docs/decisions.md, 2026-10-20 M2:
    /// storage root is Application Support). The database itself lives in db/ under this
    /// root, created by CyberSendDatabase.openDeviceDatabase.
    let documentDirectory: URL
    let variant: BuildVariant
    var openDatabase: DatabaseOpener = CyberSendDatabase.openDeviceDatabase

    init(documentDirectory: URL, variant: BuildVariant, openDatabase: @escaping DatabaseOpener = CyberSendDatabase.openDeviceDatabase) {
        self.documentDirectory = documentDirectory
        self.variant = variant
        self.openDatabase = openDatabase
    }

    /// The live bootstrap for the running app.
    static func live() -> AppBootstrap {
        AppBootstrap(documentDirectory: applicationSupportRoot(), variant: appBuildVariant)
    }

    /// The Application Support/CyberSend directory for the current user.
    static func applicationSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CyberSend", isDirectory: true)
    }

    /// Opens the database and builds the environment, or returns a guidance state with no
    /// environment. Never throws: every failure becomes a LaunchState the UI can render.
    func run() -> (state: LaunchState, environment: AppEnvironment?) {
        do {
            let (writer, migration) = try openDatabase(documentDirectory)
            let repos = Repositories(writer: writer)
            let flags = try resolvedFlags(for: variant, settings: repos.settings)
            let environment = AppEnvironment(
                documentDirectory: documentDirectory,
                writer: writer,
                repos: repos,
                migration: migration,
                variant: variant,
                flags: flags,
                stores: AppStores(repos: repos, variant: variant, flags: flags)
            )
            return (.ready, environment)
        } catch let error as MigrationError {
            if case .databaseNewerThanApp(let databaseVersion, let appVersion) = error {
                return (.newerDatabase(databaseVersion: databaseVersion, appVersion: appVersion), nil)
            }
            return (.migrationFailed(message: error.description), nil)
        } catch {
            return (.migrationFailed(message: error.localizedDescription), nil)
        }
    }
}
