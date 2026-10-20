import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import XCTest
@testable import CyberSend

// Restore confirmation gate smoke (docs/reviews.md M1 review obligation: no path may call
// restoreBackup without an explicit confirmation dialog). RestoreGate is the seam every
// settings restore and import path executes through; these tests prove that unconfirmed
// or cancelled requests never run destructive work, which is the unit level half of the
// proof (the settings restore smoke proves the dialog and the cancel path end to end).
// The M2 review finding (import follow-through ordering) adds the order independence
// regressions: a dismissal write after the confirm button action may not erase the
// confirmation before the picker returns, and the factored import handler runs against
// a fixture file URL because the system document picker cannot run inside XCTest.

@MainActor
final class RestoreGateTests: XCTestCase {
    func testWorkDoesNotRunWithoutARequest() {
        let gate = RestoreGate()
        var ran = false

        let output: Int? = gate.confirmed(.restoreNewestBackup) {
            ran = true
            return 1
        }

        XCTAssertNil(output, "a restore without a requested confirmation produces no output")
        XCTAssertFalse(ran, "no destructive work may run without the confirmation dialog")
    }

    func testConfirmedWorkRunsExactlyOnce() {
        let gate = RestoreGate()
        var runs = 0

        gate.request(.restoreNewestBackup)
        gate.confirm(.restoreNewestBackup)
        let output: Int? = gate.confirmed(.restoreNewestBackup) {
            runs += 1
            return runs
        }

        XCTAssertEqual(output, 1, "the confirmed work runs and returns its result")
        XCTAssertEqual(runs, 1)

        let second: Int? = gate.confirmed(.restoreNewestBackup) {
            runs += 1
            return runs
        }
        XCTAssertNil(second, "the confirmation is consumed; work cannot run twice")
        XCTAssertEqual(runs, 1)
    }

    func testCancelledRequestNeverRunsWork() {
        let gate = RestoreGate()
        var ran = false

        gate.request(.importFile)
        gate.cancel()
        gate.confirm(.importFile)
        let output: Int? = gate.confirmed(.importFile) {
            ran = true
            return 1
        }

        XCTAssertNil(output)
        XCTAssertFalse(ran, "a cancelled dialog leaves the destructive work unrun")
        XCTAssertFalse(gate.isPending(.importFile), "confirming a cancelled dialog does not reopen it")
    }

    func testConfirmThenCancelStillRunsTheConfirmedWorkExactlyOnce() {
        let gate = RestoreGate()
        var runs = 0

        gate.request(.importFile)
        gate.confirm(.importFile)
        gate.cancel()

        let output: Int? = gate.confirmed(.importFile) {
            runs += 1
            return runs
        }

        XCTAssertEqual(output, 1, "cancel after confirm is a dismissal write, not an eraser")
        XCTAssertEqual(runs, 1, "the confirmed import runs exactly once after the dismissal")

        let second: Int? = gate.confirmed(.importFile) {
            runs += 1
            return runs
        }
        XCTAssertNil(second, "the confirmation is consumed once even after the dismissal write")
        XCTAssertEqual(runs, 1)
    }

    func testConfirmForARequestThatIsNotPendingChangesNothing() {
        let gate = RestoreGate()

        gate.request(.restoreNewestBackup)
        gate.confirm(.importFile)

        var ran = false
        let output: Int? = gate.confirmed(.importFile) {
            ran = true
            return 1
        }

        XCTAssertNil(output, "a stray confirmation may not unlock a request the dialog never showed")
        XCTAssertFalse(ran)
        XCTAssertTrue(gate.isPending(.restoreNewestBackup), "the shown dialog stays pending")
    }

    func testAConfirmationDoesNotUnlockTheOtherRequest() {
        let gate = RestoreGate()

        gate.request(.importFile)
        gate.confirm(.importFile)

        var ran = false
        let output: Int? = gate.confirmed(.restoreNewestBackup) {
            ran = true
            return 1
        }

        XCTAssertNil(output, "confirming an import may not unlock a restore")
        XCTAssertFalse(ran)
    }

