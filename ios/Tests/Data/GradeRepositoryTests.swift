import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain

// Grade repository tests (US-9, port of
// src/data/repositories/__tests__/grade_repository.test.ts, reconciled to the normalized
// grade_systems and grade_levels tables): built-in schemes, custom ordered levels, delete in
// use blocked.

@Suite("GradeRepository")
struct GradeRepositoryTests {
    @Test("lists built-in V scale and Font schemes with ordered levels")
    func listsBuiltinSchemes() throws {
        let test = try makeTestDatabase()
        let systems = try test.repos.grades.listSystems()

        let vScale = systems.first { $0.id == vScaleID }
        let font = systems.first { $0.id == fontID }
        #expect(vScale?.isBuiltin == true)
        #expect(font?.isBuiltin == true)
        #expect(vScale?.levels.first?.label == "V0")
        #expect(font?.levels.map(\.label).contains("6a+") == true)
    }

    @Test("creates a custom scheme of named ordered levels")
    func createsCustomScheme() throws {
        let test = try makeTestDatabase()
        let system = try test.repos.grades.createCustomSystem(
            CreateGradeSystemInput(name: " My gym colors ", levelLabels: ["green", "blue", "black"])
        )

        #expect(system.name == "My gym colors")
        #expect(system.levels.map(\.label) == ["green", "blue", "black"])
        #expect(system.levels.first?.id == "\(system.id)_l0")

        let systems = try test.repos.grades.listSystems()
        #expect(systems.filter { $0.id == system.id }.count == 1)

        let stored = try test.repos.grades.getSystem(id: system.id)
        #expect(stored?.levels.map(\.label) == ["green", "blue", "black"])
        #expect(stored?.levels.map(\.rankOrder) == [0, 1, 2])
    }

    @Test("rejects invalid custom schemes")
    func rejectsInvalidSchemes() throws {
        let test = try makeTestDatabase()
        #expect(throws: DomainValidationError.self) {
            try test.repos.grades.createCustomSystem(CreateGradeSystemInput(name: " ", levelLabels: ["a"]))
        }
        let empty = #expect(throws: DomainValidationError.self) {
            try test.repos.grades.createCustomSystem(CreateGradeSystemInput(name: "x", levelLabels: []))
        }
        #expect(empty?.message.contains("at least one") ?? false)
        let duplicate = #expect(throws: DomainValidationError.self) {
            try test.repos.grades.createCustomSystem(CreateGradeSystemInput(name: "x", levelLabels: ["a", "a"]))
        }
        #expect(duplicate?.message.contains("unique") ?? false)
    }

    @Test("renaming works for custom schemes only")
    func renamesCustomSchemes() throws {
        let test = try makeTestDatabase()
        let system = try test.repos.grades.createCustomSystem(CreateGradeSystemInput(name: "Old", levelLabels: ["one"]))
        let renamed = try test.repos.grades.renameCustomSystem(id: system.id, name: " New ")
        #expect(renamed.name == "New")

        let builtinError = #expect(throws: DomainValidationError.self) {
            try test.repos.grades.renameCustomSystem(id: "v_scale", name: "Nope")
        }
        #expect(builtinError?.message.contains("Built-in") ?? false)
        let missingError = #expect(throws: DomainValidationError.self) {
            try test.repos.grades.renameCustomSystem(id: "missing", name: "x")
        }
        #expect(missingError?.message.contains("not found") ?? false)
    }

    @Test("deleting a scheme in use is blocked; deleting a used built-in is blocked (US-9.4)")
    func deleteBlockedInUseAndBuiltin() throws {
        let test = try makeTestDatabase()
        let gym = try test.repos.gyms.create(CreateGymInput(name: "Gym"))
        let system = try test.repos.grades.createCustomSystem(CreateGradeSystemInput(name: "Circuit", levelLabels: ["easy", "hard"]))
        _ = try test.repos.climbs.create(
            CreateClimbInput(gymId: gym.id, gradeSystemId: system.id, gradeLevelId: system.levels.first?.id)
        )

        let inUseError = #expect(throws: DomainValidationError.self) {
            try test.repos.grades.deleteCustomSystem(id: system.id)
        }
        #expect(inUseError?.message.contains("used by 1 climb") ?? false)
        #expect(inUseError?.code == "grade_system_in_use")

        let builtinError = #expect(throws: DomainValidationError.self) {
            try test.repos.grades.deleteCustomSystem(id: "v_scale")
        }
        #expect(builtinError?.message.contains("Built-in") ?? false)
    }

    @Test("deleting an unused custom scheme removes it and resets a stale default")
    func deleteResetsStaleDefault() throws {
        let test = try makeTestDatabase()
        let system = try test.repos.grades.createCustomSystem(CreateGradeSystemInput(name: "Temp", levelLabels: ["a"]))
        try test.repos.grades.setDefaultSystem(id: system.id)
        #expect(try test.repos.grades.defaultSystemID() == system.id)

        try test.repos.grades.deleteCustomSystem(id: system.id)
        #expect(try test.repos.grades.defaultSystemID() == "v_scale")
        let systems = try test.repos.grades.listSystems()
        #expect(!systems.contains { $0.id == system.id })
    }

    @Test("validates (scheme, level) pairs for climbs")
    func validatesGradePairs() throws {
        let test = try makeTestDatabase()
        let system = try test.repos.grades.createCustomSystem(CreateGradeSystemInput(name: "Colors", levelLabels: ["green", "blue"]))

        try test.repos.grades.assertValidGrade(systemId: system.id, levelId: system.levels.last?.id)
        try test.repos.grades.assertValidGrade(systemId: system.id, levelId: nil)

        let levelError = #expect(throws: DomainValidationError.self) {
            try test.repos.grades.assertValidGrade(systemId: system.id, levelId: "missing_level")
        }
        #expect(levelError?.message.contains("does not exist") ?? false)
        let schemeError = #expect(throws: DomainValidationError.self) {
            try test.repos.grades.assertValidGrade(systemId: "no_such_scheme", levelId: "x")
        }
        #expect(schemeError?.message.contains("Unknown grade scheme") ?? false)
    }

    @Test("default scheme falls back to the V scale")
    func defaultSchemeFallsBackToVScale() throws {
        let test = try makeTestDatabase()
        #expect(try test.repos.grades.defaultSystemID() == "v_scale")
        try test.repos.grades.setDefaultSystem(id: "font")
        #expect(try test.repos.grades.defaultSystemID() == "font")
        #expect(throws: DomainValidationError.self) {
            try test.repos.grades.setDefaultSystem(id: "missing")
        }
    }
}

// Local aliases keep the ported test bodies close to the TypeScript originals.
private let vScaleID = "v_scale"
private let fontID = "font"
