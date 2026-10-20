import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Grade schemes screen (M2 Task 4, US-9): lists the built-in V scale and Fontainebleau
// schemes plus custom ones (named ordered levels), owns the default scheme preference
// (US-25.1 default grade scheme, settings key settingsKeyDefaultGradeSystem through
// GradeSchemesStore), and manages custom schemes. Deleting a scheme in use is blocked by
// the repository with the blocking climb count in the message (US-9.4), surfaced here.

struct GradeSchemesView: View {
    @EnvironmentObject private var grades: GradeSchemesStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var newName = ""
    @State private var newLabels = ""
    @State private var actionError: String?
    @State private var showRename = false
    @State private var renameTarget: GradeSystem?
    @State private var renameText = ""
    @State private var pendingDelete: GradeSystem?

    var body: some View {
        Screen {
            if let message = actionError ?? grades.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("grades.error")
            }

            SectionTitle("Add custom scheme")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.words)
                        .accessibilityIdentifier("grades.new-name")
                    TextField("Level labels, low to high (for example A, B, C)", text: $newLabels)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.words)
                        .accessibilityIdentifier("grades.new-labels")
                    Button("Add scheme") {
                        createScheme()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("grades.create")
                }
            }

            SectionTitle("Schemes")
            Card {
                if grades.systems.isEmpty {
                    EmptyState(
                        systemImage: "chart.line.uptrend.xyaxis",
                        title: "No grade schemes",
                        message: "The built-in schemes appear after the database seeds them."
                    )
                } else {
                    ForEach(grades.systems) { system in
                        schemeRow(system)
                    }
                }
            }
        }
        .accessibilityIdentifier("grades.screen")
        .navigationTitle("Grade schemes")
        .onAppear {
            grades.refresh()
        }
        .alert("Rename scheme", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                saveRename()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this scheme?",
            isPresented: deleteBinding,
            presenting: pendingDelete
        ) { system in
            Button("Delete scheme", role: .destructive) {
                delete(system)
            }
            Button("Cancel", role: .cancel) {}
        } message: { system in
            Text("Custom levels of \(system.name) are removed. Climbs keep their stored level id.")
        }
    }

    private func schemeRow(_ system: GradeSystem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(system.name)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                if system.id == grades.defaultSystemId {
                    Chip("Default", emphasized: true)
                        .accessibilityIdentifier("grades.default.badge.\(system.id)")
                }
            }
            Text("\(system.isBuiltin ? "Built in" : "Custom"), \(system.levels.count) levels")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            Text(levelsPreview(system))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .accessibilityIdentifier("grades.levels.\(system.id)")
            HStack(spacing: 12) {
                if system.id != grades.defaultSystemId {
                    Button("Use as default") {
                        setDefault(system)
                    }
                    .accessibilityIdentifier("grades.set-default.\(system.id)")
                }
                if !system.isBuiltin {
                    Button("Rename") {
                        renameTarget = system
                        renameText = system.name
                        showRename = true
                    }
                    .accessibilityIdentifier("grades.rename.\(system.id)")
                    Button("Delete", role: .destructive) {
                        pendingDelete = system
                    }
                    .accessibilityIdentifier("grades.delete.\(system.id)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func levelsPreview(_ system: GradeSystem) -> String {
        let labels = system.levels.map(\.label)
        if labels.count > 8 {
            return labels.prefix(8).joined(separator: ", ") + ", ..."
        }
        return labels.joined(separator: ", ")
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func createScheme() {
        let labels = newLabels
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        do {
            try grades.createCustomSystem(name: newName, labels: labels)
            newName = ""
            newLabels = ""
            actionError = nil
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func setDefault(_ system: GradeSystem) {
        do {
            try grades.setDefault(id: system.id)
            settings.refresh()
            actionError = nil
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func saveRename() {
        guard let target = renameTarget else { return }
        do {
            try grades.rename(id: target.id, name: renameText)
            renameTarget = nil
            actionError = nil
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func delete(_ system: GradeSystem) {
        do {
            try grades.delete(id: system.id)
            pendingDelete = nil
            actionError = nil
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }
}
