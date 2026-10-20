import Testing
@testable import CyberSendDomain

// Grade scheme helpers (port of src/domain/grade, US-9): built-in V scale and Font,
// deterministic custom level ids, and the M4 normalization seam's data gate (US-30).

@Suite("Built-in grade schemes")
struct BuiltinSchemeTests {
    @Test("V scale is the default scheme with levels V0 to V17 in order")
    func vScaleLevelsAreOrdered() {
        #expect(vScale.id == "v_scale")
        #expect(vScale.isBuiltin)
        #expect(vScale.levels.count == 18)
        #expect(vScale.levels.first?.id == "v0")
        #expect(vScale.levels.first?.label == "V0")
        #expect(vScale.levels.last?.label == "V17")
        #expect(vScale.levels.map(\.rankOrder) == Array(0..<18))
    }

    @Test("Font scale uses stable ids with plus rendered as _plus")
    func fontLevelIDsAreStable() {
        #expect(fontScale.id == "font")
        #expect(fontScale.levels.count == 26)
        #expect(fontScale.levels.map(\.label).contains("6a+"))
        #expect(findLevel(fontScale, levelId: "f6a_plus")?.label == "6a+")
        #expect(findLevel(fontScale, levelId: "f9a")?.label == "9a")
    }

    @Test("default scheme is the V scale and builtin lookup works")
    func defaultSystemLookup() {
        #expect(defaultGradeSystemID == "v_scale")
        #expect(findBuiltinSystem("v_scale") != nil)
        #expect(findBuiltinSystem("nope") == nil)
    }

    @Test("gradeLabel resolves known pairs and returns nil for unknown ones")
    func gradeLabelResolution() {
        #expect(gradeLabel(vScale, levelId: "v4") == "V4")
        #expect(gradeLabel(vScale, levelId: "missing") == nil)
        #expect(gradeLabel(nil, levelId: "v4") == nil)
        #expect(gradeLabel(vScale, levelId: nil) == nil)
    }
}

@Suite("Custom grade schemes")
struct CustomSchemeTests {
    @Test("creates a custom scheme of named ordered levels with deterministic ids")
    func makeCustomSystemBuildsLevels() throws {
        let system = try makeCustomSystem(systemId: "abc", name: " My gym colors ", levelLabels: ["green", "blue", "black"])
        #expect(system.name == "My gym colors")
        #expect(!system.isBuiltin)
        #expect(system.levels.map(\.label) == ["green", "blue", "black"])
        #expect(system.levels.first?.id == "abc_l0")
        #expect(system.levels.map(\.rankOrder) == [0, 1, 2])
    }

    @Test("an empty name is rejected")
    func emptyNameThrows() {
        let error = #expect(throws: DomainValidationError.self) {
            try makeCustomSystem(systemId: "abc", name: " ", levelLabels: ["a"])
        }
        #expect(error?.code == "grade_system_name_required")
    }

    @Test("level labels are required and non empty")
    func emptyLevelsThrow() {
        let empty = #expect(throws: DomainValidationError.self) {
            try makeCustomSystem(systemId: "abc", name: "x", levelLabels: [])
        }
        #expect(empty?.code == "grade_system_levels_required")

        let blank = #expect(throws: DomainValidationError.self) {
            try makeCustomSystem(systemId: "abc", name: "x", levelLabels: ["a", "  "])
        }
        #expect(blank?.code == "grade_system_levels_required")
    }

    @Test("duplicate level labels are rejected")
    func duplicateLevelsThrow() {
        let error = #expect(throws: DomainValidationError.self) {
            try makeCustomSystem(systemId: "abc", name: "x", levelLabels: ["a", "a"])
        }
        #expect(error?.code == "grade_system_duplicate_levels")
    }

    @Test("a color hex list that does not match the label count is rejected")
    func colorCountMismatchThrows() {
        let error = #expect(throws: DomainValidationError.self) {
            try makeCustomSystem(systemId: "abc", name: "x", levelLabels: ["a", "b"], colorHexes: ["#fff"])
        }
        #expect(error?.code == "grade_system_color_count_mismatch")
    }

    @Test("level color hexes are carried when provided")
    func colorHexesAreCarried() throws {
        let system = try makeCustomSystem(
            systemId: "abc",
            name: "Circuits",
            levelLabels: ["green", "blue"],
            colorHexes: ["#00ff00", nil]
        )
        #expect(system.levels.first?.colorHex == "#00ff00")
        #expect(system.levels.last?.colorHex == nil)
    }
}

@Suite("Grade normalization seam")
struct GradeNormalizationTests {
    @Test("the data sufficiency gate follows the US-30 thresholds")
    func sufficiencyThresholds() {
        #expect(!GradeNormalization.isDataSufficient(attemptCount: 29, gymCount: 2))
        #expect(!GradeNormalization.isDataSufficient(attemptCount: 30, gymCount: 1))
        #expect(GradeNormalization.isDataSufficient(attemptCount: 30, gymCount: 2))
        #expect(GradeNormalization.minimumAttemptCount == 30)
        #expect(GradeNormalization.minimumGymCount == 2)
    }
}
