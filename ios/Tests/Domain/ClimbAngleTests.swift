import Testing
@testable import CyberSendDomain

// Wall and climb angle rules plus quick-log visibility (port of src/domain/models/wall.ts and
// climb.ts, US-10).

@Suite("Angle validation")
struct AngleValidationTests {
    @Test("nil angles are valid everywhere")
    func nilAngleIsValid() {
        #expect(isValidAngle(nil))
        #expect(isClimbAngleValid(nil))
    }

    @Test("the 0 to 90 inclusive range is valid")
    func rangeBoundariesAreValid() {
        #expect(isValidAngle(0))
        #expect(isValidAngle(45))
        #expect(isValidAngle(90))
    }

    @Test("angles below 0 or above 90 are rejected")
    func outOfRangeAnglesThrow() {
        #expect(!isValidAngle(-1))
        #expect(!isValidAngle(91))
        #expect(!isValidAngle(.nan))
        #expect(!isValidAngle(.infinity))
    }

    @Test("the domain constants match the schema range")
    func angleConstants() {
        #expect(minAngleDeg == 0)
        #expect(maxAngleDeg == 90)
    }
}

@Suite("Climb visibility")
struct ClimbVisibilityTests {
    private func climb(isActive: Bool = true, isArchived: Bool = false) -> Climb {
        Climb(id: "c1", gymId: "g1", isActive: isActive, isArchived: isArchived, createdAt: "t", updatedAt: "t")
    }

    @Test("only active non archived climbs are quick loggable (US-10)")
    func quickLoggableRules() {
        #expect(isQuickLoggable(climb()))
        #expect(!isQuickLoggable(climb(isArchived: true)))
        #expect(!isQuickLoggable(climb(isActive: false)))
    }

    @Test("climb grade derives from the scheme and level pair (US-9)")
    func climbGradePair() {
        var graded = climb()
        graded.gradeSystemId = "v_scale"
        graded.gradeLevelId = "v4"
        #expect(climbGrade(of: graded) == ClimbGrade(systemId: "v_scale", levelId: "v4"))

        graded.gradeLevelId = nil
        #expect(climbGrade(of: graded) == nil)
    }
}