    func testPendingDrivesTheDialogVisibility() {
        let gate = RestoreGate()

        XCTAssertFalse(gate.isPending(.restoreNewestBackup))
        gate.request(.restoreNewestBackup)
        XCTAssertTrue(gate.isPending(.restoreNewestBackup))
        XCTAssertFalse(gate.isPending(.importFile), "only the requested dialog shows")

        gate.confirm(.restoreNewestBackup)
        XCTAssertFalse(gate.isPending(.restoreNewestBackup), "confirming hides the dialog")
    }

    // MARK: - Import path integration (fixture file instead of the system picker)

    func testConfirmedImportRunsAgainstAFixtureFileAfterTheDialogDismissal() throws {
        // A source logbook seeds one gym and exports it as the JSON payload fixture.
        let sourceRoot = try makeTemporaryRoot(label: "import-fixture-source")
        defer { removeTemporaryRoot(sourceRoot) }
        let source = try XCTUnwrap(
            AppBootstrap(documentDirectory: sourceRoot, variant: .development).run().environment
        )
        try source.repos.gyms.create(CreateGymInput(name: "Fixture Gym"))
        let payload = try buildExportJSON(repos: source.repos, now: nowISO8601())
        let fixtureURL = sourceRoot.appendingPathComponent("fixture-export.json")
        try payload.write(to: fixtureURL, atomically: true, encoding: .utf8)

        // A fresh logbook imports the fixture through the settings pipeline.
        let root = try makeTemporaryRoot(label: "import-fixture-target")
        defer { removeTemporaryRoot(root) }
        let environment = try XCTUnwrap(
            AppBootstrap(documentDirectory: root, variant: .development).run().environment
        )
        let services = AppServices(
            repos: environment.repos,
            documentDirectory: environment.documentDirectory,
            backupProcedures: environment.backupProcedures
        )
        let backup = BackupStore(services: services)
        let gate = RestoreGate()
        let actions = SettingsDataActions(backup: backup, gate: gate)

        gate.request(.importFile)
        actions.confirmImport()
        gate.cancel()  // the dialog's dismissal write after the button action

        let report = try XCTUnwrap(
            actions.performImport(at: fixtureURL),
            "the confirmation survives the dismissal write, so the import runs"
        )
        XCTAssertGreaterThan(report.restoredRows, 0, "the fixture gym lands in the report counts")
        XCTAssertEqual(
            try environment.repos.gyms.list(includeArchived: false).map(\.name),
            ["Fixture Gym"],
            "the imported row is in the logbook"
        )
        XCTAssertNil(backup.lastErrorMessage, "the import leaves the settings store clean")

        // The consumed confirmation cannot import again (no double picker return).
        let second = try actions.performImport(at: fixtureURL)
        XCTAssertNil(second, "the confirmation is consumed; a second picker return does nothing")
        XCTAssertEqual(try environment.repos.gyms.list(includeArchived: false).count, 1)
    }

    func testUnconfirmedImportNeverTouchesTheLogbook() throws {
        let root = try makeTemporaryRoot(label: "import-unconfirmed")
        defer { removeTemporaryRoot(root) }
        let environment = try XCTUnwrap(
            AppBootstrap(documentDirectory: root, variant: .development).run().environment
        )
        let services = AppServices(
            repos: environment.repos,
            documentDirectory: environment.documentDirectory,
            backupProcedures: environment.backupProcedures
        )
        let backup = BackupStore(services: services)
        let gate = RestoreGate()
        let actions = SettingsDataActions(backup: backup, gate: gate)

        let fixtureURL = root.appendingPathComponent("never-read.json")
        try "{\"schema_version\": 1}".write(to: fixtureURL, atomically: true, encoding: .utf8)

        gate.request(.importFile)
        gate.cancel()  // dismissed without confirming

        let output = try actions.performImport(at: fixtureURL)
        XCTAssertNil(output, "a dismissed dialog may not import a file")
        XCTAssertTrue(try environment.repos.gyms.list(includeArchived: false).isEmpty)
    }
}
