import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Gym managers screen (M2 Task 4, US-8): create, rename, and archive gyms through the
// Features GymsStore. Archived gyms stay visible here and in session history but leave
// new session pickers and the quick log (US-8.4); the logbook tab refreshes after every
// write so its chips and selection follow (an archived default gym falls back per
// LogbookStore.resolveSelectedGymId).

struct GymsManagerView: View {
    @EnvironmentObject private var gyms: GymsStore
    @EnvironmentObject private var logbook: LogbookStore

    @State private var newName = ""
    @State private var actionError: String?
    @State private var showRename = false
    @State private var renameTarget: Gym?
    @State private var renameText = ""

    var body: some View {
        Screen {
            if let message = actionError ?? gyms.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("gyms.error")
            }

            SectionTitle("Add gym")
            Card {
                HStack(spacing: 12) {
                    TextField("Gym name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.words)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("gyms.new-name")
                    Button("Add") {
                        createGym()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("gyms.create")
                }
            }

            SectionTitle("All gyms")
            Card {
                if gyms.gyms.isEmpty {
                    EmptyState(
                        systemImage: "building.2",
                        title: "No gyms yet",
                        message: "Add your first gym above. Sessions attach to exactly one gym."
                    )
                } else {
                    ForEach(gyms.gyms) { gym in
                        gymRow(gym)
                    }
                }
            }
        }
        .accessibilityIdentifier("gyms.screen")
        .navigationTitle("Gyms")
        .onAppear {
            gyms.refresh()
        }
        .alert("Rename gym", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                saveRename()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func gymRow(_ gym: Gym) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(gym.name)
                    .foregroundStyle(gym.isArchived ? Theme.secondaryText : Theme.primaryText)
                Text("Added \(DisplayDate.string(from: gym.createdAt))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            if gym.isArchived {
                Chip("Archived")
                    .accessibilityIdentifier("gyms.archived.\(gym.id)")
            }
            Button {
                renameTarget = gym
                renameText = gym.name
                showRename = true
            } label: {
                Image(systemName: "pencil")
            }
            .accessibilityIdentifier("gyms.rename.\(gym.id)")
            .accessibilityLabel("Rename \(gym.name)")
            Button {
                setArchived(gym, archived: !gym.isArchived)
            } label: {
                Image(systemName: gym.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .accessibilityIdentifier("gyms.archive.\(gym.id)")
            .accessibilityLabel(gym.isArchived ? "Unarchive \(gym.name)" : "Archive \(gym.name)")
        }
        .padding(.vertical, 4)
    }

    private func createGym() {
        do {
            try gyms.createGym(name: newName)
            newName = ""
            actionError = nil
            logbook.refresh()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func saveRename() {
        guard let target = renameTarget else { return }
        do {
            try gyms.rename(id: target.id, name: renameText)
            renameTarget = nil
            actionError = nil
            logbook.refresh()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func setArchived(_ gym: Gym, archived: Bool) {
        do {
            try gyms.setArchived(id: gym.id, archived: archived)
            actionError = nil
            logbook.refresh()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }
}
