import Foundation

/// Where the app keeps its own things: its settings (user defaults) and its support folder (layout,
/// hooks, themes). Debug builds can be pointed elsewhere with `--isolated <folder>`, so a test run never
/// reads or changes the state of a Whiskr you are using (a second copy would otherwise empty
/// the first one's hooks folder at launch and overwrite its saved layout).
enum AppPlaces {
    /// The support folder's name in Application Support, and the folder in your home that holds the git
    /// worktrees the app makes (`~/.whiskr/worktrees`).
    static let supportFolderName = "Whiskr"
    static let dotFolderName = ".whiskr"

    static var applicationSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    private(set) static var defaults: UserDefaults = .standard
    private(set) static var supportFolder: URL = applicationSupport.appendingPathComponent(supportFolderName, isDirectory: true)
    /// Running against a scratch folder and settings of its own (Debug only).
    private(set) static var isIsolated = false

    /// The home folder other editors' settings and extensions are read from (Settings › General › Import
    /// Settings): yours, or in an isolated run a `Home` folder inside its own, so a test run reads only
    /// what was put there.
    static var otherEditorsHome: URL {
        isIsolated ? supportFolder.appendingPathComponent("Home", isDirectory: true) : FileManager.default.homeDirectoryForCurrentUser
    }

    #if DEBUG
    /// The settings of an isolated run, one suite per folder: test runs side by side never share settings,
    /// and a relaunch on the same folder finds its own.
    static func isolatedSuite(for folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return "app.whiskr.Whiskr.isolated." + String(hash, radix: 36)
    }

    /// Starts from empty settings (unless `keepingSettings`, to check what a relaunch brings back) and keeps
    /// everything in `folder`. Called before anything reads either.
    static func isolate(in folder: URL, keepingSettings: Bool = false) {
        // Made first: a folder's standard path depends on whether it exists (/private/tmp is /tmp once it
        // does), and a relaunch must find the same settings as the run that made the folder.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let isolatedSuite = isolatedSuite(for: folder)
        defaults = UserDefaults(suiteName: isolatedSuite) ?? .standard
        if !keepingSettings {
            // Cleared through the suite itself, key by key as well: settings left by an earlier run (or one
            // still running) must not leak into this one.
            defaults.removePersistentDomain(forName: isolatedSuite)
            for key in defaults.persistentDomain(forName: isolatedSuite)?.keys ?? Dictionary<String, Any>().keys { defaults.removeObject(forKey: key) }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        supportFolder = folder
        isIsolated = true
    }
    #endif
}
