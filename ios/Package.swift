// swift-tools-version: 6.0
// CyberSend native core package (ios/). Two targets: CyberSendDomain (pure, zero dependencies)
// and CyberSendData (GRDB, the only SQL surface). The iOS app target (SwiftUI, M1/M2) is not
// part of this package; it builds in Xcode and depends on these products.

import PackageDescription

let package = Package(
    name: "CyberSendCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CyberSendDomain", targets: ["CyberSendDomain"]),
        .library(name: "CyberSendData", targets: ["CyberSendData"]),
        .library(name: "CyberSendFeatures", targets: ["CyberSendFeatures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.3.0"),
        // This machine runs the CommandLineTools toolchain, which does not bundle the
        // swift-testing module that Xcode toolchains provide. Depending on the package makes
        // `import Testing` work everywhere; harmless under Xcode.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.0.0"),
        // .cybersend backup archives are zips (docs/decisions.md, backup as a .cybersend zip
        // with staging import). ZIPFoundation is Apache-2.0 and pure Foundation plus zlib.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "CyberSendDomain",
            path: "Sources/Domain"
        ),
        .target(
            name: "CyberSendData",
            dependencies: [
                "CyberSendDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Data"
        ),
        .target(
            name: "CyberSendFeatures",
            dependencies: [
                "CyberSendDomain",
                "CyberSendData",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/Features"
        ),
        .testTarget(
            name: "CyberSendCoreTests",
            dependencies: [
                "CyberSendDomain",
                "CyberSendData",
                "CyberSendFeatures",
                .product(name: "Testing", package: "swift-testing"),
                // Crafted malformed archives for the unpack failure paths.
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Tests",
            resources: [
                // Golden fixtures for the US-14 export round trip and the import-side
                // compatibility suite (old exports must always import).
                .copy("Fixtures"),
            ],
            linkerSettings: [
                // The CommandLineTools toolchain ships lib_TestingInterop (needed by the
                // swift-testing package) under Library/Developer/usr/lib, which the linker
                // does not search by default and dyld does not add as an rpath. The flags are
                // inert on Xcode toolchains that already expose the library.
                .unsafeFlags([
                    "-L", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
