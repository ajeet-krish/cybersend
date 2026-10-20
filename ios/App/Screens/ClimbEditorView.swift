import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Climb editor screen (M2 Task 5, US-10, port of app/climb/[id].tsx): create a climb
// (LogbookRoute.climbDetail with climbId "new") or edit one. Grade is a (scheme, level)
// chip pair, never free text (US-9); the wall angle is nullable and validated 0 to 90
// (US-10.2); archiving keeps attempts and deleting is blocked while attempts exist
// (US-26). Saving and archiving refresh the logbook so the quick log list follows.

struct ClimbEditorView: View {
    let climbId: String

    @EnvironmentObject private var logbook: LogbookStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: ClimbEditorStore

    @State private var actionError: String?
    @State private var confirmDelete = false

    init(climbId: String, services: AppServices) {
        self.climbId = climbId
        // "new" is the LogbookRoute creation id (port of the TypeScript climb screen).
        _store = StateObject(wrappedValue: ClimbEditorStore(
            repos: services.repos,
            climbId: climbId == "new" ? nil : climbId
        ))
    }

    var body: some View {
        Screen {
            if let message = actionError ?? store.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("climb.error")
            }

            SectionTitle("Name")
            Card {
                TextField("For example: Blue V4 slab", text: $store.name)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.words)
                    .accessibilityIdentifier("climb.name")
            }

            SectionTitle("Grade scheme")
            Card {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.gradeSystems) { system in
                            Button {
                                store.schemeId = system.id
                                store.levelId = nil
                            } label: {
                                Chip(system.name, emphasized: system.id == store.schemeId)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("climb.scheme.\(system.id)")
                            .accessibilityLabel(system.name)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)

            SectionTitle("Level")
            Card {
                if let levels = store.selectedLevels {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(levels) { level in
                                Button {
                                    store.levelId = store.levelId == level.id ? nil : level.id
                                } label: {
                                    Chip(level.label, emphasized: store.levelId == level.id)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("climb.level.\(level.id)")
                                .accessibilityLabel(level.label)
                            }
                        }
                    }
                } else {
                    Text("Scheme not found.")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("climb.level.missing")
                }
            }
            .accessibilityElement(children: .contain)

            SectionTitle("Details")
            Card {
                TextField("Wall angle in degrees (optional, 0 to 90)", text: $store.angleText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("climb.angle")
                TextField("Color circuit (optional)", text: $store.colorCircuit)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.words)
                    .accessibilityIdentifier("climb.color")
            }

            PrimaryButton(store.isNew ? "Add climb" : "Save changes") {
                save()
            }
            .accessibilityIdentifier("climb.save")

            if !store.isNew {
                SectionTitle("Manage")
                Card {
                    Text(DisplayText.attemptCount(store.attemptCount))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("climb.attempts")
                    SecondaryButton(store.climb?.isArchived == true ? "Unarchive climb" : "Archive climb") {
                        toggleArchive()
                    }
                    .accessibilityIdentifier("climb.archive")
                    Button("Delete climb", role: .destructive) {
                        confirmDelete = true
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("climb.delete")
                }
            }
        }
        .accessibilityIdentifier("climb.screen")
        .navigationTitle(store.isNew ? "New climb" : "Climb")
        .confirmationDialog(
            "Delete this climb?",
            isPresented: $confirmDelete
        ) {
            Button("Delete climb", role: .destructive) {
                deleteClimb()
            }
            .accessibilityIdentifier("climb.delete.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only works when the climb has no attempts. Otherwise archive it.")
        }
    }

    private func save() {
        do {
            try store.save(gymId: logbook.selectedGymId)
            actionError = nil
            logbook.refresh()
            dismiss()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func toggleArchive() {
        do {
            try store.setArchived(store.climb?.isArchived != true)
            actionError = nil
            logbook.refresh()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func deleteClimb() {
        do {
            try store.delete()
            actionError = nil
            logbook.refresh()
            dismiss()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }
}
