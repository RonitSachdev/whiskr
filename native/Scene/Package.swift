// swift-tools-version: 6.0
// The meadow scene, native: the three.js scene in `src/` (cat, meadow, village, camera) ported to Swift
// and Metal, as an AppKit view the Mac app embeds. See docs/ARCHITECTURE.md.
import PackageDescription

let package = Package(
    name: "MeadowScene",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "MeadowScene", targets: ["MeadowScene"]),
        .executable(name: "MeadowDemo", targets: ["MeadowDemo"]),
    ],
    targets: [
        // Optimised in Debug builds too: the app draws it every frame on the main thread beside its terminals,
        // and unoptimised it costs ~30× the CPU per frame (measured: 23 ms against 0.7 ms), enough to lag typing.
        .target(name: "MeadowScene", path: "Sources/MeadowScene",
                swiftSettings: [.unsafeFlags(["-O", "-enable-testing"], .when(configuration: .debug))]),
        .executableTarget(name: "MeadowDemo", dependencies: ["MeadowScene"], path: "Sources/MeadowDemo"),
        .testTarget(name: "MeadowSceneTests", dependencies: ["MeadowScene"], path: "Tests/MeadowSceneTests", resources: [.copy("Fixtures")]),
    ]
)
