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
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
}
