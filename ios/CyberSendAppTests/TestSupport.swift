import Foundation

// Shared helpers for the app level XCTest smoke suites (docs/architecture.md test
// strategy: app level XCTest covers the composition root and launch states).

/// Creates a unique temporary directory for a storage root and removes it on teardown.
func makeTemporaryRoot(label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cybersend-app-tests", isDirectory: true)
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func removeTemporaryRoot(_ root: URL) {
    // Remove only this test's unique root; the shared parent directory stays so parallel
    // tests never wipe each other's working directory (review 2026-10-20, teardown scope).
    try? FileManager.default.removeItem(at: root)
}
