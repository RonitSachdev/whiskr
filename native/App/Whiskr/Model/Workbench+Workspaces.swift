import Foundation
import WhiskrKit

/// What a tab can show besides terminals. A page takes a terminal's place in its tab's tree (its id is
/// a leaf there, kept in `Workbench.pages` rather than `panes`), so everything that walks a tab's
/// terminals simply finds none, and a file can sit in a split beside terminals. Files and diffs are
/// saved with the layout; the Start page is not.
enum TabPage: Equatable {
    /// Where a new workspace begins (⌘N): open a folder, a terminal, or a recent folder.
    case start
    /// A file, in the editor or its preview (Workbench+Files.swift).
    case file(path: String)
    /// A file's changes: its unstaged ones against the index, or (`staged`) its staged ones against HEAD.
    case changes(path: String, staged: Bool)

    var title: String {
        switch self {
        case .start: String(localized: "Start", comment: "Title of the Start page's tab")
        case .file(let path): URL(fileURLWithPath: path).lastPathComponent
        case .changes(let path, let staged):
            staged ? String(localized: "\(URL(fileURLWithPath: path).lastPathComponent) · Staged", comment: "Tab title: a file's staged changes")
                : String(localized: "\(URL(fileURLWithPath: path).lastPathComponent) · Changes", comment: "Tab title: a file's changes")
        }
    }

    /// The file it shows, for a file or its changes.
    var path: String? {
        switch self {
        case .start: nil
        case .file(let path), .changes(let path, _): path
        }
    }

    /// Saved with the layout and brought back at the next launch.
    var isKept: Bool { path != nil }

    var isDiff: Bool {
        if case .changes = self { return true }
        return false
    }
}

/// Workspaces beyond opening and closing: the Start page, names that follow the shell, renaming,
/// moving tabs between workspaces, pins and Mark as Unread.
extension Workbench {
    // MARK: The Start page

