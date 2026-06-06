// swift-tools-version: 5.10
// PixlPut — macOS menu bar window-memory utility.

import PackageDescription

let package = Package(
    name: "PixlPut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PixlPut", targets: ["PixlPut"]),
        .library(name: "PixlPutCore", targets: ["PixlPutCore"]),
    ],
    dependencies: [
        // Sparkle 2 — auto-updater. Used by App/Infra/Updates.swift.
        // The release pipeline signs each build with the EdDSA private key
        // generated via `sparkle_generate_keys`; the matching public key
        // lives in Resources/Info.plist under `SUPublicEDKey`.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(
            name: "PixlPutCore",
            path: "App/Core"
            // AX + CGS code lives under Core/Accessibility and Core/Spaces.
            // They link against ApplicationServices / CoreGraphics and contain
            // dlsym-based fallback wrappers around private CG symbols — safe to
            // include in the test build because no init-time AX or private-CG
            // calls happen; the calls only fire when an AXClient instance is
            // actually exercised.
        ),
        .executableTarget(
            name: "PixlPut",
            dependencies: [
                "PixlPutCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "App",
            exclude: ["Core"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                    // Sparkle.framework is bundled at Contents/Frameworks/
                    // by scripts/build-app.sh, but dyld only searches
                    // @executable_path (Contents/MacOS) by default. Add
                    // a runpath entry pointing at the framework directory.
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "PixlPutCoreTests",
            dependencies: ["PixlPutCore"],
            path: "Tests",
            exclude: ["Fixtures/README.md"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
