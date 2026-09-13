import Foundation
import Testing
@testable import WhiskrKit

/// A scratch home with an Application Support folder, laid out as a Workers Factory left it.
private final class ScratchHome {
    let url: URL
    let places: LegacyMigration.Places

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-migration-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let support = url.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        places = .standard(home: url, applicationSupport: support, newSupportFolderName: "Whiskr", newDotFolderName: ".whiskr")
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ contents: String, under folder: URL) throws {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    func read(_ path: String, under folder: URL) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String, under folder: URL) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }

    /// The old app's support folder with a layout, the Claudes' state, a theme, and what it regenerates.
    func oldSupportFolder() throws {
        let old = places.oldSupportFolder
        try write("layout.json", #"{"workspaces":["shop"]}"#, under: old)
        try write("agents.json", #"{"agents":[]}"#, under: old)
        try write("Themes/Paper.wftheme", #"{"format":"workers-factory-theme","name":"Paper"}"#, under: old)
        try write("shell/share/fish/vendor_conf.d/workers-factory.fish", "# old", under: old)
        try write("hooks/settings.json", "{}", under: old)
        try write("host/host.lock", "", under: old)
    }
}

@Suite("Carrying a Workers Factory's things over to Whiskr")
struct LegacyMigrationTests {
    @Test("the layout, the Claudes' state and the themes move; what the app regenerates stays behind")
    func movesTheUsersThings() throws {
        let home = try ScratchHome()
        try home.oldSupportFolder()
        let report = LegacyMigration.migrateFolders(home.places, oldInUse: false)
        #expect(report.support == .moved(["layout.json", "agents.json", "Themes"]))
        #expect(report.themesRenamed == 1)
        let new = home.places.newSupportFolder, old = home.places.oldSupportFolder
        #expect(home.read("layout.json", under: new) == #"{"workspaces":["shop"]}"#)
        #expect(home.read("agents.json", under: new) == #"{"agents":[]}"#)
        #expect(home.exists("Themes/Paper.whiskrtheme", under: new))
        #expect(!home.exists("Themes/Paper.wftheme", under: new))
        // Only the user's own things came over; the old shell integration (which would run in fish) did not.
        #expect(!home.exists("shell", under: new) && !home.exists("hooks", under: new) && !home.exists("host", under: new))
        #expect(!home.exists("layout.json", under: old) && !home.exists("Themes", under: old))
        #expect(home.exists("host/host.lock", under: old))
        // Private, as the app's own folder is.
        let mode = try FileManager.default.attributesOfItem(atPath: new.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test("while the old app or its session host runs, everything is copied and the old folder is left whole")
    func copiesWhileInUse() throws {
        let home = try ScratchHome()
        try home.oldSupportFolder()
        let report = LegacyMigration.migrateFolders(home.places, oldInUse: true)
        #expect(report.support == .copied(["layout.json", "agents.json", "Themes"]))
        let new = home.places.newSupportFolder, old = home.places.oldSupportFolder
        #expect(home.read("layout.json", under: new) == home.read("layout.json", under: old))
        #expect(home.exists("Themes/Paper.whiskrtheme", under: new))
        #expect(home.exists("Themes/Paper.wftheme", under: old))
        #expect(home.exists("shell/share/fish/vendor_conf.d/workers-factory.fish", under: old))
    }

    @Test("it happens once: an existing Whiskr folder is never touched, and a second run does nothing")
    func onlyOnce() throws {
        let home = try ScratchHome()
        try home.oldSupportFolder()
        try home.write("layout.json", #"{"workspaces":["mine"]}"#, under: home.places.newSupportFolder)
        let report = LegacyMigration.migrateFolders(home.places, oldInUse: false)
        #expect(report.support == .nothingToDo)
        #expect(home.read("layout.json", under: home.places.newSupportFolder) == #"{"workspaces":["mine"]}"#)
        #expect(home.exists("layout.json", under: home.places.oldSupportFolder))
        #expect(LegacyMigration.migrateFolders(home.places, oldInUse: false).isEmpty)
    }

    @Test("with no old app ever installed there is nothing to do and nothing is created")
    func nothingToCarry() throws {
        let home = try ScratchHome()
        let report = LegacyMigration.migrateFolders(home.places, oldInUse: false)
        #expect(report.isEmpty && report.themesRenamed == 0)
        #expect(!FileManager.default.fileExists(atPath: home.places.newSupportFolder.path))
        #expect(!FileManager.default.fileExists(atPath: home.places.newDotFolder.path))
    }

    @Test("an old folder holding none of the user's things still becomes an (empty) Whiskr folder")
    func emptyOldFolder() throws {
        let home = try ScratchHome()
        try home.write("shell/bin/claude", "#!/bin/sh", under: home.places.oldSupportFolder)
        #expect(LegacyMigration.migrateFolders(home.places, oldInUse: false).support == .moved([]))
        #expect(FileManager.default.fileExists(atPath: home.places.newSupportFolder.path))
    }

    @Test("a theme already present under the new extension is not overwritten")
    func themeClash() throws {
        let home = try ScratchHome()
        try home.oldSupportFolder()
        try home.write("Themes/Paper.whiskrtheme", "mine", under: home.places.oldSupportFolder)
        let report = LegacyMigration.migrateFolders(home.places, oldInUse: false)
        #expect(report.themesRenamed == 0)
        #expect(home.read("Themes/Paper.whiskrtheme", under: home.places.newSupportFolder) == "mine")
        #expect(home.exists("Themes/Paper.wftheme", under: home.places.newSupportFolder))
    }

    @Test("a theme file of the old format still reads")
    func oldThemeFormatReads() throws {
        var data = try BuiltInThemes.theme(id: "gruvbox")!.fileData()
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: Theme.format, with: Theme.legacyFormat)
        #expect(text.contains(Theme.legacyFormat))
        data = Data(text.utf8)
        #expect(try Theme.read(data).name == "Gruvbox")
        #expect(throws: (any Error).self) { try Theme.read(Data(#"{"format":"someone-elses-theme","name":"x"}"#.utf8)) }
    }

    @Test("~/.workers-factory with no checkout in it becomes ~/.whiskr")
    func movesAnEmptyWorktreeFolder() throws {
        let home = try ScratchHome()
        try FileManager.default.createDirectory(at: home.places.oldDotFolder.appendingPathComponent("worktrees/shop"), withIntermediateDirectories: true)
        #expect(LegacyMigration.migrateFolders(home.places, oldInUse: false).dotFolder == .moved)
        #expect(FileManager.default.fileExists(atPath: home.places.newDotFolder.appendingPathComponent("worktrees/shop").path))
        #expect(!FileManager.default.fileExists(atPath: home.places.oldDotFolder.path))
    }

    @Test("~/.workers-factory holding git worktree checkouts stays where git and saved workspaces know it")
    func keepsCheckouts() throws {
        let home = try ScratchHome()
        let worktrees = home.places.oldDotFolder.appendingPathComponent("worktrees", isDirectory: true)
        try home.write("shop/wt/mittens/.git", "gitdir: /somewhere/shop/.git/worktrees/mittens", under: worktrees)
        try home.write("shop/feature/cart/.git", "gitdir: /somewhere/shop/.git/worktrees/cart", under: worktrees)
        try home.write("shop/feature/cart/src/inner/.git", "not counted: inside a checkout", under: worktrees)
        let report = LegacyMigration.migrateFolders(home.places, oldInUse: false)
        #expect(report.dotFolder == .keptCheckouts(2))
        #expect(FileManager.default.fileExists(atPath: worktrees.appendingPathComponent("shop/wt/mittens/.git").path))
        #expect(!FileManager.default.fileExists(atPath: home.places.newDotFolder.path))
    }

    @Test("settings come over when Whiskr has none; the old theme id is renamed; permissions are asked anew")
    func settings() throws {
        let old: [String: Any] = ["theme": "workers-factory", "recentFolders": [["path": "/code/shop", "time": 1.0]],
                                  "soundVolume": 0.25, "notificationsRequested": true]
        let carried = try #require(LegacyMigration.migratedDefaults(old: old, new: nil))
        #expect(carried["theme"] as? String == BuiltInThemes.defaultID)
        #expect(carried["soundVolume"] as? Double == 0.25)
        #expect((carried["recentFolders"] as? [[String: Any]])?.first?["path"] as? String == "/code/shop")
        #expect(carried["notificationsRequested"] == nil)
        // A theme of the user's own keeps its id.
        #expect(LegacyMigration.migratedDefaults(old: ["theme": "nord"], new: [:])?["theme"] as? String == "nord")
        // Whiskr's own settings are never replaced; nothing old means nothing to do.
        #expect(LegacyMigration.migratedDefaults(old: old, new: ["theme": "dracula"]) == nil)
        #expect(LegacyMigration.migratedDefaults(old: nil, new: nil) == nil)
        #expect(LegacyMigration.migratedDefaults(old: [:], new: nil) == nil)
    }
}
