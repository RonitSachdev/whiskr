import Foundation
import Observation
import WhiskrKit

/// Settings › General, Terminal's keyboard and Alerts (docs/DESIGN.md): each applies at once and
/// is kept in the app's settings.
@Observable
final class Preferences {
    static let shared = Preferences()

    enum NewTerminalFolder: String, CaseIterable, Identifiable {
        case current, home
        var id: String { rawValue }
    }

    /// Which Option key a terminal takes as Meta (Claude Code's ⌥P, ⌥T and word moves need it); the
    /// other types characters, as iTerm2 and Ghostty split them (§9.1).
    enum OptionKey: String, CaseIterable, Identifiable {
        case left, right, both, neither
        var id: String { rawValue }
    }

    /// Restored panes that were running Claude resume its conversation (`claude --resume <id>`).
    var resumeClaude: Bool { didSet { save(resumeClaude, "resumeClaude") } }
    /// Where a new tab or split opens: the focused pane's folder, or your home folder.
    var newTerminalFolder: NewTerminalFolder { didSet { AppPlaces.defaults.set(newTerminalFolder.rawValue, forKey: "newTerminalFolder") } }
    /// While you are in another app: a notification when Claude needs you, and when it finishes.
    var notifyRequests: Bool { didSet { save(notifyRequests, "notifyRequests") } }
    var notifyFinished: Bool { didSet { save(notifyFinished, "notifyFinished") } }
    /// The Dock icon counts requests.
    var dockBadge: Bool { didSet { save(dockBadge, "dockBadge") } }
    /// The Dock icon bounces once for a request while you are in another app.
    var dockBounce: Bool { didSet { save(dockBounce, "dockBounce") } }
    /// The alert sounds (§6.4): a request (an error has its own sound, under the same switch), a finish.
    var soundRequests: Bool { didSet { save(soundRequests, "soundRequests") } }
    var soundFinished: Bool { didSet { save(soundFinished, "soundFinished") } }
    var soundVolume: Double { didSet { AppPlaces.defaults.set(soundVolume, forKey: "soundVolume") } }
    /// Pause Alerts (§6.6): no sounds and no notifications until then; nil when not paused.
    var alertsPausedUntil: Date? { didSet { AppPlaces.defaults.set(alertsPausedUntil, forKey: "alertsPausedUntil") } }
    var optionKey: OptionKey { didSet { AppPlaces.defaults.set(optionKey.rawValue, forKey: "optionKey") } }
    /// Where new git worktrees are checked out (Settings › General); nil for the usual place.
    var worktreeFolderChoice: String? { didSet { AppPlaces.defaults.set(worktreeFolderChoice, forKey: "worktreeFolder") } }

    /// Where new git worktrees go: `~/.whiskr/worktrees/<repository>/<branch>` unless chosen
    /// otherwise (a test run keeps its own, inside its folder).
    var worktreeFolder: URL {
        if let worktreeFolderChoice, !worktreeFolderChoice.isEmpty { return URL(fileURLWithPath: worktreeFolderChoice, isDirectory: true) }
        return Self.defaultWorktreeFolder
    }

    static var defaultWorktreeFolder: URL {
        if AppPlaces.isIsolated { return AppPlaces.supportFolder.appendingPathComponent("worktrees", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("\(AppPlaces.dotFolderName)/worktrees", isDirectory: true)
    }

    var alertsPaused: Bool { AlertPause.isPaused(until: alertsPausedUntil, now: Date()) }

    private init() {
        let defaults = AppPlaces.defaults
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        resumeClaude = flag("resumeClaude", true)
        newTerminalFolder = defaults.string(forKey: "newTerminalFolder").flatMap(NewTerminalFolder.init(rawValue:)) ?? .current
        notifyRequests = flag("notifyRequests", true)
        notifyFinished = flag("notifyFinished", true)
        dockBadge = flag("dockBadge", true)
        dockBounce = flag("dockBounce", false)
        soundRequests = flag("soundRequests", true)
        soundFinished = flag("soundFinished", true)
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.4
        alertsPausedUntil = defaults.object(forKey: "alertsPausedUntil") as? Date
        optionKey = defaults.string(forKey: "optionKey").flatMap(OptionKey.init(rawValue:)) ?? .left
        worktreeFolderChoice = defaults.string(forKey: "worktreeFolder")
    }

    private func save(_ value: Bool, _ key: String) {
        AppPlaces.defaults.set(value, forKey: key)
    }
}
