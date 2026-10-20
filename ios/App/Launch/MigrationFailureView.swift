import SwiftUI

// US-7 launch guidance (docs/requirements.md US-7.4): a database created by a newer app
// version is refused with "update the app first" and no writes; any other migration
// failure left the prior schema intact because the failed migration rolled back, so the
// screen offers Try again and Restore from backup. This screen is guidance only: it never
// touches the database.

struct MigrationFailureView: View {
    let state: LaunchState
    let onRetry: () -> Void
    let onRestore: () -> Void

    @State private var restoreNoteVisible = false

    var body: some View {
        Screen {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(guidance)
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                if restoreNoteVisible {
                    ErrorNote(restoreNote)
                }
                VStack(spacing: 12) {
                    PrimaryButton("Try again", action: onRetry)
                    SecondaryButton("Restore from backup") {
                        restoreNoteVisible = true
                        onRestore()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        }
    }

    private var title: String {
        switch state {
        case .newerDatabase:
            return "Update the app first"
        case .migrationFailed:
            return "Your data is unchanged"
        default:
            return "Can't open logbook"
        }
    }

    private var guidance: String {
        switch state {
        case .newerDatabase(let databaseVersion, let appVersion):
            return "This logbook was saved by a newer version of CyberSend (schema \(databaseVersion), this app runs schema \(appVersion)). Update the app from the App Store, then open your logbook again. Nothing was changed."
        case .migrationFailed(let message):
            return "CyberSend couldn't finish preparing the logbook. The failed step was rolled back and your existing data is unchanged. Try again, or restore from a backup.\n\nDetails: \(message)"
        default:
            return ""
        }
    }

    /// Restore cannot run while the database refuses to open, so the shell states the path
    /// that works today. The full restore flow (confirmation dialog, file importer,
    /// BackupService.restoreBackup) lands with the Settings screen in M2 Task 5.
    private var restoreNote: String {
        "Restore needs the database to open. Keep your .cybersend backup files safe; if this screen keeps appearing, reinstall the app and import your backup from Settings."
    }
}
