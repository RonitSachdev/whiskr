import Foundation

/// Carries a user's things over from the app's earlier name, "Workers Factory", once, at the first launch
/// as Whiskr. Nothing is deleted: what is not carried over stays where it was.
///
/// - **Settings** (the user defaults of `dev.workersfactory.mac`) are copied into Whiskr's when Whiskr
///   has none yet (`migratedDefaults`).
/// - **The support folder** (`~/Library/Application Support/Workers Factory`): the user's own things in
///   it (the saved layout, the Claudes' last state, their themes) go to Whiskr's support folder when that
///   does not exist yet. They are moved, or copied while the old app or its session host still runs: that
///   host's terminals use the old folder's shell integration and hook files, so it stays as it is. The
///   rest (shell integration, hook addresses, the host's socket) is written afresh by Whiskr at launch.
/// - **`~/.workers-factory`** (git worktrees made by the app) becomes `~/.whiskr` when it holds no
///   checkout. A checkout is left where it is: git has its path on record, and saved workspaces and
///   Claude Code's history of the folder name it by that path.
public enum LegacyMigration {
    public static let oldDefaultsDomain = "dev.workersfactory.mac"
    public static let oldSupportFolderName = "Workers Factory"
    public static let oldDotFolderName = ".workers-factory"
    /// The bundle identifier the old app ran under.
    public static let oldBundleIdentifier = oldDefaultsDomain

    /// The support folder's entries that are the user's own, carried over. Anything else is regenerated.
    public static let carriedEntries = ["layout.json", "agents.json", "Themes"]

    /// Where things were and where they go.
    public struct Places: Sendable, Equatable {
        public var oldSupportFolder: URL
        public var newSupportFolder: URL
        public var oldDotFolder: URL
        public var newDotFolder: URL

        public init(oldSupportFolder: URL, newSupportFolder: URL, oldDotFolder: URL, newDotFolder: URL) {
            self.oldSupportFolder = oldSupportFolder
            self.newSupportFolder = newSupportFolder
            self.oldDotFolder = oldDotFolder
            self.newDotFolder = newDotFolder
        }

        /// The usual places in a home folder.
        public static func standard(home: URL, applicationSupport: URL, newSupportFolderName: String, newDotFolderName: String) -> Places {
            Places(oldSupportFolder: applicationSupport.appendingPathComponent(oldSupportFolderName, isDirectory: true),
                   newSupportFolder: applicationSupport.appendingPathComponent(newSupportFolderName, isDirectory: true),
                   oldDotFolder: home.appendingPathComponent(oldDotFolderName, isDirectory: true),
                   newDotFolder: home.appendingPathComponent(newDotFolderName, isDirectory: true))
        }
    }

    public enum SupportOutcome: Sendable, Equatable {
        /// No old folder, or Whiskr already has one.
        case nothingToDo
        /// These entries were moved.
        case moved([String])
        /// These entries were copied (the old app or its session host is still running).
        case copied([String])
        case failed(String)
    }

    public enum DotFolderOutcome: Sendable, Equatable {
        case nothingToDo
        case moved
        /// Left in place: it holds git worktree checkouts.
        case keptCheckouts(Int)
        case failed(String)
    }

    public struct Report: Sendable, Equatable {
        public var support: SupportOutcome
        public var dotFolder: DotFolderOutcome
        /// Theme files renamed to the current extension.
        public var themesRenamed: Int

        /// Nothing was found to carry over.
        public var isEmpty: Bool { support == .nothingToDo && dotFolder == .nothingToDo }
    }

    // MARK: Folders

    /// Moves or copies what there is to carry over. `oldInUse`: the old app or its session host is
    /// running. Safe to run at every launch: once Whiskr's folders exist it does nothing.
    public static func migrateFolders(_ places: Places, oldInUse: Bool, files: FileManager = .default) -> Report {
        let support = migrateSupportFolder(places, oldInUse: oldInUse, files: files)
        var renamed = 0
        switch support {
        case .moved, .copied: renamed = renameLegacyThemes(in: places.newSupportFolder.appendingPathComponent("Themes", isDirectory: true), files: files)
        case .nothingToDo, .failed: break
        }
        return Report(support: support, dotFolder: migrateDotFolder(places, files: files), themesRenamed: renamed)
    }

