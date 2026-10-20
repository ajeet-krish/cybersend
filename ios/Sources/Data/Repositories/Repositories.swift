import Foundation
import GRDB

// Repository factory (port of src/data/repositories/index.ts): one repository set per
// connection. Repositories are the only SQL surface (US-13).

public struct Repositories: Sendable {
    public let attempts: any AttemptRepository
    public let climbs: any ClimbRepository
    public let grades: any GradeRepository
    public let gyms: any GymRepository
    public let holds: any HoldRepository
    public let media: any MediaRepository
    public let sessions: any SessionRepository
    public let settings: any SettingsRepository

    public init(writer: any DatabaseWriter) {
        let grades = GRDBGradeRepository(writer: writer)
        self.attempts = GRDBAttemptRepository(writer: writer)
        self.climbs = GRDBClimbRepository(writer: writer, grades: grades)
        self.grades = grades
        self.gyms = GRDBGymRepository(writer: writer)
        self.holds = GRDBHoldRepository(writer: writer)
        self.media = GRDBMediaRepository(writer: writer)
        self.sessions = GRDBSessionRepository(writer: writer)
        self.settings = GRDBSettingsRepository(writer: writer)
    }
}

/// Hermetic repository set over an in-memory migrated database (docs/tests.md: DataTests run
/// on in-memory GRDB).
public func makeTestRepositories() throws -> (writer: DatabaseQueue, repos: Repositories) {
    let (queue, _) = try CyberSendDatabase.makeTestDatabase()
    return (queue, Repositories(writer: queue))
}
