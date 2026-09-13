import AppKit
import Foundation
import Observation
import TerminalHost
import WhiskrKit

/// One row of the navigator's list: the main agent of a pane with Claude in it, with its helpers.
struct AgentRow: Identifiable, Equatable {
    let id: UUID                 // the pane
    let workspaceID: UUID
    let workspaceName: String
    let name: String
    let status: AgentStatus
    let line: String
    let since: Date
    let accountIndex: Int
    let helpers: [AgentSnapshot]
}

/// A closed tab (or pane), kept alive for a moment so ⌘Z can bring it back exactly as it was, process
/// and all; then its processes end and it can still be reopened in its folder (⇧⌘T).
struct ClosedTab {
    let id = UUID()
    let workspace: WorkspacePlace
    let index: Int
    /// The tab as it was. For a closed pane, the tab it was in and its tree before.
    let tab: Tab
    let tree: PaneTree
    /// Only this pane was closed (the tab stays).
    let onlyPane: UUID?
    let panes: [Pane]
    let closedAt: Date
    /// What to reopen later: each pane's folder, and the conversation to resume where Claude ran.
    let reopen: [(folder: String, resume: String?)]
}

/// A workspace as it was when a tab of it closed: what ⌘Z needs to bring it back as it was (its last tab
/// closes it) and ⇧⌘T to find it again.
struct WorkspacePlace {
    let id: UUID
    let folder: String
    let colorIndex: Int
    let customName: String?
    /// Its place in the meadow's order.
    let index: Int
}

/// Everything the window shows and does: workspaces, tabs, panes and the agents in them. The one
/// owner of the app's state; views read it and call its methods.
///
/// Every pane is a shell. Claude in a pane is seen, however it was started: our `claude` shim (first on
/// the pane's PATH, `ShellIntegration`) runs it with this pane's hooks, and the terminal's foreground
/// program shows it at once, before its first hook event (`AgentPresence`).
@Observable
final class Workbench {
    let monitor = AgentMonitor()
    @ObservationIgnored let notifier = Notifier()

    private(set) var accounts: [ClaudeAccount] = []
    private(set) var workspaces: [Workspace] = []
    var selectedWorkspaceID: UUID?
    private(set) var panes: [UUID: Pane] = [:]
    /// The window is in front and the app is active: what is on screen counts as seen.
    var isLookingAtWindow = false {
        didSet { if isLookingAtWindow { markVisibleSeen() } }
    }
    /// The tab whose name is being edited in the tab strip.
    var renamingTabID: UUID?
    /// The listener could not start; Claude still runs in panes, but only its presence is known.
    private(set) var hooksUnavailable = false
    /// Closed tabs and panes, still running for `undoSeconds`, newest last.
    private(set) var closing: [ClosedTab] = []
    /// Tabs closed longer ago, to reopen in their folders (⇧⌘T), newest last.
    private(set) var reopenable: [ClosedTab] = []
    /// Where ⌘J came from, so it can take you back once nothing is waiting.
    private(set) var jumpedFrom: UUID?

    /// The agent last chosen in the focused pane's session: a helper's id after its cat was clicked, nil
    /// for the session's own agent. A helper has no terminal; its story shows in the pane's place.
    var focusedAgent: String?
    /// What a tab can show besides terminals (`TabPage`), by the id that holds its place in the tab's
    /// tree. A tree's leaf names a terminal in `panes` or a page here, never both. Changed only by the
    /// page methods (Workbench+Workspaces.swift).
    var pages: [UUID: TabPage] = [:]
    /// The files side: side panels, repositories, open documents (Workbench+Files.swift).
    @ObservationIgnored let files = FilesCenter()
    /// Panes whose Claude you pinned: marked in the meadow and listed first (herdr's pin).
    var pinnedPanes: Set<UUID> = []
    /// Panes you marked as unread: their Finished mark stays until you have looked away and back.
    @ObservationIgnored var heldUnread: Set<UUID> = []
    /// Places chosen in the palette and Go to, for their order ("frecency"); and the tabs visited, newest first.
    @ObservationIgnored var paletteUsage = PaletteUsage(data: AppPlaces.defaults.data(forKey: "paletteUsage"))
    @ObservationIgnored var visitedTabs: [UUID] = []
    @ObservationIgnored let git = GitWatcher()
    /// When a key was last pressed in a pane: alert sounds wait for a pause in typing.
    @ObservationIgnored var lastKeystroke: Date?

    /// The window's undo manager: Edit › Undo Close Tab (⌘Z) goes through it, as any Mac undo does.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Asks the window to give a pane's terminal the keyboard.
    @ObservationIgnored var onFocusPane: ((Pane) -> Void)?
    /// Asks the window to give the Home page the keyboard (`goHome`).
    @ObservationIgnored var onFocusHome: (() -> Void)?
    /// Counts the times Home was entered: its page starts again on New Terminal each time.
    var homeVisits = 0
    /// Claudes not resumed at this launch because another version's session host still holds terminals
    /// (they may be alive there); the launch notice says so.
    private(set) var resumesWithheld = 0
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var ticker: Timer?
    /// Folders opened here, newest first (File › Open Recent and Home).
    private(set) var history: [RecentFolder]
    /// Folders Claude Code has worked in lately, read once at launch: Home offers them too.
    var claudeFolders: [RecentFolder] = []
    /// The workspace whose name is being edited (in the tab row's workspace button).
    var renamingWorkspaceID: UUID?
    /// The session host, which owns every pane's terminal and keeps them running when the app quits.
    @ObservationIgnored let host = HostLink()
    /// A helper terminal with no tab of its own (`paw run --bg`) shown over the panes, as herdr peeks.
    var peekedPane: UUID?
    /// Text passed between terminals (`paw send`, notes, a task handed over): the meadow acts it out.
    @ObservationIgnored var onPassed: ((PassedMessage) -> Void)?
    /// Each workspace's branch against its upstream and whether files changed, read off the main thread.
    var branchChanges: [UUID: SceneSnapshot.BranchChanges] = [:]
    @ObservationIgnored let branches = BranchWatcher()
    @ObservationIgnored private let integration = ShellIntegration(folder: AppPlaces.supportFolder.appendingPathComponent("shell", isDirectory: true))

    static var supportFolder: URL { AppPlaces.supportFolder }
    static var layoutFile: URL { supportFolder.appendingPathComponent("layout.json") }
    static var hooksFolder: URL { supportFolder.appendingPathComponent("hooks", isDirectory: true) }
    /// The settings every pane's `claude` is given (`HookSettings`): one file for all of them.
    static var hooksFile: URL { hooksFolder.appendingPathComponent("settings.json") }
    /// What the Claudes were doing when the app last quit, to bring their cats back as they were.
    static var agentsFile: URL { supportFolder.appendingPathComponent("agents.json") }

