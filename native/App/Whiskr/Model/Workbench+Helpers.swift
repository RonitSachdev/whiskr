import Foundation
import TerminalHost
import WhiskrKit

/// Terminals that programs start (`paw run`, agents starting and steering agents): each belongs to the
/// workspace of the Claude that started it and shows as a helper cat beside it. One with a tab of its own
/// is a tab like any; one without (`--bg`) is a "loose" helper, kept in `panes` but in no tab, until you
/// look at it (a peek over the panes, with Keep as Tab). And what the Claudes were doing, kept across a
/// relaunch.
extension Workbench {
    // MARK: Who belongs where

    /// The pane whose program started this one's terminal.
    func boss(of pane: Pane) -> Pane? {
        pane.origin?.parent.flatMap { panes[$0] }
    }

    /// A helper terminal in no tab.
    func isLooseHelper(_ pane: Pane) -> Bool {
        pane.origin != nil && workspace(of: pane.id) == nil
    }

    /// Where a boss is: its tab's workspace, or (a boss that is itself a loose helper) its own boss's.
    func workspaceOfBoss(_ boss: Pane) -> (Workspace, Tab)? {
        var current: Pane? = boss
        var seen: Set<UUID> = []
        while let pane = current, seen.insert(pane.id).inserted {
            if let place = workspace(of: pane.id) { return place }
            current = self.boss(of: pane)
        }
        return nil
    }

    /// The loose helpers of a workspace: started from one of its panes (or from one of its helpers).
    func looseHelpers(in workspace: Workspace) -> [Pane] {
        panes.values.filter { isLooseHelper($0) && boss(of: $0).flatMap(workspaceOfBoss)?.0 === workspace }
            .sorted { ($0.address ?? "").localizedStandardCompare($1.address ?? "") == .orderedAscending }
    }

    /// Every helper terminal a pane started, with a tab or without.
    func helperTerminals(of id: UUID) -> [Pane] {
        panes.values.filter { $0.origin?.parent == id }.sorted { ($0.address ?? "").localizedStandardCompare($1.address ?? "") == .orderedAscending }
    }

    // MARK: Looking at a loose helper

    /// Shows a helper with no tab over the panes (herdr's peek): its real terminal, which takes the
    /// keyboard. Only ever for something you did.
    func peek(_ id: UUID) {
        guard let pane = panes[id], isLooseHelper(pane) else { return }
        if let boss = boss(of: pane), let (workspace, tab) = workspaceOfBoss(boss) {
            if selectedWorkspaceID != workspace.id { selectedWorkspaceID = workspace.id }
            if workspace.selectedTabID != tab.id { workspace.selectedTabID = tab.id }
        }
        if focusedAgent != nil { focusedAgent = nil }
        peekedPane = id
        onFocusPane?(pane)
    }

    /// Closes the peek (its terminal keeps running) and gives the keyboard back to the pane underneath.
    func closePeek() {
        guard peekedPane != nil else { return }
        peekedPane = nil
        if let pane = focusedPane { onFocusPane?(pane) }
    }

    /// Keep as Tab: the helper gets a tab of its own, right after its boss's, and is shown there.
    func keepAsTab(_ id: UUID) {
        guard let pane = panes[id], isLooseHelper(pane) else { return }
        if peekedPane == id { peekedPane = nil }
        let tab = Tab(tree: .pane(id))
        if let boss = boss(of: pane), let (workspace, bossTab) = workspaceOfBoss(boss) {
            let index = workspace.tabs.firstIndex { $0 === bossTab }.map { $0 + 1 } ?? workspace.tabs.count
            workspace.tabs.insert(tab, at: index)
        } else {
            let workspace = workspaces.first { $0.folder == pane.currentFolder } ?? addWorkspace(folder: pane.currentFolder)
            workspace.tabs.append(tab)
        }
        select(tab: tab)
        scheduleSave()
    }

    /// Ends a helper terminal (its program, then the terminal): from its cat's menu or the peek.
    func stopHelper(_ id: UUID) {
        guard let pane = panes[id] else { return }
        if peekedPane == id { closePeek() }
        pane.end()
    }

    /// A loose helper has ended: it goes, and with it its cat (which reports to its boss on the way out).
    func discardHelper(_ id: UUID) {
        if peekedPane == id { closePeek() }
        // Only let go: the host keeps an ended helper's record a while (how it ended, its last screen) for
        // `paw wait` and `paw read`, and a close would make it forget it at once.
        letGo(pane: id)
    }

    // MARK: Kept across a relaunch

    /// The Claudes' state, written when the app saves its layout and when it quits.
    func saveAgents() {
        let open = Set(panes.values.filter(\.agentRunning).map(\.id.uuidString))
        if let data = monitor.saved(keepingPanes: open) {
            try? data.write(to: Self.agentsFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: Self.agentsFile)
        }
    }

    /// After the layout is back on its terminals: each Claude still running comes back as it was when
    /// the app quit, then takes in what its terminal reported meanwhile (a turn that ended while the app
    /// was away shows as finished and not yet seen). Entries for terminals that have ended are dropped.
    func restoreAgents() {
        guard let data = try? Data(contentsOf: Self.agentsFile) else { return }
        let running = panes.values.filter { !$0.exited && ($0.claudeInFront || $0.programReport != nil) }
        monitor.restore(data, keepingPanes: Set(running.map(\.id.uuidString)))
        for pane in running { monitor.reconcile(paneID: pane.id, report: pane.programReport) }
    }
}
