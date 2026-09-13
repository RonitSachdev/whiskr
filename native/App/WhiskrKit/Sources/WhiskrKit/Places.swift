import Foundation

/// Folders as the app shows and offers them: shortened paths, and the recent folders that the Start page
/// and File › Open Recent list (the same list in both).
public enum Places {
    /// The path with your home folder written "~".
    public static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A folder's name as a workspace shows it: "~" for home, a hidden folder with its parent
    /// ("shop/.work"), else its last part.
    public static func name(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return "/" }
        if last.hasPrefix("."), parts.count > 1 { return "\(parts[parts.count - 2])/\(last)" }
        return last
    }

    /// The folders to offer: those opened here, newest first, then those Claude Code has worked in
    /// lately (so a first launch already has some), each once, home and the excluded ones (open now)
    /// left out, and temporary folders too (a scratch run is no place to go back to). The folders are not
    /// looked at: many are in places macOS guards with a prompt, so a folder is checked only when chosen.
    public static func recents(opened: [RecentFolder], claude: [RecentFolder], excluding: Set<String> = [], home: String, limit: Int = 9) -> [RecentFolder] {
        var seen = excluding.union([home])
        var list: [RecentFolder] = []
        for folder in opened + claude where !seen.contains(folder.path) && folder.path.hasPrefix("/") && !isTemporary(folder.path) {
            seen.insert(folder.path)
            list.append(folder)
            if list.count == limit { break }
        }
        return list
    }

    static let temporaryRoots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]

    static func isTemporary(_ path: String) -> Bool {
        temporaryRoots.contains { path.hasPrefix($0) }
    }
}

/// The status line under the terminals (as herdr's status bar): where you are and how many Claudes
/// there are, how many need you.
public struct StatusSummary: Sendable, Equatable {
    public var claudes = 0
    public var needYou = 0

    public init(statuses: [AgentStatus]) {
        claudes = statuses.count
        needYou = statuses.filter { $0 == .blocked }.count
    }
}
