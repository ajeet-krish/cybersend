import CyberSendData
import CyberSendDomain
import CyberSendFeatures
import SwiftUI
import UniformTypeIdentifiers

// Settings screen (M2 Task 5, US-24 to US-26, port of app/(tabs)/settings.tsx): defaults
// (default gym and grade scheme), appearance, photo retention with a read only video
// label, JSON and CSV export through the share sheet, and the backup and restore entry
// points. Restore and import are gated behind a destructive confirmation dialog
// (docs/architecture.md M2 navigation, docs/reviews.md M1 review obligation: no path may
// call restoreBackup without an explicit confirmation; RestoreGate is the seam the unit
// tests and the settings restore smoke prove).

struct SettingsView: View {
    let services: AppServices

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var gyms: GymsStore
    @EnvironmentObject private var grades: GradeSchemesStore
    @EnvironmentObject private var logbook: LogbookStore
    @EnvironmentObject private var history: SessionsHistoryStore

    @StateObject private var backup: BackupStore
    @StateObject private var gate = RestoreGate()

    @State private var actionError: String?
    @State private var notice: String?
    @State private var showFileImporter = false
    @State private var importReport: ImportReport?

    init(services: AppServices) {
        self.services = services
        _backup = StateObject(wrappedValue: BackupStore(services: services))
    }

