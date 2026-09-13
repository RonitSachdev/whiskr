import Foundation
import Observation
import WhiskrKit

/// A piece of work in a workspace: its panes and how they are split.
@Observable
final class Tab: Identifiable {
    let id: UUID
    /// A name you gave it; nil while it is named after what runs in it.
    var name: String?
    var tree: PaneTree
    private(set) var focusedPane: UUID
    var zoomedPane: UUID?
    /// Panes in the order they were last focused, latest last: focus moves to the most recent of
    /// equally near panes.
    private(set) var recency: [UUID]

    init(id: UUID = UUID(), name: String? = nil, tree: PaneTree, focusedPane: UUID? = nil, zoomedPane: UUID? = nil) {
        self.id = id
        self.name = name
        self.tree = tree
        let focused = focusedPane.flatMap { tree.contains($0) ? $0 : nil } ?? tree.panes[0]
        self.focusedPane = focused
        self.zoomedPane = zoomedPane.flatMap { tree.contains($0) ? $0 : nil }
        self.recency = [focused]
    }

    func focus(_ pane: UUID) {
        guard tree.contains(pane) else { return }
        if focusedPane != pane { focusedPane = pane }
        if recency.last != pane {
            recency.removeAll { $0 == pane }
            recency.append(pane)
        }
    }

    /// Takes a pane out; the tab is empty when this returns false.
    func remove(_ pane: UUID) -> Bool {
        guard let remaining = tree.removing(pane) else { return false }
        tree = remaining
        recency.removeAll { $0 == pane }
        if zoomedPane == pane { zoomedPane = nil }
        if focusedPane == pane { focus(recency.last ?? remaining.panes[0]) }
        return true
    }
}

/// A place to work, for one folder (usually a repository): its tabs. One blanket in the meadow.
@Observable
final class Workspace: Identifiable {
    let id: UUID
    /// The folder it was opened on: new terminals start here unless they inherit a pane's folder.
    var folder: String
    var tabs: [Tab]
    var selectedTabID: UUID?
    /// Its blanket's colour, one of six, kept for its whole life.
    let colorIndex: Int
    /// A name you gave it; nil while it is named after where it is.
    var customName: String?
    /// Where its first terminal is now: an unnamed workspace is named after it and follows its `cd`
    /// (herdr's rule), so two workspaces opened in your home folder part ways as soon as you move.
    var liveFolder: String
    /// The git repository at `liveFolder` and its branch, read off the main thread (`GitWatcher`).
    var git: GitHead?

    init(id: UUID = UUID(), folder: String, tabs: [Tab], selectedTabID: UUID? = nil, colorIndex: Int, customName: String? = nil) {
        self.id = id
        self.folder = folder
        self.liveFolder = folder
        self.tabs = tabs
        self.selectedTabID = selectedTabID ?? tabs.first?.id
        self.colorIndex = colorIndex
        self.customName = customName
    }

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// The name you gave it, else its repository's, else its folder's ("~" for your home folder; a hidden
    /// folder with its parent, "shop/.work").
    var name: String {
        if let customName, !customName.isEmpty { return customName }
        if let git { return git.name }
        return Places.name(liveFolder, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// The branch checked out where it is; nil outside a repository.
    var branch: String? { git?.branch }

    /// Where it is, with the home folder shortened to "~".
    var displayPath: String { abbreviatingHome(liveFolder) }
}

func abbreviatingHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
