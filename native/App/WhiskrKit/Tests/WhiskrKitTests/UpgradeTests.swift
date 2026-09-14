import Foundation
import Testing
@testable import WhiskrKit

/// What earlier builds left on disk must still open. `Fixtures/Upgrade` holds a `layout.json` and a window
/// layout (as kept in the settings) written by each checkpoint's own types (`LayoutSnapshot`, `PaneTree`,
/// `WindowLayout` of commits 124a5a7, 70f237b, c785ecc and 055b6c1, compiled as they were and given the
/// same arrangement): two workspaces, three tabs, splits within splits, a file and a diff beside
/// terminals, a pinned Claude with its session, a zoomed pane, a side panel, a name and a colour; and a
/// theme of the user's own written by the first checkpoint's `Theme`.
@Suite("Layouts saved by earlier builds")
struct UpgradeTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Upgrade", isDirectory: true)
    static let checkpoints = ["124a5a7", "70f237b", "c785ecc", "055b6c1"]
    /// The window layout gained View › Show Status Bar at c785ecc.
    static let withStatusBar: Set<String> = ["c785ecc", "055b6c1"]

    static func id(_ text: String) -> UUID { UUID(uuidString: text)! }

    /// The arrangement every fixture holds, under `/Users/someone/Projects`.
    static var expected: LayoutSnapshot {
        let root = "/Users/someone/Projects"
        let (p1, p2, p3, p4) = (id("33333333-0000-0000-0000-000000000001"), id("33333333-0000-0000-0000-000000000002"),
                                id("33333333-0000-0000-0000-000000000003"), id("33333333-0000-0000-0000-000000000004"))
        let (f1, f2) = (id("44444444-0000-0000-0000-000000000001"), id("44444444-0000-0000-0000-000000000002"))
        let (t1, t2, t3) = (id("22222222-0000-0000-0000-000000000001"), id("22222222-0000-0000-0000-000000000002"), id("22222222-0000-0000-0000-000000000003"))
        let tree1 = PaneTree.split(.init(axis: .horizontal, ratio: 0.62, first: .pane(p1),
                                         second: .split(.init(axis: .vertical, ratio: 0.4, first: .pane(p2), second: .pane(f1)))))
        let tab1 = LayoutSnapshot.Tab(id: t1, name: "build", tree: tree1, panes: [
            .init(id: p1, folder: "\(root)/alpha", isClaude: true, accountConfigDir: "\(root)/.claude-work", claudeSessionID: "sess-1",
                  claudeSessionTitle: "Fix the cart", pinned: true),
            .init(id: p2, folder: "\(root)/alpha/src", isClaude: false, accountConfigDir: nil, claudeSessionID: nil, claudeSessionTitle: nil),
        ], focusedPane: p2, zoomedPane: nil, pages: [.init(id: f1, kind: .file, path: "\(root)/alpha/README.md")])
        let tab2 = LayoutSnapshot.Tab(id: t2, name: nil, tree: .split(.init(axis: .vertical, ratio: 0.5, first: .pane(p3), second: .pane(f2))), panes: [
            .init(id: p3, folder: "\(root)/alpha", isClaude: false, accountConfigDir: nil, claudeSessionID: nil, claudeSessionTitle: nil),
        ], focusedPane: p3, zoomedPane: p3, pages: [.init(id: f2, kind: .changes, path: "\(root)/alpha/main.swift")])
        let tab3 = LayoutSnapshot.Tab(id: t3, name: "日本語のタブ", tree: .pane(p4), panes: [
            .init(id: p4, folder: "\(root)/beta", isClaude: false, accountConfigDir: nil, claudeSessionID: nil, claudeSessionTitle: nil),
        ], focusedPane: p4, zoomedPane: nil, pages: nil)
        return LayoutSnapshot(workspaces: [
            .init(id: id("11111111-0000-0000-0000-000000000001"), folder: "\(root)/alpha", tabs: [tab1, tab2], selectedTab: t2, color: 3, name: "Alpha",
                  panel: .init(shown: true, mode: .changes, width: 333)),
            .init(id: id("11111111-0000-0000-0000-000000000002"), folder: "\(root)/beta", tabs: [tab3], selectedTab: t3),
        ])
    }

    @Test("each checkpoint's layout.json opens whole", arguments: checkpoints)
    func layout(_ checkpoint: String) throws {
        let layout = try #require(LayoutSnapshot.read(from: Self.fixtures.appendingPathComponent("layout-\(checkpoint).json")))
        #expect(layout == Self.expected)
    }

    @Test("each checkpoint's window layout opens whole", arguments: checkpoints)
    func windowLayout(_ checkpoint: String) throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("window-\(checkpoint).json"))
        let window = WindowLayout(data: data)
        #expect(window == WindowLayout(navigator: .list, mode: .split, navigatorWidth: 512, showsStatusBar: !Self.withStatusBar.contains(checkpoint)))
    }

    @Test("a theme of your own saved by the first checkpoint opens, its retired colours (sidebar, hover, pressed) left out")
    func firstTheme() throws {
        let theme = try Theme.read(Data(contentsOf: Self.fixtures.appendingPathComponent("theme-124a5a7.whiskrtheme")))
        #expect(theme.id == "era-124a5a7" && theme.name == "Era One" && theme.author == "someone")
        let dark = try #require(theme.dark), light = try #require(theme.light)
        #expect(dark.terminal.background == RGBColor(0x1b1d23) && light.terminal.foreground == RGBColor(0x2b2b2b))
        #expect(dark.app[.accent] == RGBColor(0xff8800))
        #expect(dark.terminal.ansi.count == 16 && dark.tokenColors.isEmpty && dark.origin == nil)
    }

    @Test("a Workers Factory's folder and settings, carried over, open as Whiskr's")
    func legacyCarriedOver() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-upgrade-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let places = LegacyMigration.Places.standard(home: home, applicationSupport: support, newSupportFolderName: "Whiskr", newDotFolderName: ".whiskr")
        let old = places.oldSupportFolder
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Themes", isDirectory: true), withIntermediateDirectories: true)
        // The oldest layout there is, and a theme of the user's own in the old format and extension.
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("layout-124a5a7.json"), to: old.appendingPathComponent("layout.json"))
        var mine = BuiltInThemes.theme(id: "nord")!
        mine.id = "my-nord"
        mine.name = "My Nord"
        let oldFormat = String(decoding: try mine.fileData(), as: UTF8.self).replacingOccurrences(of: Theme.format, with: Theme.legacyFormat)
        try Data(oldFormat.utf8).write(to: old.appendingPathComponent("Themes/my-nord.\(Theme.legacyFileExtension)"))

        let report = LegacyMigration.migrateFolders(places, oldInUse: false)
        #expect(report.support == .moved(["layout.json", "Themes"]))
        let new = places.newSupportFolder
        #expect(LayoutSnapshot.read(from: new.appendingPathComponent("layout.json")) == Self.expected)
        let theme = try Theme.read(Data(contentsOf: new.appendingPathComponent("Themes/my-nord.\(Theme.fileExtension)")))
        #expect(theme.name == "My Nord" && theme.hasSameColors(as: mine))

        // The settings, with the window layout kept in them as data.
        let window = try Data(contentsOf: Self.fixtures.appendingPathComponent("window-124a5a7.json"))
        let settings = try #require(LegacyMigration.migratedDefaults(old: ["theme": "workers-factory", "windowLayout": window, "terminalFontSize": 14.0], new: nil))
        #expect(settings["theme"] as? String == BuiltInThemes.defaultID)
        #expect(WindowLayout(data: settings["windowLayout"] as? Data) == WindowLayout(navigator: .list, mode: .split, navigatorWidth: 512))
        #expect(settings["terminalFontSize"] as? Double == 14)
    }

    @Test("a layout that cannot be read is set aside at launch, never replaced by the launch's own")
    func unreadableSetAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("layout.json")
        let whole = try Data(contentsOf: Self.fixtures.appendingPathComponent("layout-055b6c1.json"))
        var newer = Self.expected
        newer.version = LayoutSnapshot.currentVersion + 1
        let encoder = JSONEncoder()
        let damaged: [(String, Data)] = [("cut short", whole.prefix(whole.count / 2)), ("empty", Data()), ("garbage", Data((0..<512).map { UInt8($0 % 251) })),
                                         ("newer", try encoder.encode(newer))]
        for (index, (what, data)) in damaged.enumerated() {
            try data.write(to: url)
            let now = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            let read = LayoutSnapshot.launchRead(from: url, now: now)
            #expect(read.layout == nil, "\(what)")
            let aside = try #require(read.setAside, "\(what)")
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(what)")
            #expect(try Data(contentsOf: aside) == data, "\(what): kept as it was")
            #expect(aside.lastPathComponent.hasPrefix("layout-unreadable-") && aside.pathExtension == "json", "\(what)")
        }
        // A good file is read and left in place; no file at all is nothing to set aside.
        try whole.write(to: url)
        let good = LayoutSnapshot.launchRead(from: url)
        #expect(good.layout == Self.expected && good.setAside == nil && FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: url)
        let none = LayoutSnapshot.launchRead(from: url)
        #expect(none.layout == nil && none.setAside == nil)
    }
}
