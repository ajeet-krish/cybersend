import CyberSendData
import CyberSendDomain
import Foundation

// Climb editor store (M2 Task 5, US-10): load, create, edit, archive, and delete one
// climb through the climb repository. Lives app side next to SessionsHistoryStore because
// the Features stores cover screens that already exist and the climb editor is the only
// screen that writes climbs (US-10 is app layer work; repositories stay the only SQL
// surface, US-13).

@MainActor
final class ClimbEditorStore: ObservableObject {
    /// The climb being edited; nil in create mode.
    @Published private(set) var climb: Climb?
    /// Every gym for the details group picker. The editor can create a problem in any gym
    /// and move an existing one, which is why the gym is a field rather than a screen
    /// context.
    @Published private(set) var gyms: [Gym] = []
    /// Hold count for the holds card (M3, US-19): drives the summary, the tagging link,
    /// and the delete and replace photo warnings when holds exist.
    @Published private(set) var holdCount: Int = 0
    /// The climb's holds (M3): the holds card renders the count and the role breakdown
    /// from this list, and the tagging screen edits the same rows.
    @Published private(set) var holds: [Hold] = []
    /// Every grade scheme for the scheme chips (US-9: grade is a pair, never free text).
    @Published private(set) var gradeSystems: [GradeSystem] = []

    @Published var name: String = ""
    /// The gym the problem belongs to. For a create it starts as the gym the climber is
    /// standing in (the session's gym) or the selected gym; for an edit it is the climb's
    /// current gym.
    @Published var gymId: String = ""
    @Published var schemeId: String = defaultGradeSystemID
    @Published var levelId: String?
    @Published var angleText: String = ""
    @Published var colorCircuit: String = ""
    /// Free text problem details (Migration 004, Problems catalog): beta, style, what to
    /// remember. Empty is stored as nil so the column reads as "no details yet".
    @Published var notes: String = ""
    /// Descriptive category tags (Migration 005), toggled from the category button grid.
    @Published private(set) var categories: Set<ClimbCategory> = []
    @Published private(set) var lastErrorMessage: String?

    /// True when the screen creates a new climb instead of editing an existing one.
    /// Flipped by reloadAfterCreate so an inline create can continue into the photo and
    /// holds sections without closing and reopening the sheet.
    private(set) var isNew: Bool

    private let repos: Repositories

    /// climbId "new" (the LogbookRoute case for creation) or nil opens create mode.
    init(repos: Repositories, climbId: String?) {
        self.repos = repos
        self.isNew = climbId == nil
        gyms = (try? repos.gyms.list()) ?? []
        if let climbId {
            load(climbId: climbId)
        } else {
            gradeSystems = (try? repos.grades.listSystems()) ?? []
            if let first = gradeSystems.first {
                schemeId = first.id
            }
        }
    }

    /// Continues an inline create as an edit of the row that was just written. The climb
    /// already exists, so the photo and holds sections become available in place.
    func reloadAfterCreate(climbId: String) {
        isNew = false
        load(climbId: climbId)
    }

    /// The selected scheme's levels for the level picker; nil when the scheme is unknown.
    var selectedLevels: [GradeLevel]? {
        gradeSystems.first(where: { $0.id == schemeId })?.levels
    }

