import Foundation
import GRDB

// with_transaction helper (port of src/data/db/transaction.ts). GRDB's inSavepoint joins an
// outer transaction automatically, so nested calls commit only at the outermost depth and a
// nested failure rolls back the entire outer transaction, exactly like the TypeScript depth
// counter. Multi table writes (log attempt, import, restore, media sweep) go through this.

extension Database {
    /// Runs body inside a savepoint that joins any open transaction. Only the outermost call
    /// commits or rolls back.
    @discardableResult
    public func withTransaction<T>(_ body: (Database) throws -> T) throws -> T {
        var value: T?
        try inSavepoint {
            value = try body(self)
            return .commit
        }
        // Only reachable when body succeeded; a thrown error propagates after the rollback.
        return value!
    }
}

/// Runs body inside a transaction on the writer, joining an outer transaction when one is
/// already open on the same connection.
@discardableResult
public func withTransaction<T>(on writer: any DatabaseWriter, _ body: @Sendable (Database) throws -> T) throws -> T where T: Sendable {
    try writer.write { db in
        try db.withTransaction(body)
    }
}