    private static let historyKey = "recentFolders"
    /// How often each pane's foreground is looked at: often enough that a cat appears as Claude starts.
    static let lookInterval: TimeInterval = 0.25
    /// How long a closed tab keeps running so ⌘Z can bring it back.
    static let undoSeconds: TimeInterval = 10
    /// How long a finished pane must be on screen before it counts as seen.
    static let seenDwell: TimeInterval = 1

    init() {
        history = (AppPlaces.defaults.array(forKey: Self.historyKey) as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = entry["path"] as? String, let time = entry["time"] as? Double else { return nil }
            return RecentFolder(path: path, lastUsed: Date(timeIntervalSince1970: time))
        }
        accounts = Discovery.accounts(home: FileManager.default.homeDirectoryForCurrentUser)
        monitor.hasPane = { [weak self] paneID in UUID(uuidString: paneID).flatMap { self?.panes[$0] } != nil }
        monitor.accountName = { [weak self] configDir in self?.account(configDir: configDir).name ?? ClaudeAccount.defaultName }
        monitor.onChange = { [weak self] before, after in self?.agentsChanged(before: before, after: after) }
        git.onChange = { [weak self] id, head in
            guard let self, let workspace = self.workspaces.first(where: { $0.id == id }), workspace.git != head else { return }
            workspace.git = head
            // A worktree goes beside its repository, whichever of the two was opened first.
            for each in self.workspaces where each.git?.isWorktree == true { self.nestWorktree(each) }
            self.branches.follow(id, root: head?.root)
        }
        branches.onChange = { [weak self] id, changes in
            guard let self, self.branchChanges[id] != changes else { return }
            self.branchChanges[id] = changes
        }
        host.onStarted = { [weak self] info in self?.adoptStarted(info) }
        host.onPassed = { [weak self] message in self?.onPassed?(message) }
        notifier.onOpen = { [weak self] pane in
            NSApp.activate()
            self?.focus(pane: pane)
        }
        // Allow or Deny from the notification: answered if that request still waits, else you are taken
        // to its terminal to see what changed.
        notifier.onAnswer = { [weak self] id, allow in
            guard let self else { return }
            let request = self.openRequest(pane: id)
            if let request, let option = request.answers.first(where: { $0.role == (allow ? .allow : .deny) }),
               self.answer(request, with: option, checkScreen: false) { return }
            NSApp.activate()
            self.focus(pane: id)
        }
    }

    // MARK: Starting up and shutting down

