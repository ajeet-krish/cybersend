import Testing
@testable import CyberSendDomain

// Session RPE rules (port of src/domain/models/session.ts, US-11): session level RPE,
// integer 1 to 10, validated regardless of source.

@Suite("Session validation")
struct SessionValidationTests {
    @Test("nil RPE is valid and stays nil")
    func nilRPEIsValid() throws {
        #expect(try validateRPE(nil) == nil)
    }

    @Test("RPE accepts the full 1 to 10 range")
    func rpeRangeBoundariesAreValid() throws {
        #expect(try validateRPE(1) == 1)
        #expect(try validateRPE(10) == 10)
        #expect(try validateRPE(7) == 7)
    }

    @Test("RPE below 1 or above 10 is rejected")
    func rpeOutOfRangeThrows() {
        for value in [0, -1, 11, 99] {
            let error = #expect(throws: DomainValidationError.self) {
                try validateRPE(value)
            }
            #expect(error?.code == "rpe_out_of_range")
        }
    }

    @Test("a session is open while ended_at is nil")
    func openSessionSemantics() {
        let open = Session(id: "s1", gymId: "g1", startedAt: "t", createdAt: "t", updatedAt: "t")
        #expect(isSessionOpen(open))
        var closed = open
        closed.endedAt = "t2"
        #expect(!isSessionOpen(closed))
    }
}
