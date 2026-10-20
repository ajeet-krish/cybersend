import Foundation
import Testing
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// CSV export (US-14.2, port of src/features/backup/csv.ts): RFC 4180 escaping, stable
// column order matching the TypeScript spec, CRLF row endings with a trailing CRLF.

@Suite("CSV export")
struct CsvExportTests {
    @Test("escaping follows RFC 4180 (ported csv_escape cases)")
    func escapingCases() {
        #expect(csvEscape(nil) == "")
        #expect(csvEscape("plain") == "plain")
        #expect(csvEscape("42") == "42")
        #expect(csvEscape("a,b") == "\"a,b\"")
        #expect(csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(csvEscape("line\nbreak") == "\"line\nbreak\"")
        #expect(csvEscape("line\r\nbreak") == "\"line\r\nbreak\"")
        #expect(csvEscape("") == "")
    }

    @Test("rows join with CRLF and the text ends with CRLF")
    func toCsvStructure() {
        let csv = toCsv(headers: ["a", "b"], rows: [["1", nil], ["2", "x"]])
        #expect(csv == "a,b\r\n1,\r\n2,x\r\n")
    }

    @Test("sessions CSV keeps the TypeScript header order and escapes notes")
    func sessionsCsv() throws {
        let session = Session(
            id: "session-1",
            gymId: "gym-1",
            startedAt: "2026-01-01T09:00:00.000Z",
            endedAt: nil,
            rpe: 7,
            notes: "pumped, \"so\" pumped",
            createdAt: "2026-01-01T09:00:00.000Z",
            updatedAt: "2026-01-01T09:00:00.000Z"
        )
        let csv = sessionsToCsv([session])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "id,gym_id,started_at,ended_at,rpe,notes,created_at,updated_at")
        #expect(lines[1] == "session-1,gym-1,2026-01-01T09:00:00.000Z,,7,\"pumped, \"\"so\"\" pumped\",2026-01-01T09:00:00.000Z,2026-01-01T09:00:00.000Z")
    }

    @Test("attempts CSV uses the legacy fell_on_hold_id and created_at names")
    func attemptsCsv() throws {
        let attempt = Attempt(
            id: "attempt-1",
            sessionId: "session-1",
            climbId: "climb-1",
            attemptNo: 2,
            outcome: .flash,
            fallOnHoldId: "hold-9",
            attemptedAt: "2026-01-01T10:00:00.000Z"
        )
        let csv = attemptsToCsv([attempt])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "id,session_id,climb_id,attempt_no,outcome,fell_on_hold_id,notes,created_at")
        #expect(lines[1] == "attempt-1,session-1,climb-1,2,flash,hold-9,,2026-01-01T10:00:00.000Z")
    }

    @Test("climbs CSV renders flags as 1 and 0 and the scheme id as grade_system")
    func climbsCsv() throws {
        let climb = Climb(
            id: "climb-1",
            gymId: "gym-1",
            name: "Blue V4",
            gradeSystemId: "v_scale",
            gradeLevelId: "v4",
            colorCircuit: "blue",
            angleDeg: 30,
            isActive: true,
            isArchived: false,
            createdAt: "2026-01-01T09:00:00.000Z",
            updatedAt: "2026-01-01T09:00:00.000Z"
        )
        let archived = Climb(
            id: "climb-2",
            gymId: "gym-1",
            gradeSystemId: "v_scale",
            isActive: false,
            isArchived: true,
            createdAt: "2026-01-01T09:00:00.000Z",
            updatedAt: "2026-01-01T09:00:00.000Z"
        )
        let csv = climbsToCsv([climb, archived])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "id,gym_id,wall_id,name,grade_system,grade_level_id,color_circuit,angle_deg,is_active,is_archived,created_at,updated_at")
        #expect(lines[1] == "climb-1,gym-1,,Blue V4,v_scale,v4,blue,30,1,0,2026-01-01T09:00:00.000Z,2026-01-01T09:00:00.000Z")
        #expect(lines[2] == "climb-2,gym-1,,,v_scale,,,,0,1,2026-01-01T09:00:00.000Z,2026-01-01T09:00:00.000Z")
    }

    @Test("buildExportCSV reads through the repositories")
    func buildCsvFromRepositories() throws {
        let test = try makeTestDatabase()
        try seedDatabase(test.writer, repos: test.repos, rows: goldenSeedRows())

        let sessions = try buildExportCSV(repos: test.repos, entity: .sessions)
        #expect(sessions.hasPrefix("id,gym_id,started_at,ended_at,rpe,notes,created_at,updated_at\r\n"))
        #expect(sessions.contains("session-1,gym-1"))

        let attempts = try buildExportCSV(repos: test.repos, entity: .attempts)
        #expect(attempts.contains("attempt-1,session-1,climb-1,1,send,hold-1"))

        let climbs = try buildExportCSV(repos: test.repos, entity: .climbs)
        #expect(climbs.contains("climb-1,gym-1,,\"Blue \"\"V4\"\" slab\",v_scale,v4,blue,30,1,0"))
    }
}
