import CyberSendDomain
import Foundation

// Shared display strings for the logbook screens (M2 Task 4). One place for outcome
// titles, grade label lookups, fall hold labels, and attempt counts so every screen words
// them the same way and UI tests can assert on stable text.

enum DisplayText {
    /// "Flash", "Send", "Project", "Fail" for outcome buttons and attempt rows.
    static func outcomeTitle(_ outcome: AttemptOutcome) -> String {
        outcome.rawValue.capitalized
    }

    /// The climb's stored (scheme, level) grade label, nil when scheme or level is unknown.
    static func grade(_ climb: Climb, systems: [GradeSystem]) -> String? {
        guard let system = systems.first(where: { $0.id == climb.gradeSystemId }) else { return nil }
        return gradeLabel(system, levelId: climb.gradeLevelId)
    }

    /// Climber facing climb title: name plus grade when known.
    static func climbTitle(_ climb: Climb, systems: [GradeSystem]) -> String {
        let name = climb.name ?? ""
        let base = name.isEmpty ? "Untitled climb" : name
        guard let grade = grade(climb, systems: systems) else { return base }
        return "\(base), \(grade)"
    }

    /// Fall hold label for an attempt: resolves the stored hold id against the climb's
    /// holds (usually empty until M3 photo tagging gives climbs holds).
    static func fallHoldTitle(fallOnHoldId: String?, holds: [Hold]) -> String? {
        guard let fallOnHoldId else { return nil }
        guard let hold = holds.first(where: { $0.id == fallOnHoldId }) else { return "Fall hold" }
        return "Fell on \(holdTitle(hold))"
    }

    /// One hold's display name: color first, then role, then ordinal.
    static func holdTitle(_ hold: Hold) -> String {
        if let color = hold.colorFamily { return "\(color) hold" }
        if let role = hold.role {
            switch role {
            case .start: return "start hold"
            case .intermediate: return "intermediate hold"
            case .top: return "top hold"
            }
        }
        if let ordinal = hold.ordinal { return "hold \(ordinal + 1)" }
        return "fall hold"
    }

    /// "1 attempt" or "N attempts".
    static func attemptCount(_ count: Int) -> String {
        count == 1 ? "1 attempt" : "\(count) attempts"
    }

    /// "RPE 7" label; nil when the session has no RPE stored.
    static func rpe(_ rpe: Int?) -> String? {
        rpe.map { "RPE \($0)" }
    }

    /// Transient warning text for the repository warning codes returned by logAttempt.
    static func warningMessage(_ code: String) -> String {
        if code == warningOutcomeRecordsNoFallHold {
            return "Sends do not record a fall hold, so the selected hold was cleared."
        }
        return code
    }
}
