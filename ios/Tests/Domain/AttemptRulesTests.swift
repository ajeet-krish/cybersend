import Testing
@testable import CyberSendDomain

// Attempt outcome rules (port of the TypeScript src/domain/attempts behavior, US-12): flash
// implies first attempt, fall hold must belong to the climb, flash and send record no fall hold.

@Suite("Attempt rules")
struct AttemptRulesTests {
    @Test("accepts a project outcome with a fall hold on the climb")
    func projectWithFallHoldIsAccepted() throws {
        let validation = try validateAttempt(
            input: AttemptInput(outcome: .project, fallOnHoldId: "hold-1"),
            context: AttemptRuleContext(attemptNo: 3, climbHoldIds: ["hold-1", "hold-2"])
        )
        #expect(validation.fallOnHoldId == "hold-1")
        #expect(validation.warnings.isEmpty)
    }

    @Test("a flash requires the first attempt of the session")
    func flashRequiresFirstAttempt() {
        let error = #expect(throws: DomainValidationError.self) {
            try validateAttempt(
                input: AttemptInput(outcome: .flash),
                context: AttemptRuleContext(attemptNo: 2, climbHoldIds: [])
            )
        }
        #expect(error?.code == "flash_requires_first_attempt")
    }

    @Test("a send on attempt one stays valid")
    func sendOnAttemptOneIsValid() throws {
        let validation = try validateAttempt(
            input: AttemptInput(outcome: .send),
            context: AttemptRuleContext(attemptNo: 1, climbHoldIds: [])
        )
        #expect(validation.warnings.isEmpty)
    }

    @Test("the fall hold must belong to the climb")
    func fallHoldMustBelongToClimb() {
        let error = #expect(throws: DomainValidationError.self) {
            try validateAttempt(
                input: AttemptInput(outcome: .fail, fallOnHoldId: "other-climb-hold"),
                context: AttemptRuleContext(attemptNo: 1, climbHoldIds: ["hold-1"])
            )
        }
        #expect(error?.code == "fall_hold_not_on_climb")
    }

    @Test("a nil fall hold is valid for project and fail")
    func nilFallHoldIsValidForProjectAndFail() throws {
        let project = try validateAttempt(
            input: AttemptInput(outcome: .project),
            context: AttemptRuleContext(attemptNo: 2, climbHoldIds: ["hold-1"])
        )
        #expect(project.fallOnHoldId == nil)
        let fail = try validateAttempt(
            input: AttemptInput(outcome: .fail),
            context: AttemptRuleContext(attemptNo: 4, climbHoldIds: ["hold-1"])
        )
        #expect(fail.fallOnHoldId == nil)
    }

    @Test("flash and send record no fall hold and warn instead of dropping it silently")
    func outcomeContradictionWarns() throws {
        let send = try validateAttempt(
            input: AttemptInput(outcome: .send, fallOnHoldId: "hold-1"),
            context: AttemptRuleContext(attemptNo: 1, climbHoldIds: ["hold-1"])
        )
        #expect(send.fallOnHoldId == nil)
        #expect(send.warnings == [warningOutcomeRecordsNoFallHold])

        let flash = try validateAttempt(
            input: AttemptInput(outcome: .flash, fallOnHoldId: "hold-2"),
            context: AttemptRuleContext(attemptNo: 1, climbHoldIds: ["hold-2"])
        )
        #expect(flash.fallOnHoldId == nil)
        #expect(flash.warnings == [warningOutcomeRecordsNoFallHold])
    }

    @Test("an attempt number below one is rejected")
    func attemptNoMustBePositive() {
        let error = #expect(throws: DomainValidationError.self) {
            try validateAttempt(
                input: AttemptInput(outcome: .fail),
                context: AttemptRuleContext(attemptNo: 0, climbHoldIds: [])
            )
        }
        #expect(error?.code == "invalid_attempt_no")
    }

    @Test("outcome raw values match the schema CHECK constraint")
    func outcomeRawValues() {
        #expect(AttemptOutcome.allCases.map(\.rawValue) == ["flash", "send", "project", "fail"])
        #expect(isAttemptOutcome("flash"))
        #expect(!isAttemptOutcome("sent"))
    }
}
