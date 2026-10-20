import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import XCTest
@testable import CyberSend

// Composition root smoke (docs/architecture.md: app level XCTest covers the composition
// root and launch states). The bootstrap runs against a temporary storage root with the
// real CyberSendDatabase.openDeviceDatabase opener, so migrations run exactly like a
// device launch without touching the simulator's own Application Support directory.

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testBootstrapOpensDatabaseAtTemporaryRootAndRunsMigrations() throws {
        let root = try makeTemporaryRoot(label: "environment")
        defer { removeTemporaryRoot(root) }

        let bootstrap = AppBootstrap(documentDirectory: root, variant: .development)
        let result = bootstrap.run()

        XCTAssertEqual(result.state, .ready)
        let environment = try XCTUnwrap(result.environment)
        XCTAssertEqual(environment.migration.schemaVersion, currentSchemaVersion)
        XCTAssertFalse(environment.migration.applied.isEmpty, "a fresh database must apply every migration")
        XCTAssertEqual(environment.variant, .development)
        XCTAssertEqual(environment.flags, defaultFlags(for: .development))
        XCTAssertEqual(environment.documentDirectory, root)

        let databaseFile = root
            .appendingPathComponent(CyberSendDatabase.directoryName, isDirectory: true)
            .appendingPathComponent(CyberSendDatabase.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseFile.path))

        // Repositories work through the environment (US-13 surface).
        XCTAssertNil(try environment.repos.settings.get(key: settingsKeyFlagOverrides))
        XCTAssertEqual(try environment.repos.gyms.list(includeArchived: false), [])
    }

    func testSecondLaunchReopensWithoutApplyingMigrations() throws {
        let root = try makeTemporaryRoot(label: "relaunch")
        defer { removeTemporaryRoot(root) }

        let first = AppBootstrap(documentDirectory: root, variant: .development).run()
        XCTAssertEqual(first.state, .ready)
        XCTAssertFalse(try XCTUnwrap(first.environment).migration.applied.isEmpty)

        let second = AppBootstrap(documentDirectory: root, variant: .development).run()
        XCTAssertEqual(second.state, .ready)
        XCTAssertEqual(try XCTUnwrap(second.environment).migration.applied, [], "already migrated")
        XCTAssertEqual(try XCTUnwrap(second.environment).migration.schemaVersion, currentSchemaVersion)
    }

    func testSettingsOverridesMergeOverCompileTimeDefaults() throws {
        let root = try makeTemporaryRoot(label: "flags")
        defer { removeTemporaryRoot(root) }

        // First launch seeds an override row the way the settings screen will.
        let first = AppBootstrap(documentDirectory: root, variant: .development).run()
        let environment = try XCTUnwrap(first.environment)
        try environment.repos.settings.set(
            key: settingsKeyFlagOverrides,
            valueJson: "{\"ai_hold_detection\": true}"
        )

        let relaunched = AppBootstrap(documentDirectory: root, variant: .development).run()
        let merged = try XCTUnwrap(relaunched.environment).flags
        XCTAssertTrue(merged.aiHoldDetection, "settings override wins over the compile time default")
        XCTAssertTrue(merged.boulderVision, "unrelated defaults survive the merge")
    }
}
