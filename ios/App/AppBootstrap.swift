import CyberSendData
import CyberSendFeatures
import Foundation

// Launch state machine (docs/architecture.md, M2 app layer). AppBootstrap opens the device
// database, runs migrations, and maps failures to guidance states per US-7: a database
// created by a newer app version is refused with "update the app first" and no writes, and
// any other migration failure leaves the prior schema intact (the failed migration rolled
// back) and is surfaced with retry and restore guidance. GRDB types stay inside Data; the
// opener below hands back Repositories, so app sources never import GRDB (review
// 2026-10-20, GRDB dependency hygiene).

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
    typealias OpenedDatabase = (repos: Repositories, migration: MigrationRunResult, backup: BackupProcedures)
    typealias DatabaseOpener = (URL) throws -> OpenedDatabase

    /// Storage root: Application Support/CyberSend (docs/decisions.md, 2026-10-20 M2:
    /// storage root is Application Support). The database itself lives in db/ under this
    /// root, created by CyberSendDatabase.openDeviceDatabase.
    let documentDirectory: URL
    let variant: BuildVariant
    var openDatabase: DatabaseOpener = AppBootstrap.openDeviceRepositories

    init(documentDirectory: URL, variant: BuildVariant, openDatabase: @escaping DatabaseOpener = AppBootstrap.openDeviceRepositories) {
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

    /// The live opener: CyberSendDatabase opens (and migrates) the device database, then
    /// Repositories wraps the writer. No GRDB type ever appears in app source; the writer
    /// only travels inside the restore and import closures. Nonisolated because it only
    /// touches Sendable Data values, matching the injectable opener type.
    nonisolated static func openDeviceRepositories(at documentDirectory: URL) throws -> OpenedDatabase {
        let opened = try CyberSendDatabase.openDeviceDatabase(at: documentDirectory)
        let repos = Repositories(writer: opened.writer)
        let databasePath = documentDirectory
            .appendingPathComponent(CyberSendDatabase.directoryName, isDirectory: true)
            .appendingPathComponent(CyberSendDatabase.filename)
            .path
        let backup = BackupProcedures(
            restoreArchive: { archiveBytes in
                try restoreBackup(
                    writer: opened.writer,
                    repos: repos,
                    documentDirectory: documentDirectory,
                    archiveBytes: archiveBytes,
                    databasePath: databasePath
                )
            },
            importPayload: { json in
                try importPayloadJSON(json, on: opened.writer)
            }
        )
        return (repos, opened.migration, backup)
    }

    /// Opens the database and builds the environment, or returns a guidance state with no
    /// environment. Never throws: every failure becomes a LaunchState the UI can render.
    func run() -> (state: LaunchState, environment: AppEnvironment?) {
        do {
            let seedRequested = uiTestSeedRequested()
            if seedRequested {
                #if DEVELOPMENT
                // Deterministic XCUITest seeding (docs/architecture.md test strategy):
                // wipe the database directory first so every seeded launch starts from an
                // empty, freshly migrated database. Debug builds only; the switch is
                // compiled out of Internal and Release, which can never wipe data.
                try UITestSeed.wipeDatabase(at: documentDirectory)
                #endif
            }
            let opened = try openDatabase(documentDirectory)
            let repos = opened.repos
            if seedRequested {
                #if DEVELOPMENT
                try UITestSeed.seed(repos: repos, documentDirectory: documentDirectory)
                #endif
            }
            let flags = try resolvedFlags(for: variant, settings: repos.settings)
            let media = MediaServices.make(repos: repos, documentDirectory: documentDirectory)
            let environment = AppEnvironment(
                documentDirectory: documentDirectory,
                repos: repos,
                migration: opened.migration,
                backupProcedures: opened.backup,
                media: media,
                variant: variant,
                flags: flags,
                stores: AppStores(repos: repos, storage: media.storage, variant: variant)
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

    /// True when the running Debug build was launched with the UI test seeding argument
    /// (either the base seed or the 100 hold canvas fixture, which also wipes first).
    private func uiTestSeedRequested() -> Bool {
        #if DEVELOPMENT
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(uiTestSeedArgument) || arguments.contains(uiTestSeedHoldsArgument)
        #else
        return false
        #endif
    }
}
