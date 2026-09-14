import Foundation

/// Everything about the window's arrangement that is brought back on the next launch: workspaces, their
/// tabs and splits, and what ran in each pane. After the app was quit, each pane is put back onto its
/// terminal, which kept running in the session host under the pane's id. After the Mac restarted (or
/// the terminal ended meanwhile), a shell pane comes back as a fresh shell in its folder (no command is
/// ever re-run), and a Claude pane comes back running `claude --resume <session>`, which loads the
/// conversation and waits.
public struct LayoutSnapshot: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public var version = Self.currentVersion
    /// In the meadow's order. Which one was selected is not kept: a launch always lands on Home (an older
    /// file's `selectedWorkspace` is read past).
    public var workspaces: [Workspace]

    public init(workspaces: [Workspace]) {
        self.workspaces = workspaces
    }

    public struct Workspace: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        /// The folder the workspace is for; new terminals start here unless they inherit a pane's folder.
        public var folder: String
        public var tabs: [Tab]
        public var selectedTab: UUID?
        /// Its blanket's colour (one of six), kept for its life; nil in layouts saved before colours were.
        public var color: Int?
        /// A name you gave it; nil while it is named after its repository or folder.
        public var name: String?
        /// Its side panel (Files or Changes); nil in layouts saved before there was one.
        public var panel: Panel?

        public init(id: UUID, folder: String, tabs: [Tab], selectedTab: UUID?, color: Int? = nil, name: String? = nil, panel: Panel? = nil) {
            self.id = id
            self.folder = folder
            self.tabs = tabs
            self.selectedTab = selectedTab
            self.color = color
            self.name = name
            self.panel = panel
        }

        /// The colour for a new workspace: the one fewest of `taken` have (the first of those in order),
        /// so the six go round in turn and two neighbours rarely share one.
        public static func nextColor(after taken: [Int], of count: Int = 6) -> Int {
            let uses = (0..<count).map { color in taken.filter { $0 == color }.count }
            let least = uses.min() ?? 0
            // After the last colour handed out, the next least-used one, so they go round in turn.
            let start = ((taken.last ?? -1) + 1) % count
            return (0..<count).map { (start + $0) % count }.first { uses[$0] == least } ?? 0
        }
    }

    public struct Tab: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        /// A name you gave it; nil while it is named after what runs in it.
        public var name: String?
        public var tree: PaneTree
        public var panes: [Pane]
        public var focusedPane: UUID?
        public var zoomedPane: UUID?
        /// The files and diffs in its tree beside (or instead of) terminals; nil in layouts saved before
        /// files opened in tabs.
        public var pages: [Page]?

        public init(id: UUID, name: String?, tree: PaneTree, panes: [Pane], focusedPane: UUID?, zoomedPane: UUID?, pages: [Page]? = nil) {
            self.id = id
            self.name = name
            self.tree = tree
            self.panes = panes
            self.focusedPane = focusedPane
            self.zoomedPane = zoomedPane
            self.pages = pages
        }
    }

    /// A file or a diff open in a tab, by its place in the tab's tree.
    public struct Page: Sendable, Equatable, Codable, Identifiable {
        public enum Kind: String, Sendable, Codable {
            /// The file itself, in the editor or its preview.
            case file
            /// Its changes against HEAD.
            case changes
            /// Its staged changes.
            case stagedChanges
        }

        public var id: UUID
        public var kind: Kind
        public var path: String

        public init(id: UUID, kind: Kind, path: String) {
            self.id = id
            self.kind = kind
            self.path = path
        }
    }

    /// A workspace's side panel: whether it shows, in which mode, how wide.
    public struct Panel: Sendable, Equatable, Codable {
        public enum Mode: String, Sendable, Codable { case files, changes }

        public var shown: Bool
        public var mode: Mode
        public var width: Double

        public init(shown: Bool = false, mode: Mode = .files, width: Double = 280) {
            self.shown = shown
            self.mode = mode
            self.width = width
        }
    }

    /// A pane's id is its identity for good: hook events are routed by it, and it names the pane's
    /// terminal in the session host, which is how a relaunched app finds it again.
    public struct Pane: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        /// The folder its shell was in when last seen.
        public var folder: String
        /// It was running Claude when the app quit: it reopens running Claude again.
        public var isClaude: Bool
        /// The account's config folder, for a pane that ran Claude; nil for the default account or a shell.
        public var accountConfigDir: String?
        /// The Claude session that last ran in it, reopened with `claude --resume`; nil when none had
        /// started (a Claude pane without one reopens a fresh session) or for a plain shell.
        public var claudeSessionID: String?
        public var claudeSessionTitle: String?
        /// Its Claude is pinned: marked, and listed first (herdr's pin, D3); nil (not pinned) in layouts
        /// saved before pins were.
        public var pinned: Bool?

        public init(id: UUID, folder: String, isClaude: Bool, accountConfigDir: String?, claudeSessionID: String?, claudeSessionTitle: String?,
                    pinned: Bool? = nil) {
            self.id = id
            self.folder = folder
            self.isClaude = isClaude
            self.accountConfigDir = accountConfigDir
            self.claudeSessionID = claudeSessionID
            self.claudeSessionTitle = claudeSessionTitle
            self.pinned = pinned
        }
    }

    // MARK: Files

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    /// The saved layout, or nil when there is none or it cannot be used (another version, damaged).
    /// A layout that cannot be used is never fatal: the app starts fresh.
    public static func read(from url: URL) -> LayoutSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(LayoutSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot.repaired
    }

    /// The saved layout as a launch takes it. A file that is there but cannot be used (damaged, cut
    /// short, or written by a newer version) is first renamed aside, to `layout-unreadable-<time>.json`
    /// beside it: the launch starts fresh and saves its own layout, which must not replace the only copy
    /// of yours. `setAside` is the name it was given, when one was.
    public static func launchRead(from url: URL, now: Date = Date()) -> (layout: LayoutSnapshot?, setAside: URL?) {
        if let layout = read(from: url) { return (layout, nil) }
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-unreadable-\(stamp).json")
        guard (try? FileManager.default.moveItem(at: url, to: aside)) != nil else { return (nil, nil) }
        return (nil, aside)
    }

    /// The same layout with anything inconsistent dropped: tabs whose tree and pane (and page) lists disagree or
    /// that reuse a pane from another tab (hook events are routed by pane), empty workspaces, and
    /// selections pointing at nothing.
    public var repaired: LayoutSnapshot {
        var copy = self
        var seen = Set<UUID>()
        copy.workspaces = workspaces.compactMap { workspace in
            var workspace = workspace
            workspace.tabs = workspace.tabs.compactMap { tab in
                var tab = tab
                let ids = tab.tree.panes
                let held = tab.panes.map(\.id) + (tab.pages ?? []).map(\.id)
                guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids) == Set(held),
                      held.count == ids.count, seen.isDisjoint(with: ids) else { return nil }
                seen.formUnion(ids)
                if let focused = tab.focusedPane, !ids.contains(focused) { tab.focusedPane = nil }
                if let zoomed = tab.zoomedPane, !ids.contains(zoomed) { tab.zoomedPane = nil }
                return tab
            }
            guard !workspace.tabs.isEmpty else { return nil }
            if let selected = workspace.selectedTab, !workspace.tabs.contains(where: { $0.id == selected }) { workspace.selectedTab = nil }
            return workspace
        }
        return copy
    }
}
