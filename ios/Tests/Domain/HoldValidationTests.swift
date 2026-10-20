import Foundation
import Testing
@testable import CyberSendDomain

// Hold coordinate rules (port of src/domain/models/hold.ts): normalized 0..1 at the domain
// boundary, radius positive (docs/decisions.md, normalized coordinates).

@Suite("Hold validation")
struct HoldValidationTests {
    @Test("normalized coordinates inside the unit square pass")
    func validCoordinatesPass() throws {
        try validateHoldCoords(xNorm: 0, yNorm: 0, radiusNorm: 0.02)
        try validateHoldCoords(xNorm: 1, yNorm: 1, radiusNorm: 1)
        try validateHoldCoords(xNorm: 0.5, yNorm: 0.25, radiusNorm: 0.05)
    }

    @Test("x outside 0 to 1 is rejected")
    func xOutOfRangeThrows() {
        for x in [-0.1, 1.1] {
            let error = #expect(throws: DomainValidationError.self) {
                try validateHoldCoords(xNorm: x, yNorm: 0.5, radiusNorm: 0.02)
            }
            #expect(error?.code == "hold_x_out_of_range")
        }
    }

    @Test("y outside 0 to 1 is rejected")
    func yOutOfRangeThrows() {
        for y in [-0.1, 1.1] {
            let error = #expect(throws: DomainValidationError.self) {
                try validateHoldCoords(xNorm: 0.5, yNorm: y, radiusNorm: 0.02)
            }
            #expect(error?.code == "hold_y_out_of_range")
        }
    }

    @Test("a radius of zero or below is rejected")
    func radiusMustBePositive() {
        for radius in [0.0, -0.01] {
            let error = #expect(throws: DomainValidationError.self) {
                try validateHoldCoords(xNorm: 0.5, yNorm: 0.5, radiusNorm: radius)
            }
            #expect(error?.code == "hold_radius_invalid")
        }
    }

    @Test("non finite coordinates are rejected")
    func nonFiniteCoordinatesThrow() {
        let nan = Double.nan
        let error = #expect(throws: DomainValidationError.self) {
            try validateHoldCoords(xNorm: nan, yNorm: 0.5, radiusNorm: 0.02)
        }
        #expect(error?.code == "hold_x_out_of_range")
    }

    @Test("hold roles are the US-19 enum values")
    func holdRoleValues() {
        #expect(HoldRole.allCases.map(\.rawValue) == ["start", "intermediate", "top"])
        #expect(HoldSource.allCases.map(\.rawValue) == ["manual", "detection", "board"])
    }
}
