import Foundation
import GRDB
import Testing
@testable import CyberSendData

// Transaction helper tests (port of src/data/db/__tests__/transaction.test.ts): nesting joins
// the outer transaction, rollback on error at any depth, and the database stays usable after
// a rollback. The TypeScript depth counter has no public GRDB equivalent; the join semantics
// are asserted behaviorally instead.

@Suite("withTransaction")
struct TransactionTests {
    private func countSettings(_ db: Database) throws -> Int {
        Int(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM settings") ?? 0)
    }

    @Test("commits on success")
    func commitsOnSuccess() throws {
        let test = try makeTestDatabase()
        try test.writer.write { db in
            try db.withTransaction { tx in
                try tx.execute(
                    sql: "INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                    arguments: ["a", "1", "t"]
                )
            }
        }
        let count = try test.writer.read { try countSettings($0) }
        #expect(count == 1)
    }

    @Test("rolls back every write when the body throws")
    func rollsBackOnThrow() throws {
        let test = try makeTestDatabase()
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try test.writer.write { db in
                try db.withTransaction { tx in
                    try tx.execute(
                        sql: "INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                        arguments: ["a", "1", "t"]
                    )
                    try tx.execute(
                        sql: "INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                        arguments: ["b", "2", "t"]
                    )
                    throw Boom()
                }
            }
        }
        let count = try test.writer.read { try countSettings($0) }
        #expect(count == 0)

        // The database is usable again after a rollback.
        try test.writer.write { db in
            try db.withTransaction { tx in
                try tx.execute(
                    sql: "INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                    arguments: ["c", "3", "t"]
                )
            }
        }
        let after = try test.writer.read { try countSettings($0) }
        #expect(after == 1)
    }

    @Test("nested calls join the outer transaction (one commit)")
    func nestedCallsJoin() throws {
        let test = try makeTestDatabase()
        try test.writer.write { db in
            try db.withTransaction { outerTx in
                try outerTx.execute(
                    sql: "INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                    arguments: ["a", "1", "t"]
                )
                try outerTx.withTransaction { innerTx in
                    try innerTx.execute(
                        sql: "INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                        arguments: ["b", "2", "t"]
                    )
                    // Inner calls never commit; only the outermost call does.
                    let visible = try Int64.fetchOne(innerTx, sql: "SELECT COUNT(*) FROM settings") ?? 0
                    #expect(visible == 2)
                }
            }
        }
        let count = try test.writer.read { try countSettings($0) }
        #expect(count == 2)
    }

    @Test("a nested failure rolls back the entire outer transaction")
    func nestedFailureRollsBackEverything() throws {
        let test = try makeTestDatabase()
        struct InnerBoom: Error {}
        #expect(throws: InnerBoom.self) {
            try test.writer.write { db in
                try db.withTransaction { outerTx in
                    try outerTx.execute(
                        sql: "INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                        arguments: ["a", "1", "t"]
                    )
                    try outerTx.withTransaction { innerTx in
                        try innerTx.execute(
                            sql: "INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                            arguments: ["b", "2", "t"]
                        )
                        throw InnerBoom()
                    }
                }
            }
        }
        let count = try test.writer.read { try countSettings($0) }
        #expect(count == 0)
    }
}
