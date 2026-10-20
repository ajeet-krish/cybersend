import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Logbook store tests (M2): default gym preselect, active gym filtering, the quick-log
// climb set, and the one open session rule surfaced with the TypeScript error code.

@Suite("LogbookStore")
@MainActor
struct LogbookStoreTests {
    @Test("preselects the persisted default gym when it is active")
    func preselectsDefaultGym() throws {
        let test = try makeTestDatabase()
        let first = try seedGym(test.repos, name: "Alpha")
        let preferred = try seedGym(test.repos, name: "Beta")
        try test.repos.settings.setJSON(key: settingsKeyDefaultGymID, value: preferred.id)

        let store = LogbookStore(repos: test.repos)

        #expect(store.selectedGymId == preferred.id)
        #expect(store.selectedGym?.id == preferred.id)
        #expect(store.gyms.map(\.id) == [first.id, preferred.id])
    }

    @Test("falls back to the first active gym and lists archived gyms separately")
    func fallsBackToFirstActiveGym() throws {
        let test = try makeTestDatabase()
        let alpha = try seedGym(test.repos, name: "Alpha")
        let beta = try seedGym(test.repos, name: "Beta")
        let archived = try seedGym(test.repos, name: "Old Gym")
        _ = try test.repos.gyms.setArchived(id: archived.id, archived: true)

        let store = LogbookStore(repos: test.repos)

        #expect(store.gyms.map(\.id) == [alpha.id, beta.id])
        #expect(!store.gyms.contains { $0.id == archived.id })
        #expect(store.allGyms.count == 3)
        #expect(store.selectedGymId == alpha.id)
    }

    @Test("a default gym that was archived falls back to the first active gym")
    func archivedDefaultFallsBack() throws {
        let test = try makeTestDatabase()
        let alpha = try seedGym(test.repos, name: "Alpha")
        let archived = try seedGym(test.repos, name: "Old Gym")
        _ = try test.repos.gyms.setArchived(id: archived.id, archived: true)
        try test.repos.settings.setJSON(key: settingsKeyDefaultGymID, value: archived.id)

        let store = LogbookStore(repos: test.repos)

        #expect(store.selectedGymId == alpha.id)
    }

    @Test("quick-log climbs exclude archived and inactive climbs")
    func quickLogExcludesArchivedAndInactive() throws {
        let test = try makeTestDatabase()
        let gym = try seedGym(test.repos)
        let active = try seedClimb(test.repos, gymId: gym.id, name: "Active")
        let archived = try seedClimb(test.repos, gymId: gym.id, name: "Archived")
        let inactive = try seedClimb(test.repos, gymId: gym.id, name: "Inactive")
        _ = try test.repos.climbs.archive(id: archived.id)
        _ = try test.repos.climbs.setActive(id: inactive.id, active: false)

        let store = LogbookStore(repos: test.repos)
        store.refresh()

        #expect(store.quickLogClimbs.map(\.id) == [active.id])
    }

    @Test("startSession opens a session and the second start throws open_session_exists")
    func startSessionOneOpenRule() throws {
        let test = try makeTestDatabase()
        let gym = try seedGym(test.repos)
        let store = LogbookStore(repos: test.repos)
        #expect(store.selectedGymId == gym.id)

        let session = try store.startSession()
        #expect(isSessionOpen(session))
        #expect(session.gymId == gym.id)
        #expect(store.openSession?.id == session.id)
        #expect(store.recentSessions.map(\.session.id) == [session.id])

        let error = #expect(throws: DomainValidationError.self) {
            try store.startSession()
        }
        #expect(error?.code == "open_session_exists")
        #expect(store.openSession?.id == session.id)
        #expect(try test.repos.sessions.getOpen()?.id == session.id)
        #expect(try test.repos.sessions.list(limit: 10).count == 1)
    }

    @Test("startSession with no active gym throws gym_not_selected")
    func startSessionWithoutGym() throws {
        let test = try makeTestDatabase()
        let store = LogbookStore(repos: test.repos)
        #expect(store.gyms.isEmpty)
        #expect(store.selectedGymId == nil)

        let error = #expect(throws: DomainValidationError.self) {
            try store.startSession()
        }
        #expect(error?.code == "gym_not_selected")
    }

    @Test("selectGym persists the choice as the default gym for the next store")
    func selectGymPersistsDefault() throws {
        let test = try makeTestDatabase()
        let alpha = try seedGym(test.repos, name: "Alpha")
        let beta = try seedGym(test.repos, name: "Beta")
        let store = LogbookStore(repos: test.repos)
        #expect(store.selectedGymId == alpha.id)

        store.selectGym(beta.id)

        #expect(store.selectedGymId == beta.id)
        #expect(try test.repos.settings.getJSON(key: settingsKeyDefaultGymID, as: String.self) == beta.id)

        let fresh = LogbookStore(repos: test.repos)
        #expect(fresh.selectedGymId == beta.id)

        store.selectGym(nil)
        #expect(store.selectedGymId == nil)
        #expect(try test.repos.settings.get(key: settingsKeyDefaultGymID) == nil)
    }

    @Test("refresh exposes grade systems, the open session, and recent history")
    func refreshExposesSharedState() throws {
        let test = try makeTestDatabase()
        let gym = try seedGym(test.repos)
        let session = try test.repos.sessions.create(CreateSessionInput(gymId: gym.id))

        let store = LogbookStore(repos: test.repos)

        #expect(store.openSession?.id == session.id)
        #expect(store.recentSessions.map(\.session.id) == [session.id])
        #expect(store.gradeSystems.contains { $0.id == defaultGradeSystemID && $0.isBuiltin })
        #expect(store.lastErrorMessage == nil)
    }
}
