// swift-tools-version:6.0
//
// The macOS app. The Rust core (crates/scribe-core) must be built first; it is
// linked as a static library from target/release. ./build.sh does both.
//
// The interface lives in the ScribeUI library so it can run two ways: as the
// standalone Scribe app (the thin `Scribe` executable), and embedded in the
// Electron desktop app, which loads `libScribeEmbed.dylib` and shows Scribe's
// view inside its own window (./build-embed.sh builds that).

import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let linkCore: [LinkerSetting] = [.unsafeFlags(["-L", "\(root)/target/release"])]

let package = Package(
    name: "Scribe",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Scribe", targets: ["Scribe"]),
        .library(name: "ScribeEmbed", type: .dynamic, targets: ["ScribeEmbed"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
    ],
    targets: [
        .systemLibrary(name: "CScribeCore", path: "macos/CScribeCore"),
        .target(
            name: "ScribeUI",
            dependencies: ["CScribeCore", "SwiftMath"],
            path: "macos/Scribe",
            resources: [.copy("Resources/Fonts")],
            linkerSettings: linkCore
        ),
        .executableTarget(
            name: "Scribe",
            dependencies: ["ScribeUI"],
            path: "macos/ScribeApp",
            linkerSettings: linkCore
        ),
        .target(
            name: "ScribeEmbed",
            dependencies: ["ScribeUI"],
            path: "macos/ScribeEmbed",
            linkerSettings: linkCore
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["ScribeUI"],
            path: "macos/Tests",
            linkerSettings: linkCore
        ),
    ],
    swiftLanguageModes: [.v5]
)
