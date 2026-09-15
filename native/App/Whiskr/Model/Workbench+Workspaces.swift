import AppKit
import WhiskrKit

/// What a tab can show besides terminals. A page takes a terminal's place in its tab's tree (its id is
/// a leaf there, kept in `Workbench.pages` rather than `panes`), so everything that walks a tab's
/// terminals simply finds none, and a file can sit in a split beside terminals. Saved with the layout.
enum TabPage: Equatable {
    /// A file, in the editor or its preview (Workbench+Files.swift).
    case file(path: String)
    /// A file's changes: its unstaged ones against the index, or (`staged`) its staged ones against HEAD.
    case changes(path: String, staged: Bool)

    var title: String {
        switch self {
        case .file(let path): URL(fileURLWithPath: path).lastPathComponent
        case .changes(let path, let staged):
            staged ? String(localized: "\(URL(fileURLWithPath: path).lastPathComponent) · Staged", comment: "Tab title: a file's staged changes")
                : String(localized: "\(URL(fileURLWithPath: path).lastPathComponent) · Changes", comment: "Tab title: a file's changes")
        }
    }

    /// The file it shows, or whose changes it shows.
    var path: String {
        switch self {
        case .file(let path), .changes(let path, _): path
        }
    }

    var isDiff: Bool {
        if case .changes = self { return true }
        return false
    }
}

/// Workspaces beyond opening and closing: Home, names that follow the shell, renaming, moving tabs
/// between workspaces, pins and Mark as Unread.
extension Workbench {
    // MARK: Home

    /// Home (docs/DESIGN.md) is no workspace selected: every workspace waits on its blanket and in the
    /// Home page's Open list, still running. Go › Home, the workspace button's menu, New Workspace (⌘N),
    /// and closing the workspace on screen all come here; the Home page takes the keyboard, on New Terminal.
    /// `chosen`: false when Home comes because the workspace shown has closed.
    func goHome(chosen: Bool = true) {
        if chosen { youChose() }
        if peekedPane != nil { peekedPane = nil }
        if focusedAgent != nil { focusedAgent = nil }
        if selectedWorkspaceID != nil { selectedWorkspaceID = nil }
        homeVisits += 1
        onFocusHome?()
    }

    var isHome: Bool { selectedWorkspace == nil }

    /// An edit in the tab row (a rename) has ended and its field has gone: if it took the keyboard with it
    /// (the window itself, or the gone field's editor, has it now), the keyboard goes back to what is
    /// shown: the tab's focused terminal or file, else Home. Anywhere else (a click went there) it stays.
    func returnKeyboardIfLost(again: Bool = true) {
        // Looked at again once SwiftUI has finished taking the field away (it can let the keyboard go after).
        if again { DispatchQueue.main.async { [weak self] in self?.returnKeyboardIfLost(again: false) } }
        guard let window = files.window, window.firstResponder === window || window.firstResponder == nil
                || (window.firstResponder as? NSText).map({ $0.delegate == nil || ($0.delegate as? NSView)?.window == nil }) == true else { return }
        if let pane = focusedPane {
            onFocusPane?(pane)
        } else if let page = focusedPageID {
            files.onFocusPage?(page)
        } else if isHome {
            onFocusHome?()
        }
    }

    /// The open workspaces as the Home page lists them (`HomeList`).
    var homeRows: [HomeList.Row] {
        let rows = agentRows
        return HomeList.open(workspaces.map { workspace in
            let claudes = rows.filter { $0.workspaceID == workspace.id }.map { row in
                (status: row.status, failed: panes[row.id].flatMap(session(of:))?.failed ?? false)
            }
            return HomeList.Workspace(id: workspace.id, name: workspace.name, folder: workspace.folder, branch: workspace.branch,
                                      colorIndex: workspace.colorIndex, claudes: claudes)
        })
    }

    /// The Home page's Recent: File › Open Recent's folders, without those already under Open.
    var homeRecents: [RecentFolder] {
        HomeList.recents(recentFolders, open: workspaces.map(\.folder))
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

    /// A tab dropped on a pane (`PaneArea`): on its edge, the tab's panes go beside it on that side and the
    /// tab leaves the row; in its middle, the tab moves to that pane's tab's place in the row and shows.
    /// Nothing in it stops or restarts.
    func dropTab(_ tab: Tab, onto pane: UUID, side: PaneTree.Direction?) {
        guard let (workspace, target) = workspace(ofLeaf: pane), target !== tab, workspace.tabs.contains(where: { $0 === tab }) else { return }
        guard let side else {
            move(tab: tab, toIndex: workspace.tabs.firstIndex { $0 === target } ?? workspace.tabs.count)
            select(tab: tab)
            return
        }
        workspace.tabs.removeAll { $0 === tab }
        target.zoomedPane = nil
        target.tree = target.tree.inserting(tab.tree, beside: pane, on: side)
        target.focus(tab.focusedPane)
        workspace.selectedTabID = target.id
        select(tab: target)
        scheduleSave()
    }

    /// The tab holding a pane or a page.
    func workspace(ofLeaf id: UUID) -> (Workspace, Tab)? {
        for workspace in workspaces {
            if let tab = workspace.tabs.first(where: { $0.tree.contains(id) }) { return (workspace, tab) }
        }
        return nil
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

    /// A plain terminal of the tab rang its bell while out of sight (its tab shows a bell until seen).
    func rang(in tab: Tab) -> Bool {
        tab.tree.panes.contains { panes[$0].map { $0.rang && !$0.agentRunning } ?? false }
    }

    // MARK: Recent places

    /// A tab was shown: the palette's Recent section lists the last ones.
    func noteVisit(_ tab: Tab) {
        guard visitedTabs.first != tab.id else { return }
        visitedTabs.removeAll { $0 == tab.id }
        visitedTabs.insert(tab.id, at: 0)
        if visitedTabs.count > 20 { visitedTabs.removeLast() }
    }

    /// The folders File › Open Recent offers (and Home, less those open): opened here first, then
    /// Claude's. One open already is offered too: choosing it shows its workspace.
    var recentFolders: [RecentFolder] {
        Places.recents(opened: history, claude: claudeFolders, home: FileManager.default.homeDirectoryForCurrentUser.path, limit: 8)
    }

    /// Reads, off the main thread, the folders Claude Code has worked in lately.
    func loadClaudeFolders() {
        // A test run never reads what you have worked on: its Home offers only its own folders.
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