    static func migrateSupportFolder(_ places: Places, oldInUse: Bool, files: FileManager) -> SupportOutcome {
        guard isDirectory(places.oldSupportFolder, files), !files.fileExists(atPath: places.newSupportFolder.path) else { return .nothingToDo }
        let entries = carriedEntries.filter { files.fileExists(atPath: places.oldSupportFolder.appendingPathComponent($0).path) }
        // Assembled beside the destination, then put in place with one rename: a launch that stops half
        // way leaves no partial folder that a later launch would take for a finished one.
        let staging = places.newSupportFolder.deletingLastPathComponent()
            .appendingPathComponent(".\(places.newSupportFolder.lastPathComponent).migrating-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for entry in entries {
                let from = places.oldSupportFolder.appendingPathComponent(entry), to = staging.appendingPathComponent(entry)
                // Copied first even when moving: the old entries are removed only once all are in place.
                try files.copyItem(at: from, to: to)
            }
            try files.moveItem(at: staging, to: places.newSupportFolder)
        } catch {
            try? files.removeItem(at: staging)
            return .failed("\(error.localizedDescription)")
        }
        guard !oldInUse else { return .copied(entries) }
        for entry in entries { try? files.removeItem(at: places.oldSupportFolder.appendingPathComponent(entry)) }
        return .moved(entries)
    }

    static func migrateDotFolder(_ places: Places, files: FileManager) -> DotFolderOutcome {
        guard isDirectory(places.oldDotFolder, files), !files.fileExists(atPath: places.newDotFolder.path) else { return .nothingToDo }
        let checkouts = worktreeCheckouts(in: places.oldDotFolder.appendingPathComponent("worktrees", isDirectory: true), files: files)
        guard checkouts == 0 else { return .keptCheckouts(checkouts) }
        do {
            try files.moveItem(at: places.oldDotFolder, to: places.newDotFolder)
            return .moved
        } catch {
            return .failed("\(error.localizedDescription)")
        }
    }

    /// Checkouts under `worktrees/<repository>/<branch…>`: folders with a `.git` entry, at any depth (a
    /// branch name may contain slashes), not looking inside a checkout.
    static func worktreeCheckouts(in folder: URL, files: FileManager) -> Int {
        guard let children = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return 0 }
        return children.reduce(0) { count, child in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return count }
            if files.fileExists(atPath: child.appendingPathComponent(".git").path) { return count + 1 }
            return count + worktreeCheckouts(in: child, files: files)
        }
    }

    /// Renames `*.wftheme` to the current extension, unless a file of that name is already there.
    static func renameLegacyThemes(in folder: URL, files: FileManager) -> Int {
        let themes = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var renamed = 0
        for theme in themes where theme.pathExtension == Theme.legacyFileExtension {
            let target = theme.deletingPathExtension().appendingPathExtension(Theme.fileExtension)
            guard !files.fileExists(atPath: target.path), (try? files.moveItem(at: theme, to: target)) != nil else { continue }
            renamed += 1
        }
        return renamed
    }

    private static func isDirectory(_ url: URL, _ files: FileManager) -> Bool {
        var directory: ObjCBool = false
        return files.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: Settings

    /// Settings that are not carried over: the notification permission belongs to the bundle identifier,
    /// so Whiskr must ask again itself.
    public static let droppedDefaultsKeys: Set<String> = ["notificationsRequested"]
    /// The built-in theme's identifier before the rename.
    public static let oldDefaultThemeID = "workers-factory"

    /// The old app's settings as Whiskr's: the same keys, the old built-in theme's identifier replaced.
    /// Nil when there is nothing to carry over or Whiskr already has settings of its own.
    public static func migratedDefaults(old: [String: Any]?, new: [String: Any]?) -> [String: Any]? {
        guard let old, !old.isEmpty, new?.isEmpty ?? true else { return nil }
        var settings = old.filter { !droppedDefaultsKeys.contains($0.key) }
        if settings["theme"] as? String == oldDefaultThemeID { settings["theme"] = BuiltInThemes.defaultID }
        return settings
    }
}