    /// Starts the hook listener and the shell integration, finds the session host, then brings back the
    /// last layout: each pane onto its terminal if the host still holds it, else as a fresh shell. Nothing
    /// is selected: a launch always lands on Home.
    func launch() async {
        do {
            try await monitor.start()
        } catch {
            hooksUnavailable = true
        }
        prepareHooksFolder()
        do {
            // `paw` goes beside the `claude` shim, linked to the copy inside the app.
            let tools = Bundle.main.url(forAuxiliaryExecutable: HostLink.toolName).map { [HostLink.toolName: $0] } ?? [:]
            try integration.install(tools: tools)
        } catch {
            NSLog("Whiskr: could not write the shell integration: \(error)")
        }
        let running = await host.start()
        if let layout = LayoutSnapshot.read(from: Self.layoutFile) { restore(layout, running: running) }
        adopt(running)
        restoreAgents()
        removeStaleHookFiles()
        loadClaudeFolders()
        let ticker = Timer(timeInterval: Self.lookInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Panes with something running in front of their shell, Claude or otherwise.
    var busyPanes: [Pane] {
        panes.values.filter { $0.foreground != nil }
    }

    /// The app is quitting. Every terminal keeps running in the session host and is found again at the
    /// next launch, unless `stoppingSessions` (Quit and Stop All Terminals): then everything in them is
    /// asked to end, and the host with them.
    func shutDown(stoppingSessions: Bool = false) {
        saveNow()
        if stoppingSessions { try? FileManager.default.removeItem(at: Self.agentsFile) }
        ticker?.invalidate()
        monitor.stop()
        if stoppingSessions {
            host.stopAll()
            try? FileManager.default.removeItem(at: Self.hooksFolder)
        } else {
            host.disconnect()
            // Sessions that live on report to the next launch; until then their hooks do nothing.
            for pane in panes.values { try? FileManager.default.removeItem(at: hookAddressFile(for: pane.id)) }
        }
    }

    // MARK: Reading

    /// The workspace on screen; nil on Home.
    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedTab: Tab? { selectedWorkspace?.selectedTab }

    var focusedPane: Pane? { selectedTab.flatMap { panes[$0.focusedPane] } }

    func workspace(of paneID: UUID) -> (Workspace, Tab)? {
        for workspace in workspaces {
            if let tab = workspace.tabs.first(where: { $0.tree.contains(paneID) }) { return (workspace, tab) }
        }
        return nil
    }

    func account(configDir: String?) -> ClaudeAccount {
        if let configDir, let known = accounts.first(where: { $0.configDir == configDir }) { return known }
        if configDir == nil, let main = accounts.first(where: \.isDefault) { return main }
        let name = configDir.map { URL(fileURLWithPath: $0).lastPathComponent.replacingOccurrences(of: ".claude-", with: "") } ?? ClaudeAccount.defaultName
        return ClaudeAccount(name: name == ".claude" ? ClaudeAccount.defaultName : name, configDir: configDir ?? "", email: nil)
    }

    func accountIndex(configDir: String?) -> Int {
        accounts.firstIndex { $0.configDir == configDir } ?? accounts.firstIndex { configDir == nil && $0.isDefault } ?? 0
    }

    /// The Claude session a pane is showing, if one has reported from it and not ended.
    func session(of pane: Pane) -> SessionSnapshot? {
        guard pane.agentRunning else { return nil }
        return monitor.session(forPane: pane.id)
    }

    /// The herdr state of a pane: nil while no Claude is in it (a shell, a dev server: a lantern);
    /// "unknown" while Claude runs but has not reported (just started, or running without our hooks).
    func status(of pane: Pane) -> AgentStatus? {
        guard pane.agentRunning else { return nil }
        return session(of: pane)?.status ?? .unknown
    }

    /// A pane's title, as herdr and Terminal title one: the agent's session title when known, else
    /// the program in front ("Claude Code", "vim", "npm"), else the folder the shell is in.
    func name(of pane: Pane) -> String {
        if pane.agentRunning {
            if let title = session(of: pane)?.title, !title.isEmpty { return title }
            // A resumed conversation, before it has reported: the name it had.
            if let title = pane.sessionTitle, !title.isEmpty { return title }
            return String(localized: "Claude Code", comment: "A pane's title while Claude Code runs in it and its chat has no name yet")
        }
        if let program = pane.programName { return program }
        return folderName(pane.currentFolder)
    }

    /// A tab's title: the name you gave it, else its agent's (or its focused pane's) title.
    func title(of tab: Tab) -> String {
        if let name = tab.name, !name.isEmpty { return name }
        let ids = tab.tree.panes
        if let page = pages[tab.focusedPane] { return page.title }
        if let agent = ids.compactMap({ panes[$0] }).first(where: \.agentRunning) { return name(of: agent) }
        return panes[tab.focusedPane].map(name(of:)) ?? String(localized: "Terminal")
    }

    func folderName(_ path: String) -> String {
        path == FileManager.default.homeDirectoryForCurrentUser.path ? "~" : (URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: path).lastPathComponent)
    }

    /// The most urgent state among a set of panes, as herdr rolls a tab or space up.
    func status(ofPanes ids: [UUID]) -> AgentStatus? {
        ids.compactMap { panes[$0].flatMap(status(of:)) }.min()
    }

    /// A tab's state, with the helpers its Claudes started that have no tab of their own (a helper's
    /// request rolls up into its boss's tab).
    func status(of tab: Tab) -> AgentStatus? {
        let helpers = panes.values.filter { isLooseHelper($0) && boss(of: $0).flatMap(workspaceOfBoss)?.1 === tab }
        return status(ofPanes: tab.tree.panes + helpers.map(\.id))
    }

    func status(of workspace: Workspace) -> AgentStatus? { status(ofPanes: workspace.tabs.flatMap(\.tree.panes) + looseHelpers(in: workspace).map(\.id)) }

    /// Every pane with Claude in it, as a row: those in tabs, and helper terminals with no tab of their
    /// own (`paw run --bg`), with the workspace of the Claude that started them.
    var agentRows: [AgentRow] {
        workspaces.flatMap { workspace in
            (workspace.tabs.flatMap(\.tree.panes) + looseHelpers(in: workspace).map(\.id)).compactMap { id -> AgentRow? in
                guard let pane = panes[id], let status = status(of: pane) else { return nil }
                let session = session(of: pane)
                return AgentRow(
                    id: id, workspaceID: workspace.id, workspaceName: workspace.name, name: name(of: pane), status: status,
                    line: session?.main.line ?? "",
                    since: session?.statusSince ?? Date.distantPast,
                    accountIndex: accountIndex(configDir: pane.sessionConfigDir),
                    helpers: Array((session?.agents.familyOrder ?? []).dropFirst()))
            }
        }
    }

    var needsYouCount: Int { agentRows.filter { $0.status == .blocked }.count }

    // MARK: Starting things

    /// A new tab with a shell (⌘T, "+", a double-click on the tab strip), in the focused pane's folder,
    /// as herdr's "follow" does (else the workspace's). On Home, a workspace in your home folder.
    @discardableResult
    func newTab() -> Pane {
        guard let workspace = selectedWorkspace else { return newWorkspace() }
        let pane = makePane(folder: newTerminalFolder(workspace: workspace))
        addTab(with: pane, to: workspace)
        focus(pane: pane.id)
        scheduleSave()
        return pane
    }

    /// A new workspace with a shell (Home's New Terminal): in your home folder unless a folder is given
    /// (⌘O, a dropped folder, Open Recent). Nothing else starts: you type `claude` yourself.
    @discardableResult
    func newWorkspace(folder: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Pane {
        remember(folder: folder)
        let pane = makePane(folder: folder)
        addTab(with: pane, to: addWorkspace(folder: folder))
        focus(pane: pane.id)
        scheduleSave()
        return pane
    }

    /// Where a new tab or split opens (Settings › General): the focused pane's folder, or home.
    private func newTerminalFolder(workspace: Workspace) -> String {
        switch Preferences.shared.newTerminalFolder {
        case .current: focusedPane?.currentFolder ?? workspace.folder
        case .home: FileManager.default.homeDirectoryForCurrentUser.path
        }
    }

    /// Opens a folder: selects its workspace when one is open for it, else makes one.
    func open(folder: String) {
        if let open = workspaces.first(where: { $0.folder == folder }) {
            remember(folder: folder)
            select(workspace: open)
        } else {
            newWorkspace(folder: folder)
        }
    }

    /// Splits the focused pane, with a shell in its folder.
    func split(_ axis: PaneTree.Axis) {
        guard let focused = focusedPane, let (workspace, _) = workspace(of: focused.id) else { return }
        let pane = makePane(folder: newTerminalFolder(workspace: workspace))
        insert(pane, besides: focused.id, axis: axis)
        focus(pane: pane.id)
        scheduleSave()
    }

    // MARK: Closing

    /// ⌘W: the focused pane goes; the last pane closes its tab, the last tab its workspace. Nothing is
    /// asked and nothing is waited for: the pane keeps running in the host for `undoSeconds`, where ⌘Z
    /// finds it again, and the host ends its programs when that moment has passed.
    func close(pane id: UUID) {
        guard let (workspace, tab) = workspace(of: id), let pane = panes[id] else { return }
        guard tab.tree.panes.count > 1 else { return close(tab: tab) }
        let before = tab.tree
        guard tab.remove(id) else { return }
        panes[id] = nil
        keepClosed(ClosedTab(workspace: place(of: workspace), index: workspace.tabs.firstIndex { $0 === tab } ?? 0,
                             tab: tab, tree: before, onlyPane: id, panes: [pane], closedAt: Date(), reopen: [reopenInfo(pane)]))
        if workspace.selectedTab === tab { focus(pane: tab.focusedPane) }
        scheduleSave()
    }

    /// ⌥⌘W: the tab goes, undoable the same way. The last tab of a workspace closes the workspace, and
    /// Home comes (never another workspace's terminal).
    func close(tab: Tab) {
        guard let workspace = workspaces.first(where: { $0.tabs.contains { $0 === tab } }) else { return }
        let closed = tab.tree.panes.compactMap { panes[$0] }
        let index = workspace.tabs.firstIndex { $0 === tab } ?? 0
        for pane in closed { panes[pane.id] = nil }
        keepClosed(ClosedTab(workspace: place(of: workspace), index: index, tab: tab, tree: tab.tree, onlyPane: nil,
                             panes: closed, closedAt: Date(), reopen: closed.map(reopenInfo)))
        remove(tab: tab, from: workspace)
        scheduleSave()
    }

    private func place(of workspace: Workspace) -> WorkspacePlace {
        WorkspacePlace(id: workspace.id, folder: workspace.folder, colorIndex: workspace.colorIndex, customName: workspace.customName,
                       index: workspaces.firstIndex { $0 === workspace } ?? workspaces.count)
    }

    /// The workspace a closed tab belongs in: still open, or brought back as it was (colour, name, place).
    private func workspace(for place: WorkspacePlace) -> Workspace {
        if let open = workspaces.first(where: { $0.id == place.id }) { return open }
        let workspace = Workspace(id: place.id, folder: place.folder, tabs: [], colorIndex: place.colorIndex, customName: place.customName)
        workspaces.insert(workspace, at: min(place.index, workspaces.count))
        git.follow(workspace.id, folder: workspace.folder)
        return workspace
    }

    private func reopenInfo(_ pane: Pane) -> (folder: String, resume: String?) {
        let resume = pane.agentRunning ? pane.sessionID.flatMap { ClaudeResume.resumeCommand(sessionID: $0, account: pane.sessionConfigDir.map { account(configDir: $0) }) } : nil
        return (pane.currentFolder, resume)
    }

    private func keepClosed(_ closed: ClosedTab) {
        for pane in closed.panes {
            notifier.withdraw(pane: pane.id)
            pane.onExit = nil
            // The host ends it by itself, a moment after the undo has gone, even if the app quits first.
            pane.end(after: Self.undoSeconds + 1)
        }
        closing.append(closed)
        registerUndo(closed)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds) { [weak self] in self?.expire(closed.id) }
    }

    private func registerUndo(_ closed: ClosedTab) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { $0.undoClose(id: closed.id) }
        undoManager.setActionName(closed.onlyPane == nil ? String(localized: "Close Tab") : String(localized: "Close Pane"))
    }

