// swift-tools-version:6.2
import PackageDescription

// The app's logic that needs no window: how hook events become agent states, how hook requests are
// checked, which Claude Code accounts and folders exist, how panes are laid out and saved, and how a
// terminal's process is launched. Kept apart from the app so `swift test` runs it in seconds.
//
// `TerminalHost` is the session host (the background process that owns the terminals) and the client
// the app talks to it with; its messages live in `WhiskrKit`.
//
// `Paw` is the `paw` command-line tool every terminal has on its PATH (agents starting and steering
// agents through the session host); `PawTool` is its `main`, which the app embeds.
//
// `WhiskrMeadow` is the one piece that knows the meadow scene (`native/Scene`): it turns the
// app's model into the scene's world, so `WhiskrKit` itself stays free of Metal and AppKit.
let package = Package(
    name: "WhiskrKit",
    // What the Kit writes for people to read (a Claude's activity line, the steps of its story) is in
    // its own string catalog, English with Japanese.
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WhiskrKit", targets: ["WhiskrKit"]),
        .library(name: "WhiskrMeadow", targets: ["WhiskrMeadow"]),
        .library(name: "TerminalHost", targets: ["TerminalHost"]),
        .library(name: "Paw", targets: ["Paw"]),
        .executable(name: "paw", targets: ["PawTool"]),
    ],
    dependencies: [
        .package(path: "../../Scene"),
    ],
    targets: [
        // FileIcons: VS Code's Seti file icons (Scripts/update-file-icons.py; FileIcons/ThirdParty).
        // Languages: TextMate grammars and language data, VS Code's and their upstreams' (Scripts/update-languages.py;
        // Languages/ThirdParty).
        .target(name: "WhiskrKit", dependencies: ["COniguruma"], resources: [.process("Localizable.xcstrings"), .copy("FileIcons"), .copy("Languages"), .copy("Themes")]),
        // Oniguruma, the regular expression engine TextMate grammars are written for (the one VS Code runs),
        // vendored at a pinned release (ThirdParty/manifest.json). Its Unicode tables are #included by
        // unicode.c, not compiled on their own.
        .target(
            name: "COniguruma",
            exclude: [
                "ThirdParty", "unicode_fold_data.c", "unicode_property_data.c", "unicode_property_data_posix.c",
                "unicode_egcb_data.c", "unicode_wb_data.c",
            ]),
        .target(name: "WhiskrMeadow", dependencies: ["WhiskrKit", .product(name: "MeadowScene", package: "Scene")]),
        .target(name: "TerminalHost", dependencies: ["WhiskrKit"]),
        .target(name: "Paw", dependencies: ["TerminalHost", "WhiskrKit"]),
        .executableTarget(name: "PawTool", dependencies: ["Paw"]),
        .testTarget(name: "WhiskrKitTests", dependencies: ["WhiskrKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TerminalHostTests", dependencies: ["TerminalHost", "WhiskrKit"]),
        .testTarget(name: "PawTests", dependencies: ["Paw", "TerminalHost", "WhiskrKit"]),
        .testTarget(name: "WhiskrMeadowTests", dependencies: ["WhiskrMeadow", "WhiskrKit", .product(name: "MeadowScene", package: "Scene")]),
    ]
)