    var body: some View {
        List {
            if let message = actionError {
                ErrorNote(message)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("settings.error")
            }
            if let notice {
                ErrorNote(notice)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("settings.notice")
            }

            defaultsSection
            appearanceSection
            photoSection
            exportSection
            backupSection
            #if !RELEASE
            developerSection
            #endif
            aboutSection
        }
        .accessibilityIdentifier("settings.screen")
        .navigationTitle("Settings")
        .onAppear {
            refreshAll()
        }
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .featureFlags:
                FeatureFlagsView()
            case .appearance, .backups, .about:
                // Defaults, backup, and about render inline on this screen like the
                // frozen TypeScript spec; the typed cases stay registered so later
                // milestone sub screens land without navigation churn.
                EmptyView()
            }
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: restoreDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                confirmRestore()
            }
            .accessibilityIdentifier("settings.restore.confirm")
            Button("Cancel", role: .cancel) {
                gate.cancel()
            }
            .accessibilityIdentifier("settings.restore.cancel")
        } message: {
            Text("Rows in the newest local backup replace the rows on this device. This cannot be undone.")
        }
        .confirmationDialog(
            "Import this file?",
            isPresented: importDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Import", role: .destructive) {
                confirmImport()
            }
            .accessibilityIdentifier("settings.import.confirm")
            Button("Cancel", role: .cancel) {
                gate.cancel()
            }
            .accessibilityIdentifier("settings.import.cancel")
        } message: {
            Text("A .cybersend backup replaces your rows with the file contents; a JSON export merges into this logbook. This cannot be undone.")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                performImport(url)
            }
        }
        .alert("Import complete", isPresented: reportAlertBinding, presenting: importReport) { _ in
            Button("Done") {
                importReport = nil
            }
            .accessibilityIdentifier("settings.report.dismiss")
        } message: { report in
            Text(reportSummary(report))
        }
    }

    // MARK: - Sections

    private var defaultsSection: some View {
        Section("Defaults") {
            if gyms.activeGyms.isEmpty {
                Text("No active gyms yet. Add one from the Logbook tab.")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("settings.default-gym.empty")
            } else {
                ForEach(gyms.activeGyms) { gym in
                    Button {
                        setDefaultGym(gym.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(gym.name)
                                .foregroundStyle(Theme.primaryText)
                            Spacer(minLength: 8)
                            if gym.id == selectedGymId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.default-gym.\(gym.id)")
                    .accessibilityLabel(gym.name)
                    .accessibilityAddTraits(gym.id == selectedGymId ? [.isSelected] : [])
                }
            }
            if grades.systems.isEmpty {
                Text("No grade schemes yet.")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("settings.default-scheme.empty")
            } else {
                Picker("Default grade scheme", selection: defaultSchemeBinding) {
                    ForEach(grades.systems) { system in
                        Text(system.name).tag(system.id)
                    }
                }
                .accessibilityIdentifier("settings.default-scheme")
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: appearanceBinding) {
                ForEach(AppearancePreference.allCases, id: \.rawValue) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appearance")
        }
    }

    private var photoSection: some View {
        Section("Photos and videos") {
            Picker("Photos", selection: photoRetentionBinding) {
                ForEach(PhotoRetentionPreference.allCases, id: \.rawValue) { retention in
                    Text(photoRetentionTitle(retention)).tag(retention)
                }
            }
            .accessibilityIdentifier("settings.photo-retention")
            Row(title: "Videos", detail: "Kept with backups")
                .accessibilityIdentifier("settings.video-retention")
        }
    }

    private var exportSection: some View {
        Section("Export") {
            if let url = backup.exportJSONURL {
                ShareLink(item: url) {
                    Label("Export JSON (full)", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.export.json")
            } else {
                Text("Preparing export...")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("settings.export.pending")
            }
            ForEach(CsvEntity.allCases, id: \.rawValue) { entity in
                if let url = backup.exportCSVURLs[entity] {
                    ShareLink(item: url) {
                        Text("Export CSV: \(entity.rawValue.capitalized)")
                    }
                    .accessibilityIdentifier("settings.export.csv.\(entity.rawValue)")
                }
            }
        }
    }

    private var backupSection: some View {
        Section("Backup and restore") {
            Button {
                backupNow()
            } label: {
                Text("Back up now")
            }
            .accessibilityIdentifier("settings.backup-now")

            Button(role: .destructive) {
                gate.request(.restoreNewestBackup)
            } label: {
                Text("Restore from a local backup")
            }
            .accessibilityIdentifier("settings.restore")

            Button {
                gate.request(.importFile)
            } label: {
                Text("Import a file")
            }
            .accessibilityIdentifier("settings.import")

            Text(backup.lastBackupLabel)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("settings.last-backup")

            if let message = backup.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("settings.backup.error")
            }
        }
    }

    #if !RELEASE
    private var developerSection: some View {
        Section("Developer") {
            NavigationLink(value: SettingsRoute.featureFlags) {
                Row(title: "Feature flags", detail: enabledFlagSummary)
            }
            .accessibilityIdentifier("settings.flags")
        }
    }
    #endif

    private var aboutSection: some View {
        Section("About") {
            Row(title: "Version", detail: currentAppVersion())
                .accessibilityIdentifier("settings.version")
            Row(title: "Schema version", detail: "\(currentSchemaVersion)")
                .accessibilityIdentifier("settings.schema-version")
            Row(title: "Build variant", detail: settings.variant.rawValue)
                .accessibilityIdentifier("settings.variant")
        }
    }

    // MARK: - Bindings

    /// Immediate persistence on change (US-25.2); a failed write leaves the selection
    /// snapped back to the stored value instead of drifting out of sync.
    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { settings.appearance },
            set: { try? settings.setAppearance($0) }
        )
    }

    private var photoRetentionBinding: Binding<PhotoRetentionPreference> {
        Binding(
            get: { settings.photoRetention },
            set: { try? settings.setPhotoRetention($0) }
        )
    }

    private var defaultSchemeBinding: Binding<String> {
        Binding(
            get: { settings.defaultGradeSystemId ?? grades.defaultSystemId },
            set: { try? settings.setDefaultGradeSystem($0) }
        )
    }

    /// The default gym row checkmark follows the persisted default, falling back to the
    /// logbook selection exactly like LogbookStore.resolveSelectedGymId.
    private var selectedGymId: String? {
        settings.defaultGymId ?? logbook.selectedGymId
    }

    private var restoreDialogBinding: Binding<Bool> {
        Binding(
            get: { gate.isPending(.restoreNewestBackup) },
            set: { if !$0 { gate.cancel() } }
        )
    }

    private var importDialogBinding: Binding<Bool> {
        Binding(
            get: { gate.isPending(.importFile) },
            set: { if !$0 { gate.cancel() } }
        )
    }

    private var reportAlertBinding: Binding<Bool> {
        Binding(
            get: { importReport != nil },
            set: { if !$0 { importReport = nil } }
        )
    }

    #if !RELEASE
    private var enabledFlagSummary: String {
        let enabled = FeatureFlag.allCases.filter { settings.flags[$0] }.count
        return "\(enabled) of \(FeatureFlag.allCases.count) on"
    }
    #endif

    // MARK: - Actions

    /// The confirmation to work pipeline, built per call against the screen's stores. It
    /// keeps RestoreGate the single path to restoreBackup and importFile and is the seam
    /// the app tests drive with a fixture file URL (the system picker cannot run in
    /// XCTest; docs/reviews.md M2 review, import follow-through finding).
    private var actions: SettingsDataActions {
        SettingsDataActions(backup: backup, gate: gate)
    }

    private func refreshAll() {
        settings.refresh()
        gyms.refresh()
        grades.refresh()
        logbook.refresh()
        backup.refresh()
    }

    private func setDefaultGym(_ gymId: String) {
        do {
            try settings.setDefaultGym(gymId)
            logbook.refresh()
            actionError = nil
        } catch {
            surface(error)
        }
    }

    private func backupNow() {
        do {
            try backup.backupNow()
            actionError = nil
            notice = "Backup written to the backups folder."
        } catch {
            notice = nil
            surface(error)
        }
    }

    /// The dialog actions route through SettingsDataActions, the factored pipeline that
    /// keeps RestoreGate the single path to restoreBackup and importFile and that the
    /// app tests drive with a fixture file URL (the system picker cannot run in XCTest).

    /// The destructive dialog confirmed the restore; only now may BackupStore reach the
    /// restore entry point (docs/reviews.md M1 review obligation).
    private func confirmRestore() {
        do {
            guard let report = try actions.confirmRestore() else {
                return
            }
            finishDataChange(report: report)
        } catch {
            surface(error)
        }
    }

    /// The destructive dialog confirmed the import; the file picker opens next and the
    /// import runs only for the confirmed request. The gate survives the dismissal write
    /// that follows this button action (docs/reviews.md M2 review finding).
    private func confirmImport() {
        actions.confirmImport()
        showFileImporter = true
    }

    private func performImport(_ url: URL) {
        do {
            guard let report = try actions.performImport(at: url) else {
                return
            }
            finishDataChange(report: report)
        } catch {
            surface(error)
        }
    }

    /// After a restore or import every store reloads so the whole app shows the new data.
    private func finishDataChange(report: ImportReport) {
        refreshAll()
        history.refresh()
        actionError = nil
        notice = nil
        importReport = report
    }

    private func reportSummary(_ report: ImportReport) -> String {
        var lines = ["\(report.restoredRows) rows added, \(report.updatedRows) rows updated."]
        if report.media.restored > 0 || report.media.skipped > 0 {
            lines.append("Media: \(report.media.restored) restored, \(report.media.verified) verified, \(report.media.skipped) skipped.")
        }
        for warning in report.warnings {
            lines.append(warning)
        }
        return lines.joined(separator: "\n")
    }

    private func surface(_ error: Error) {
        if let validation = error as? DomainValidationError {
            actionError = validation.message
            return
        }
        if let backupStore = error as? BackupStoreError {
            actionError = backupStore.message
            return
        }
        actionError = error.localizedDescription
    }

    private func photoRetentionTitle(_ retention: PhotoRetentionPreference) -> String {
        switch retention {
        case .keepOriginals: return "Keep originals"
        case .discardOriginals: return "Discard originals"
        }
    }
}
