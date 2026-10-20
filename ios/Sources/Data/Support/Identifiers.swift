import Foundation

// Id generation for UUIDv4 text primary keys (docs/decisions.md 2026-10-19, UUID ids).
// Foundation's UUID().uuidString matches the uuid v4 semantics of the TypeScript spec's
// generate_id (expo-crypto.randomUUID); lowercased because the spec's ids are lowercase hex.

public func generateID() -> String {
    UUID().uuidString.lowercased()
}
