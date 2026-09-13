import AppKit
import TerminalHost
import WhiskrKit

/// The app was called "Workers Factory" before it was Whiskr. At launch, before anything reads settings
/// or the support folder, this carries a user's settings, layout, themes and worktree folder over to the
/// new names (`LegacyMigration`), once. A test run (`--isolated`) never does.
enum AppMigration {
    static func run() {
        migrateSettings()
        let places = LegacyMigration.Places.standard(home: FileManager.default.homeDirectoryForCurrentUser,
                                                     applicationSupport: AppPlaces.applicationSupport,
                                                     newSupportFolderName: AppPlaces.supportFolderName,
                                                     newDotFolderName: AppPlaces.dotFolderName)
        // Asked only when there is something to carry over: the check knocks on the old host's socket.
        let pending = FileManager.default.fileExists(atPath: places.oldSupportFolder.path) && !FileManager.default.fileExists(atPath: places.newSupportFolder.path)
        let report = LegacyMigration.migrateFolders(places, oldInUse: pending && oldAppInUse())
        if !report.isEmpty { NSLog("Whiskr: carried over from Workers Factory: \(report)") }
    }

    /// The old app's settings become this one's when this one has none yet.
    private static func migrateSettings() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        guard let settings = LegacyMigration.migratedDefaults(old: defaults.persistentDomain(forName: LegacyMigration.oldDefaultsDomain),
                                                              new: defaults.persistentDomain(forName: domain)) else { return }
        defaults.setPersistentDomain(settings, forName: domain)
    }

    /// The old app, or a session host it started, is still running: its terminals use the old support
    /// folder, so its files are copied rather than moved, and the host is left alone.
    private static func oldAppInUse() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: LegacyMigration.oldBundleIdentifier).isEmpty { return true }
        let legacy = HostPlaces.legacy(applicationSupport: AppPlaces.applicationSupport, temporaryFolder: FileManager.default.temporaryDirectory)
        return HostLauncher.anyHostRunning(at: legacy)
    }
}
