import Foundation
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Shared support for the M2 feature store suites. Stores run on the main actor and read
// through the same hermetic in-memory repository wiring the Data tests use
// (makeTestDatabase from Tests/Data/TestSupport.swift), so no simulator is involved.

/// Seeds one active gym and returns it.
func seedGym(_ repos: Repositories, name: String = "Boulder Garden") throws -> Gym {
    try repos.gyms.create(CreateGymInput(name: name))
}

/// Seeds one quick-loggable climb (active, not archived) and returns it.
func seedClimb(_ repos: Repositories, gymId: String, name: String = "Blue V4") throws -> Climb {
    try repos.climbs.create(CreateClimbInput(gymId: gymId, name: name))
}

/// Seeds one manual hold on a climb and returns it (fall hold picker input).
func seedHold(_ repos: Repositories, climbId: String) throws -> Hold {
    try repos.holds.create(CreateHoldInput(climbId: climbId, xNorm: 0.5, yNorm: 0.55))
}