    /// The moment for ⌘Z has passed: its processes end; it can still be reopened in its folder.
    private func expire(_ id: UUID) {
        guard let index = closing.firstIndex(where: { $0.id == id }) else { return }
        let closed = closing.remove(at: index)
        for pane in closed.panes {
            pane.end()
            pane.disconnect()
            removeHookFiles(for: pane.id)
        }
        reopenable.append(closed)
        if reopenable.count > 10 { reopenable.removeFirst(reopenable.count - 10) }
        // What can no longer be undone leaves the Edit menu; the rest stays, in order.
        undoManager?.removeAllActions(withTarget: self)
        for still in closing { registerUndo(still) }
        // Its pages (files, diffs) and their documents go with it.
        prunePages()
    }

    /// "Closed · Undo ⌘Z": the same as Edit › Undo.
    func undoClose() {
        if let undoManager, undoManager.canUndo, closing.last != nil { undoManager.undo() } else if let last = closing.last { undoClose(id: last.id) }
    }

    /// Edit › Undo Close Tab (⌘Z): a closed tab or pane comes back exactly as it was, process and all, and
    /// is shown; a workspace its closing closed comes back with it.
    private func undoClose(id: UUID) {
        guard let index = closing.firstIndex(where: { $0.id == id }) else { return }
        let closed = closing.remove(at: index)
        for pane in closed.panes {
            panes[pane.id] = pane
            pane.keepRunning()
            pane.onExit = { [weak self] pane in self?.paneExited(pane) }
        }
        let workspace = workspace(for: closed.workspace)
        if let pane = closed.onlyPane, workspace.tabs.contains(where: { $0 === closed.tab }) {
            closed.tab.tree = closed.tree
            closed.tab.focus(pane)
            focus(pane: pane)
        } else {
            if closed.onlyPane != nil { closed.tab.tree = closed.tree }
            workspace.tabs.insert(closed.tab, at: min(closed.index, workspace.tabs.count))
            select(tab: closed.tab)
        }
        scheduleSave()
    }

    var canUndoClose: Bool { !closing.isEmpty }
    var canReopenClosedTab: Bool { !reopenable.isEmpty }

    /// File › Reopen Closed Tab (⇧⌘T): a tab closed longer ago comes back in its folder, resuming the
    /// conversation where Claude ran.
    func reopenClosedTab() {
        guard let closed = reopenable.popLast(), let first = closed.reopen.first else { return }
        let workspace = workspace(for: closed.workspace)
        let pane = makePane(folder: first.folder)
        if let resume = first.resume { pane.typeWhenReady(resume + "\r") }
        addTab(with: pane, to: workspace)
        focus(pane: pane.id)
        scheduleSave()
    }

    /// Whether closing this workspace stops something that is not an idle shell (then it asks).
    func isBusy(_ workspace: Workspace) -> Bool {
        workspace.tabs.flatMap(\.tree.panes).compactMap { panes[$0] }.contains { $0.foreground != nil }
    }

    /// Closes a workspace and ends what runs in it. The one on screen gives way to Home.
    func close(workspace: Workspace) {
        for id in workspace.tabs.flatMap(\.tree.panes) { discard(pane: id) }
        git.stop(workspace.id)
        branches.stop(workspace.id)
        branchChanges[workspace.id] = nil
        workspaces.removeAll { $0 === workspace }
        if HomeRules.selection(afterClosing: workspace.id, selected: selectedWorkspaceID) != selectedWorkspaceID { goHome() }
        // A workspace closed as a whole has no undo: its pages go now (a tab of it still in its ⌘Z moment keeps its own).
        prunePages()
        scheduleSave()
    }

    func discard(pane id: UUID) {
        panes[id]?.end()
        letGo(pane: id)
    }

    /// Stops showing a pane without ending its terminal (the host keeps or ends it as it was told).
    func letGo(pane id: UUID) {
        panes[id]?.onExit = nil
        panes[id]?.disconnect()
        panes[id] = nil
        notifier.withdraw(pane: id)
        removeHookFiles(for: id)
    }

    private func remove(tab: Tab, from workspace: Workspace) {
        let index = workspace.tabs.firstIndex { $0 === tab } ?? 0
        workspace.tabs.removeAll { $0 === tab }
        if workspace.tabs.isEmpty {
            close(workspace: workspace)
            return
        }
        if workspace.selectedTabID == tab.id {
            workspace.selectedTabID = workspace.tabs[min(index, workspace.tabs.count - 1)].id
        }
        if selectedWorkspace === workspace, let next = workspace.selectedTab { focus(pane: next.focusedPane) }
    }

    // MARK: Moving around

