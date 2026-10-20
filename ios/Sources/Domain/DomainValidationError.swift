import Foundation

/// Shared domain error for rule violations (validation, lifecycle guards). Repositories throw
/// these so screens get one error shape to present (port of src/domain/errors.ts).
public struct DomainValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

extension DomainValidationError: LocalizedError {
    public var errorDescription: String? { message }
}
