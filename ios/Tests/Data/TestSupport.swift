import Foundation
import GRDB
@testable import CyberSendData

// Shared DataTests support: hermetic in-memory GRDB databases through the same migration
// runner and repository wiring the app uses (docs/tests.md).

struct TestDatabase {
    let writer: DatabaseQueue
    let repos: Repositories
}

/// Fresh migrated in-memory database per test, mirroring the TypeScript create_test_database.
func makeTestDatabase() throws -> TestDatabase {
    let (writer, repos) = try makeTestRepositories()
    return TestDatabase(writer: writer, repos: repos)
}

func tableNames(_ db: Database) throws -> [String] {
    try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    )
}

func indexedNames(_ db: Database) throws -> [String] {
    try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%' ORDER BY name"
    )
}

/// Seeds one gym plus one climb and returns their ids (shared fixture).
func seedGymAndClimb(_ repos: Repositories) throws -> (gymId: String, climbId: String) {
    let gym = try repos.gyms.create(CreateGymInput(name: "Boulder Garden"))
    let climb = try repos.climbs.create(CreateClimbInput(gymId: gym.id, name: "Blue V4"))
    return (gym.id, climb.id)
}