    /// Shows a pane and gives it the keyboard: its workspace and tab are selected, and a zoom on
    /// another pane is undone. Only ever called for something you did; no agent event moves focus.
    func focus(pane id: UUID, agent: String? = nil) {
        if let helper = panes[id], isLooseHelper(helper) { return peek(id) }
        guard let (workspace, tab) = workspace(of: id), let pane = panes[id] else { return }
        if peekedPane != nil { peekedPane = nil }
        if selectedWorkspaceID != workspace.id { selectedWorkspaceID = workspace.id }
        if workspace.selectedTabID != tab.id { workspace.selectedTabID = tab.id }
        if let zoomed = tab.zoomedPane, zoomed != id { tab.zoomedPane = nil }
        tab.focus(id)
        if focusedAgent != agent { focusedAgent = agent }
        noteVisit(tab)
        onFocusPane?(pane)
        markVisibleSeen()
    }

    /// The window says this pane's terminal took the keyboard (a click, say).
    func terminalTookFocus(_ id: UUID) {
        guard let (workspace, tab) = workspace(of: id) else { return }
        if selectedWorkspaceID != workspace.id { selectedWorkspaceID = workspace.id }
        if workspace.selectedTabID != tab.id { workspace.selectedTabID = tab.id }
        if focusedAgent != nil { focusedAgent = nil }
        tab.focus(id)
        markVisibleSeen()
    }

    /// Go › Next Pane / Previous Pane (⌘] / ⌘[): through the tab's panes in order.
    func focusPane(offset: Int) {
        guard let tab = selectedTab, tab.zoomedPane == nil, tab.tree.panes.count > 1,
              let index = tab.tree.panes.firstIndex(of: tab.focusedPane) else { return }
        let ids = tab.tree.panes
        focus(pane: ids[(index + offset + ids.count) % ids.count])
    }

    func moveFocus(_ direction: PaneTree.Direction) {
        guard let tab = selectedTab, tab.zoomedPane == nil,
              let next = tab.tree.neighbor(of: tab.focusedPane, toward: direction, recency: tab.recency) else { return }
        focus(pane: next)
    }

    func swapFocused(_ direction: PaneTree.Direction) {
        guard let tab = selectedTab, tab.zoomedPane == nil,
              let other = tab.tree.neighbor(of: tab.focusedPane, toward: direction, recency: tab.recency) else { return }
        tab.tree = tab.tree.swapping(tab.focusedPane, other)
        if let pane = panes[tab.focusedPane] { onFocusPane?(pane) }
        scheduleSave()
    }

    func toggleZoom() {
        guard let tab = selectedTab, tab.tree.panes.count > 1 else { return }
        tab.zoomedPane = tab.zoomedPane == nil ? tab.focusedPane : nil
        if let pane = panes[tab.focusedPane] { onFocusPane?(pane) }
        scheduleSave()
    }

    func select(tab: Tab) {
        guard let workspace = workspaces.first(where: { $0.tabs.contains { $0 === tab } }) else { return }
        selectedWorkspaceID = workspace.id
        workspace.selectedTabID = tab.id
        noteVisit(tab)
        focus(pane: tab.focusedPane)
    }

    func selectTab(at index: Int) {
        guard let workspace = selectedWorkspace, workspace.tabs.indices.contains(index) else { return }
        select(tab: workspace.tabs[index])
    }

    func selectTab(offset: Int) {
        guard let workspace = selectedWorkspace, let tab = workspace.selectedTab,
              let index = workspace.tabs.firstIndex(where: { $0 === tab }), workspace.tabs.count > 1 else { return }
        select(tab: workspace.tabs[(index + offset + workspace.tabs.count) % workspace.tabs.count])
    }