    /// File › New Workspace (⌘N): a workspace whose one tab is the Start page, in your home folder until
    /// you choose. An unused one is reused rather than another made beside it.
    @discardableResult
    func newStartWorkspace() -> Workspace {
        if let unused = workspaces.first(where: isUnusedStart) {
            select(workspace: unused)
            return unused
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let workspace = Workspace(folder: home, tabs: [], colorIndex: LayoutSnapshot.Workspace.nextColor(after: workspaces.map(\.colorIndex)))
        let page = UUID()
        pages[page] = .start
        let tab = Tab(tree: .pane(page))
        workspace.tabs = [tab]
        workspace.selectedTabID = tab.id
        append(workspace)
        selectedWorkspaceID = workspace.id
        if focusedAgent != nil { focusedAgent = nil }
        noteVisit(tab)
        return workspace
    }

    /// A workspace holding nothing but a Start page.
    func isUnusedStart(_ workspace: Workspace) -> Bool {
        workspace.tabs.count == 1 && workspace.tabs[0].tree.panes.allSatisfy { pages[$0] == .start }
    }

    /// The page a tab shows, when it shows one.
    func page(in tab: Tab) -> (id: UUID, page: TabPage)? {
        guard tab.tree.panes.count == 1, let id = tab.tree.panes.first, let page = pages[id] else { return nil }
        return (id, page)
    }

    /// The Start page's "New Terminal": a shell where the workspace is.
    func startTerminal(from page: UUID) {
        guard let (workspace, _) = workspace(of: page) else { return }
        replace(page: page, folder: workspace.folder, remembering: false)
    }

    /// The Start page's "Open Folder…" or a recent folder: the workspace moves there with a shell, or,
    /// when that folder is already open, that workspace is shown and this Start page goes.
    func start(from page: UUID, folder: String) {
        guard let (workspace, tab) = workspace(of: page) else { return }
        if let open = workspaces.first(where: { $0 !== workspace && $0.folder == folder }) {
            remember(folder: folder)
            workspace.tabs.removeAll { $0 === tab }
            pages[page] = nil
            if workspace.tabs.isEmpty { removeEmpty(workspace) }
            select(workspace: open)
            scheduleSave()
            return
        }
        replace(page: page, folder: folder, remembering: true)
    }

    private func replace(page: UUID, folder: String, remembering: Bool) {
        guard let (workspace, tab) = workspace(of: page) else { return }
        if remembering { remember(folder: folder) }
        if workspace.tabs.count == 1 {
            workspace.folder = folder
            workspace.liveFolder = folder
            git.follow(workspace.id, folder: folder)
        }
        let pane = makePane(folder: folder)
        tab.tree = tab.tree.replacing(page, with: pane.id)
        pages[page] = nil
        focus(pane: pane.id)
        scheduleSave()
    }

    // MARK: Names

    /// An unnamed workspace is named after where its first terminal is, following its `cd` (herdr's
    /// rule): its repository's name inside one, else the folder's. Looked at with the panes' foreground.
    func followFolders() {
        for workspace in workspaces {
            guard let first = workspace.tabs.lazy.flatMap(\.tree.panes).compactMap({ self.panes[$0] }).first else { continue }
            let folder = first.currentFolder
            if workspace.liveFolder != folder { workspace.liveFolder = folder }
            git.follow(workspace.id, folder: folder)
        }
    }

    /// Rename Workspace…: an empty name goes back to following its folder.
    func rename(workspace: Workspace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.customName = trimmed.isEmpty ? nil : trimmed
        scheduleSave()
    }

    // MARK: Moving tabs

    /// A tab dragged along the tab bar to a new place (`index` counts the tabs as they are before the move).
    func move(tab: Tab, toIndex index: Int) {
        guard let workspace = workspaces.first(where: { $0.tabs.contains { $0 === tab } }),
              let from = workspace.tabs.firstIndex(where: { $0 === tab }) else { return }
        let to = min(max(index > from ? index - 1 : index, 0), workspace.tabs.count - 1)
        guard to != from else { return }
        workspace.tabs.remove(at: from)
        workspace.tabs.insert(tab, at: to)
        scheduleSave()
    }

    /// Move to Workspace ▸, or a tab dropped on another blanket: it goes there, still running, and is
    /// shown there. A workspace left with no tabs goes (nothing in it stops: its only tab moved).
    func move(tab: Tab, to target: Workspace) {
        guard let source = workspaces.first(where: { $0.tabs.contains { $0 === tab } }), source !== target else { return }
        source.tabs.removeAll { $0 === tab }
        if source.tabs.isEmpty {
            removeEmpty(source)
        } else if source.selectedTabID == tab.id {
            source.selectedTabID = source.tabs.first?.id
        }
        target.tabs.append(tab)
        select(tab: tab)
        scheduleSave()
    }

    // MARK: Pins and unread

    /// Pin (as herdr has it): a pinned Claude is marked on its blanket and listed first in Go to and the palette.
    func togglePin(pane id: UUID) {
        if pinnedPanes.contains(id) { pinnedPanes.remove(id) } else { pinnedPanes.insert(id) }
        scheduleSave()
    }

    func isPinned(_ workspace: Workspace) -> Bool {
        workspace.tabs.contains { $0.tree.panes.contains(where: pinnedPanes.contains) }
    }

    /// Mark as Unread (§6.3): the turn shows as Finished again, until you have looked away and back.
    func markUnread(pane id: UUID) {
        guard let pane = panes[id], let session = session(of: pane) else { return }
        monitor.markUnread(sessionID: session.id)
        heldUnread.insert(id)
    }

    /// Whether Mark as Unread applies: a Claude whose last turn has finished and been seen.
    func canMarkUnread(pane id: UUID) -> Bool {
        guard let pane = panes[id], let session = session(of: pane) else { return false }
        return session.status == .idle
    }

    // MARK: Recent places

    /// A tab was shown: the palette's Recent section lists the last ones.
    func noteVisit(_ tab: Tab) {
        guard visitedTabs.first != tab.id else { return }
        visitedTabs.removeAll { $0 == tab.id }
        visitedTabs.insert(tab.id, at: 0)
        if visitedTabs.count > 20 { visitedTabs.removeLast() }
    }

    /// The folders the Start page and File › Open Recent offer, the same in both: opened here first,
    /// then Claude's. One open already is offered too: choosing it shows its workspace.
    var recentFolders: [RecentFolder] {
        Places.recents(opened: history, claude: claudeFolders, home: FileManager.default.homeDirectoryForCurrentUser.path, limit: 8)
    }

    /// Reads, off the main thread, the folders Claude Code has worked in lately.
    func loadClaudeFolders() {
        // A test run never reads what you have worked on: its Start page offers only its own folders.
        guard !AppPlaces.isIsolated else { return }
        let accounts = accounts
        // Those older than the last Clear Menu stay cleared.
        let cleared = Date(timeIntervalSince1970: AppPlaces.defaults.double(forKey: "recentsClearedAt"))
        Task.detached(priority: .utility) {
            let folders = Discovery.recentFolders(accounts: accounts, limit: 20).filter { $0.lastUsed > cleared }
            await MainActor.run { self.claudeFolders = folders }
        }
    }
}