    /// Loads an existing climb plus its attempt count and the scheme list.
    private func load(climbId: String) {
        gradeSystems = (try? repos.grades.listSystems()) ?? []
        do {
            climb = try repos.climbs.get(id: climbId)
            if let climb {
                name = climb.name ?? ""
                schemeId = climb.gradeSystemId
                levelId = climb.gradeLevelId
                angleText = climb.angleDeg.map { String(Int($0)) } ?? ""
                colorCircuit = climb.colorCircuit ?? ""
                notes = climb.notes ?? ""
                gymId = climb.gymId
                categories = Set(climb.categories)
                refreshHolds()
            } else {
                lastErrorMessage = "This climb was deleted."
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Reloads the climb's holds (US-20 membership via climb_holds). Called after
    /// photo operations too: replacing or deleting a photo warns when holds exist.
    func refreshHolds() {
        guard let climb else { return }
        holds = ((try? repos.holds.listByClimb(climbId: climb.id)) ?? [])
        holdCount = holds.count
    }

    /// Falls back to the gym the climber is standing in when the editor opened without a
    /// loaded climb and the session or logbook has a selection.
    func ensureGymSelection(fallback: String?) {
        guard gymId.isEmpty, let fallback else { return }
        gymId = fallback
    }

    /// Adds or removes one category tag.
    func toggleCategory(_ category: ClimbCategory) {
        if categories.contains(category) {
            categories.remove(category)
        } else {
            categories.insert(category)
        }
    }

    func isSelected(_ category: ClimbCategory) -> Bool {
        categories.contains(category)
    }

    /// Switches grade scheme and clears the level: a level id only means something inside
    /// its scheme (US-9 keeps grade a (scheme, level) pair, never a free string), so
    /// carrying a level across schemes would produce a pair the repository rejects.
    func selectScheme(_ id: String) {
        guard schemeId != id else { return }
        schemeId = id
        levelId = nil
    }

    /// Saves the climb: create in the picked gym (the logbook selection when the picker is
    /// empty, US-11 surfaces the gym) or update the loaded row, which can also move it to
    /// another gym. Angle is validated like the TypeScript spec: empty is allowed (nullable
    /// column), otherwise a number from 0 to 90 (US-10.2).
    @discardableResult
    func save(fallbackGymId: String?) throws -> Climb {
        let angleDeg = try parseAngle(angleText)
        let targetGymId = gymId.isEmpty ? fallbackGymId : gymId
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedColor = colorCircuit.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored: Climb
        if let climb {
            stored = try repos.climbs.update(id: climb.id, patch: UpdateClimbPatch(
                gymId: .set(targetGymId ?? climb.gymId),
                name: .set(trimmedName),
                gradeSystemId: .set(schemeId),
                gradeLevelId: .set(levelId),
                colorCircuit: .set(trimmedColor.isEmpty ? nil : trimmedColor),
                angleDeg: .set(angleDeg),
                notes: .set(trimmedNotes.isEmpty ? nil : trimmedNotes),
                categories: .set(orderedClimbCategories(Array(categories)))
            ))
        } else {
            guard let targetGymId else {
                throw DomainValidationError(
                    "gym_not_selected",
                    "Select a gym on the Logbook tab before adding a climb."
                )
            }
            stored = try repos.climbs.create(CreateClimbInput(
                gymId: targetGymId,
                name: trimmedName.isEmpty ? nil : trimmedName,
                gradeSystemId: schemeId,
                gradeLevelId: levelId,
                colorCircuit: trimmedColor.isEmpty ? nil : trimmedColor,
                angleDeg: angleDeg,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                categories: orderedClimbCategories(Array(categories))
            ))
        }
        climb = stored
        lastErrorMessage = nil
        return stored
    }

    /// Archives or unarchives the climb (US-10.3 keeps attempts either way).
    func setArchived(_ archived: Bool) throws {
        guard let climb else { return }
        if archived {
            _ = try repos.climbs.archive(id: climb.id)
        } else {
            _ = try repos.climbs.unarchive(id: climb.id)
        }
        load(climbId: climb.id)
    }

    /// Deletes the climb; the repository blocks deletions when attempts exist (US-26).
    func delete() throws {
        guard let climb else { return }
        try repos.climbs.delete(id: climb.id)
    }

    /// Empty angle text clears the nullable column; anything else must be a number from
    /// 0 to 90.
    private func parseAngle(_ text: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite, value >= 0, value <= 90 else {
            throw DomainValidationError(
                "climb_angle_invalid",
                "Angle must be a number from 0 to 90, or empty."
            )
        }
        return value
    }
}