    func select(workspace: Workspace) {
        selectedWorkspaceID = workspace.id
        if let tab = workspace.selectedTab { focus(pane: tab.focusedPane) }
    }

    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        select(workspace: workspaces[index])
    }

    /// Go › Next / Previous Workspace: in the meadow's order; from Home, the first or the last.
    func selectWorkspace(offset: Int) {
        guard !workspaces.isEmpty else { return }
        guard let current = selectedWorkspace, let index = workspaces.firstIndex(where: { $0 === current }) else {
            return select(workspace: offset > 0 ? workspaces[0] : workspaces[workspaces.count - 1])
        }
        guard workspaces.count > 1 else { return }
        select(workspace: workspaces[(index + offset + workspaces.count) % workspaces.count])
    }

    /// The agents in herdr's order: needs you, done, working, idle.
    var agentOrder: [UUID] { AgentOrder.sorted(agentRows).map(\.id) }

    func focusAgent(offset: Int) {
        let order = agentOrder
        guard !order.isEmpty else { return }
        let current = focusedPane.flatMap { order.firstIndex(of: $0.id) }
        let next = current.map { ($0 + offset + order.count) % order.count } ?? (offset > 0 ? 0 : order.count - 1)
        focus(pane: order[next])
    }

    /// What ⌘J does next: the oldest request or error, else the oldest finished pane, else back to
    /// where the first jump started.
    enum NextThing: Equatable {
        case request(UUID), finished(UUID), back(UUID), nothing
    }

    var nextThing: NextThing {
        let rows = agentRows
        let waiting = rows.filter { $0.status == .blocked }.sorted { $0.since < $1.since }
        if let row = waiting.first(where: { $0.id != focusedPane?.id }) ?? waiting.first { return .request(row.id) }
        let finished = rows.filter { $0.status == .done && $0.id != focusedPane?.id }.sorted { $0.since < $1.since }
        if let row = finished.first { return .finished(row.id) }
        if let home = jumpedFrom, panes[home] != nil, home != focusedPane?.id { return .back(home) }
        return .nothing
    }

    /// Go › Next Request (⌘J).
    func goToNextThing() {
        switch nextThing {
        case .request(let id), .finished(let id):
            if jumpedFrom == nil { jumpedFrom = focusedPane?.id }
            focus(pane: id)
        case .back(let id):
            jumpedFrom = nil
            focus(pane: id)
        case .nothing:
            jumpedFrom = nil
        }
    }

    func rename(tab: Tab, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.name = trimmed.isEmpty ? nil : trimmed
        scheduleSave()
    }

    // MARK: Agents

    private func agentsChanged(before: [SessionSnapshot], after: [SessionSnapshot]) {
        let previous = Dictionary(before.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last })
        var layoutChanged = false
        for session in after where !session.ended {
            guard let paneID = session.paneID.flatMap(UUID.init(uuidString:)), let pane = panes[paneID] else { continue }
            // A hook event: Claude is in this pane (the next look at the foreground confirms it).
            pane.heardFromAgent()
            let configDir = monitor.configDir(sessionID: session.id)
            if pane.sessionID != session.id || (pane.sessionTitle ?? "") != session.title || pane.sessionConfigDir != configDir {
                pane.sessionID = session.id
                pane.sessionTitle = session.title.isEmpty ? nil : session.title
                pane.sessionConfigDir = configDir
                layoutChanged = true
            }
            guard previous[session.id] != session.status else { continue }
            // An answered request leaves Notification Center at once (§13.8).
            if previous[session.id] == .blocked { notifier.withdraw(pane: paneID) }
            if session.status == .done, isVisible(paneID) { monitor.markSeen(sessionID: session.id) }
            announce(session, pane: pane)
        }
        NSApp.dockTile.badgeLabel = needsYouCount > 0 && Preferences.shared.dockBadge ? "\(needsYouCount)" : nil
        if layoutChanged { scheduleSave() }
    }

    /// News about a Claude (`AlertCenter`): a sound while you are here and not typing in that very pane,
    /// a notification while you are in another app, saying where and what. The meadow and the tab's
    /// mark show it either way, and nothing moves.
    private func announce(_ session: SessionSnapshot, pane: Pane) {
        guard let (workspace, tab) = workspace(of: pane.id) else { return }
        let focusedHere = isLookingAtWindow && focusedPane?.id == pane.id || (session.status == .done && isVisible(pane.id))
        let place = "\(workspace.name) · \(title(of: tab))"
        AlertCenter.shared.changed(session, place: place, focusedHere: focusedHere) { [weak self] title, body, isRequest in
            guard isRequest else { return self?.notifier.post(title: title, body: body, pane: pane.id, sound: false, request: false) ?? () }
            // A request is announced only if it is still waiting two seconds later (it may have been answered).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, let pane = self.panes[pane.id], self.status(of: pane) == .blocked else { return }
                self.notifier.post(title: title, body: body, pane: pane.id, sound: true, request: self.session(of: pane)?.failed == false)
            }
        }
    }

    /// A pane is seen while its tab is on screen in the front window (herdr's rule).
    func isVisible(_ id: UUID) -> Bool {
        if isLookingAtWindow, peekedPane == id { return true }
        guard isLookingAtWindow, peekedPane == nil, let tab = selectedTab, tab.tree.contains(id) else { return false }
        if let zoomed = tab.zoomedPane { return zoomed == id }
        return true
    }

    /// When each pane came on screen, for the one-second dwell before Finished counts as seen.
    @ObservationIgnored private var visibleSince: [UUID: Date] = [:]

    /// Finished clears once its pane has been on screen in the key window for a second (not on hover,
    /// not on a glance); an error once it has been seen the same way. A pane you marked as unread keeps
    /// its mark until you have looked away from it and back.
    private func markVisibleSeen() {
        let now = Date()
        let shown = Set(((selectedTab?.tree.panes ?? []) + (peekedPane.map { [$0] } ?? [])).filter(isVisible))
        heldUnread = heldUnread.intersection(shown)
        visibleSince = visibleSince.filter { shown.contains($0.key) }
        for id in shown where visibleSince[id] == nil { visibleSince[id] = now }
        for id in shown where now.timeIntervalSince(visibleSince[id] ?? now) >= Self.seenDwell && !heldUnread.contains(id) {
            guard let pane = panes[id], let session = session(of: pane) else { continue }
            if session.status == .done || session.failed {
                monitor.markSeen(sessionID: session.id)
                notifier.withdraw(pane: id)
            }
        }
    }

    private var tickCount = 0

    /// Takes in what is in a pane's foreground: on every tick, and at once when the host says it changed.
    private func look(at pane: Pane) {
        let live = monitor.session(forPane: pane.id) != nil
        guard pane.refresh(liveSession: live), !pane.agentRunning else { return }
        // Claude has gone (exited, or killed without a word): its session is over for this pane, and
        // the next `claude` here starts afresh.
        if let session = monitor.session(forPane: pane.id) { monitor.paneLeft(paneID: pane.id, sessionID: session.id) }
        pane.sessionID = nil
        pane.sessionTitle = nil
        pane.sessionConfigDir = nil
        scheduleSave()
    }

    private func tick() {
        for pane in panes.values { look(at: pane) }
        tickCount += 1
        followFolders()
        markVisibleSeen()
        // The detail (helpers' stories, to-do lists) is kept for the sessions in the tab on screen.
        monitor.watch(Set((selectedTab?.tree.panes ?? []).compactMap { panes[$0].flatMap(session(of:))?.id }))
    }

    // MARK: Building

    func makePane(id: UUID = UUID(), folder: String) -> Pane {
        let pane = pane(id: id, folder: folder)
        pane.start(spec(folder: folder, paneID: pane.id), on: host)
        return pane
    }

    /// A pane for a terminal the host holds: from before the app was relaunched, or one a program started.
    func attachPane(to terminal: TerminalInfo, folder: String) -> Pane {
        let pane = pane(id: terminal.id, folder: terminal.status.folder ?? folder)
        // Its Claude, started before this launch, reports to this launch's listener.
        writeHookAddress(for: terminal.id)
        pane.attach(to: terminal, on: host)
        return pane
    }

    private func pane(id: UUID, folder: String) -> Pane {
        let pane = Pane(id: id, folder: folder)
        pane.hostAnswersProbes = host.speaksAgents
        pane.onExit = { [weak self] pane in self?.paneExited(pane) }
        pane.onProgramIdle = { [weak self] pane in self?.monitor.programIdle(paneID: pane.id) }
        pane.onForegroundChange = { [weak self] pane in
            guard let self, self.panes[pane.id] === pane else { return }
            self.look(at: pane)
        }
        panes[pane.id] = pane
        return pane
    }

    /// A shell that ends normally (you typed `exit`) closes its pane, as in Terminal; one that fails
    /// stays open so you can read why.
    private func paneExited(_ pane: Pane) {
        // A helper with no tab goes with its program (its cat trots back to report, then leaves).
        if isLooseHelper(pane) { return discardHelper(pane.id) }
        if pane.exitCode == 0 { close(pane: pane.id) }
    }

    /// The user's login shell, in our terminal's environment, with the shell integration that makes any
    /// `claude` typed in it report to this pane.
    private func spec(folder: String, paneID: UUID) -> ProcessSpec {
        let shell = Self.userShell
        let base = Launch.environment(
            base: ProcessInfo.processInfo.environment, shell: shell,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            localeIdentifier: Locale.current.identifier,
            localeExists: { FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)") })
        let environment = integration.environment(base, shell: shell, paneID: paneID.uuidString, hooksFile: writeHooksFile(for: paneID),
                                                  worktrees: Preferences.shared.worktreeFolder.path)
        return Launch.shell(shell, directory: folder, environment: environment)
    }

    /// The user's login shell, from the user database (the app's own environment may not say).
    static let userShell: String = {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, let path = String(validatingCString: shell), !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/zsh"
    }()

    /// The settings file of a pane started before panes shared one (kept while its Claude may still use it).
    private func hooksFile(for paneID: UUID) -> URL {
        Self.hooksFolder.appendingPathComponent("\(paneID.uuidString).json")
    }

    /// Where a pane's hooks find the app's listener (`HookSettings.command`).
    private func hookAddressFile(for paneID: UUID) -> URL {
        Self.hooksFolder.appendingPathComponent("\(paneID.uuidString).url")
    }

    /// The settings our `claude` shim passes to Claude Code in this pane: hooks posting to the app's
    /// listener, whose address (with the secret) they read from the pane's file beside them, readable only
    /// by you; and the one line that tells Claude about `paw`. nil when the listener is not running. Every
    /// pane shares the settings (the hooks find the pane's address by its id), so a terminal a program
    /// starts reports too; the address is written afresh by every launch and removed when the app quits,
    /// so a session started under one launch reports to the next.
    private func writeHooksFile(for paneID: UUID) -> String? {
        guard writeHookAddress(for: paneID) else { return nil }
        let file = Self.hooksFile
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: HookSettings.document(addressFolder: Self.hooksFolder.path),
                                                 attributes: [.posixPermissions: 0o600]) else { return nil }
        }
        return file.path
    }

    @discardableResult
    private func writeHookAddress(for paneID: UUID) -> Bool {
        guard let gate = monitor.gate else { return false }
        return FileManager.default.createFile(atPath: hookAddressFile(for: paneID).path, contents: Data(gate.url(paneID: paneID.uuidString).absoluteString.utf8),
                                              attributes: [.posixPermissions: 0o600])
    }

    private func removeHookFiles(for paneID: UUID) {
        try? FileManager.default.removeItem(at: hooksFile(for: paneID))
        try? FileManager.default.removeItem(at: hookAddressFile(for: paneID))
    }

    /// A private folder for the settings files, with this build's settings in it.
    private func prepareHooksFolder() {
        try? FileManager.default.createDirectory(at: Self.hooksFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.hooksFolder.path)
        FileManager.default.createFile(atPath: Self.hooksFile.path, contents: HookSettings.document(addressFolder: Self.hooksFolder.path),
                                       attributes: [.posixPermissions: 0o600])
    }

    /// After the layout is back: files of panes that no longer exist go (their terminals ended while
    /// the app was not running).
    private func removeStaleHookFiles() {
        for file in (try? FileManager.default.contentsOfDirectory(at: Self.hooksFolder, includingPropertiesForKeys: nil)) ?? [] {
            if file == Self.hooksFile { continue }
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), panes[id] != nil { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    @discardableResult
    func addWorkspace(folder: String) -> Workspace {
        let workspace = Workspace(folder: folder, tabs: [], colorIndex: LayoutSnapshot.Workspace.nextColor(after: workspaces.map(\.colorIndex)))
        workspaces.append(workspace)
        git.follow(workspace.id, folder: folder)
        return workspace
    }

    /// Moves a workspace to another place in the order (a worktree beside its repository).
    func move(workspace: Workspace, to index: Int) {
        guard let from = workspaces.firstIndex(where: { $0 === workspace }) else { return }
        workspaces.remove(at: from)
        workspaces.insert(workspace, at: min(max(index, 0), workspaces.count))
    }

    /// Takes out a workspace with no terminal left in it (its tabs moved away); nothing is stopped.
    func removeEmpty(_ workspace: Workspace) {
        guard workspace.tabs.allSatisfy({ $0.tree.panes.allSatisfy { panes[$0] == nil } }) else { return }
        workspaces.removeAll { $0 === workspace }
        git.stop(workspace.id)
        branches.stop(workspace.id)
        selectedWorkspaceID = HomeRules.selection(afterClosing: workspace.id, selected: selectedWorkspaceID)
    }

    func addTab(with pane: Pane, to workspace: Workspace) {
        let tab = Tab(tree: .pane(pane.id))
        let after = workspace.selectedTab.flatMap { current in workspace.tabs.firstIndex { $0 === current } }
        workspace.tabs.insert(tab, at: after.map { $0 + 1 } ?? workspace.tabs.count)
        workspace.selectedTabID = tab.id
        selectedWorkspaceID = workspace.id
    }

    private func insert(_ pane: Pane, besides other: UUID, axis: PaneTree.Axis) {
        guard let (_, tab) = workspace(of: other) else { return }
        tab.zoomedPane = nil
        tab.tree = tab.tree.splitting(other, axis: axis, new: pane.id)
        tab.focus(pane.id)
    }

    func remember(folder: String) {
        history = Discovery.merge(history, [RecentFolder(path: folder, lastUsed: Date())], limit: 30)
        AppPlaces.defaults.set(history.map { ["path": $0.path, "time": $0.lastUsed.timeIntervalSince1970] }, forKey: Self.historyKey)
        if !AppPlaces.isIsolated { NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: folder, isDirectory: true)) }
    }

    /// A recent folder that has gone: it leaves the lists.
    func forget(folder: String) {
        history.removeAll { $0.path == folder }
        claudeFolders.removeAll { $0.path == folder }
        AppPlaces.defaults.set(history.map { ["path": $0.path, "time": $0.lastUsed.timeIntervalSince1970] }, forKey: Self.historyKey)
    }

    /// File › Open Recent › Clear Menu: Home's Recent empties too.
    func clearRecentFolders() {
        claudeFolders = []
        AppPlaces.defaults.set(Date().timeIntervalSince1970, forKey: "recentsClearedAt")
        history = []
        AppPlaces.defaults.removeObject(forKey: Self.historyKey)
        if !AppPlaces.isIsolated { NSDocumentController.shared.clearRecentDocuments(nil) }
    }

    // MARK: Saving

    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func saveNow() {
        saveScheduled = false
        try? snapshot().write(to: Self.layoutFile)
        saveAgents()
    }

    func snapshot() -> LayoutSnapshot {
        // Which workspace is on screen is not kept: a launch lands on Home.
        LayoutSnapshot(workspaces: workspaces.compactMap { workspace -> LayoutSnapshot.Workspace? in
            let kept = workspace.tabs.filter { tab in tab.tree.panes.contains { panes[$0] != nil || pages[$0] != nil } }
            guard !kept.isEmpty else { return nil }
            return LayoutSnapshot.Workspace(id: workspace.id, folder: workspace.folder, tabs: kept.map { tab in
                LayoutSnapshot.Tab(id: tab.id, name: tab.name, tree: tab.tree, panes: tab.tree.panes.compactMap { id in
                    guard let pane = panes[id] else { return nil }
                    // Claude in it now, with a session to resume: it comes back resuming that session.
                    let claude = pane.agentRunning && pane.sessionID != nil
                    return LayoutSnapshot.Pane(id: id, folder: pane.currentFolder, isClaude: claude, accountConfigDir: claude ? pane.sessionConfigDir : nil,
                                               claudeSessionID: claude ? pane.sessionID : nil, claudeSessionTitle: claude ? pane.sessionTitle : nil,
                                               pinned: pinnedPanes.contains(id) ? true : nil)
                }, focusedPane: tab.focusedPane, zoomedPane: tab.zoomedPane, pages: savedPages(of: tab))
            }, selectedTab: kept.contains { $0.id == workspace.selectedTabID } ? workspace.selectedTabID : kept.first?.id,
               color: workspace.colorIndex, name: workspace.customName, panel: files.panels[workspace.id])
        })
    }

    /// Rebuilds the saved layout (`ResumePlan`). A pane whose terminal the host still holds (the app was
    /// quit, not the Mac restarted) is put back onto it, programs, screen and scrollback as they were, and
    /// nothing is typed. Any other is a fresh shell in its folder; one that was running Claude types
    /// `claude --resume <id>` (for the account it ran under), which loads the conversation and waits for
    /// you, unless another version's host still holds terminals, where that Claude may be alive. Nothing
    /// is selected: the workspaces wait on Home.
    private func restore(_ layout: LayoutSnapshot, running: [TerminalInfo]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let held = Dictionary(running.filter { !$0.closing }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let otherHosts = host.strangers > 0
        for saved in layout.workspaces {
            let tabs = saved.tabs.map { savedTab -> Tab in
                for savedPane in savedTab.panes {
                    let folder = (try? Discovery.validateFolder(savedPane.folder, home: home).get()) ?? home.path
                    if savedPane.pinned == true { pinnedPanes.insert(savedPane.id) }
                    if let terminal = held[savedPane.id] {
                        let pane = attachPane(to: terminal, folder: folder)
                        if savedPane.isClaude {
                            pane.sessionID = savedPane.claudeSessionID
                            pane.sessionTitle = savedPane.claudeSessionTitle
                            pane.sessionConfigDir = savedPane.accountConfigDir
                        }
                        continue
                    }
                    let pane = makePane(id: savedPane.id, folder: folder)
                    let command = savedPane.isClaude ? savedPane.claudeSessionID.flatMap {
                        ClaudeResume.resumeCommand(sessionID: $0, account: savedPane.accountConfigDir.map { account(configDir: $0) })
                    } : nil
                    switch ResumePlan.action(held: false, claudeSession: command != nil, resumeEnabled: Preferences.shared.resumeClaude, otherHosts: otherHosts) {
                    case .resume:
                        pane.sessionID = savedPane.claudeSessionID
                        pane.sessionTitle = savedPane.claudeSessionTitle
                        pane.sessionConfigDir = savedPane.accountConfigDir
                        if let command { pane.typeWhenReady(command + "\r") }
                    case .freshShell where command != nil:
                        resumesWithheld += 1
                    case .attach, .freshShell:
                        break
                    }
                }
                restorePages(savedTab.pages)
                return Tab(id: savedTab.id, name: savedTab.name, tree: savedTab.tree, focusedPane: savedTab.focusedPane, zoomedPane: savedTab.zoomedPane)
            }
            let color = saved.color ?? LayoutSnapshot.Workspace.nextColor(after: workspaces.map(\.colorIndex))
            workspaces.append(Workspace(id: saved.id, folder: saved.folder, tabs: tabs, selectedTabID: saved.selectedTab, colorIndex: color, customName: saved.name))
            if let panel = saved.panel { files.panels[saved.id] = panel }
        }
        for workspace in workspaces { git.follow(workspace.id, folder: workspace.liveFolder) }
    }

    /// Terminals the host holds that no pane claimed: helpers programs started (`paw run`), which join
    /// whoever started them, and any other (the app ended before it could save a new tab), which becomes
    /// a tab in the workspace for its folder, so nothing keeps running out of sight. One that has already
    /// ended is let go. Bosses come before their helpers, so each helper finds its boss.
    private func adopt(_ running: [TerminalInfo]) {
        let order = running.sorted { ($0.origin == nil ? 0 : 1, $0.address ?? "") < ($1.origin == nil ? 0 : 1, $1.address ?? "") }
        for terminal in order where panes[terminal.id] == nil && !terminal.closing {
            if terminal.origin != nil {
                adoptStarted(terminal)
                continue
            }
            let folder = terminal.status.folder ?? FileManager.default.homeDirectoryForCurrentUser.path
            let pane = attachPane(to: terminal, folder: folder)
            guard !terminal.exited else {
                discard(pane: pane.id)
                continue
            }
            // Added where it belongs, not shown: the launch still lands on Home.
            let workspace = workspaces.first { $0.folder == folder } ?? addWorkspace(folder: folder)
            workspace.tabs.append(Tab(tree: .pane(pane.id)))
            scheduleSave()
        }
    }

    /// A terminal a program started (`paw run`), now or before a relaunch. With a tab of its own it goes
    /// right after its boss's tab, without being shown (nothing an agent does moves your focus); without
    /// one it is only a helper cat beside its boss until you look at it. One whose boss has gone becomes
    /// a tab in its folder's workspace.
    func adoptStarted(_ terminal: TerminalInfo) {
        guard panes[terminal.id] == nil, !terminal.exited, !terminal.closing else { return }
        let folder = terminal.status.folder ?? terminal.directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let pane = attachPane(to: terminal, folder: folder)
        let boss = terminal.origin?.parent.flatMap { panes[$0] }
        if terminal.origin?.background == true, let boss, workspaceOfBoss(boss) != nil { return }
        if let boss, let (workspace, tab) = workspaceOfBoss(boss) {
            let index = workspace.tabs.firstIndex { $0 === tab }.map { $0 + 1 } ?? workspace.tabs.count
            workspace.tabs.insert(Tab(tree: .pane(pane.id)), at: index)
        } else {
            let workspace = workspaces.first { $0.folder == folder } ?? addWorkspace(folder: folder)
            workspace.tabs.append(Tab(tree: .pane(pane.id)))
        }
        scheduleSave()
    }
}

/// Herdr's order for agents: needs you (longest waiting first), done (most recent first), working
/// (longest running first), idle (most recent first), then those not reported yet.
enum AgentOrder {
    static func sorted(_ rows: [AgentRow]) -> [AgentRow] {
        rows.sorted { a, b in
            if a.status != b.status { return a.status < b.status }
            switch a.status {
            case .done, .idle: return a.since > b.since
            default: return a.since < b.since
            }
        }
    }
}
