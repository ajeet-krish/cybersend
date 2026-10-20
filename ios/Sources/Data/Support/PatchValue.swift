import Foundation

// Patch field semantics (port of the TypeScript update contracts, where `undefined` means
// unchanged and `null` means clear). Swift optionals cannot express that three state
// distinction alone, so update patches use PatchValue.
public enum PatchValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value)

    /// The value to apply over the existing one.
    public func resolve(or existing: Value) -> Value {
        switch self {
        case .unchanged: return existing
        case .set(let value): return value
        }
    }
}
