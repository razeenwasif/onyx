// swift-tools-version:6.0
//
// The macOS app. The Rust core (crates/scribe-core) must be built first; it is
// linked as a static library from target/release. ./build.sh does both.

import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Scribe",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Scribe", targets: ["Scribe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
    ],
    targets: [
        .systemLibrary(name: "CScribeCore", path: "macos/CScribeCore"),
        .executableTarget(
            name: "Scribe",
            dependencies: ["CScribeCore", "SwiftMath"],
            path: "macos/Scribe",
            resources: [.copy("Resources/Fonts")],
            linkerSettings: [.unsafeFlags(["-L", "\(root)/target/release"])]
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["Scribe"],
            path: "macos/Tests",
            linkerSettings: [.unsafeFlags(["-L", "\(root)/target/release"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
