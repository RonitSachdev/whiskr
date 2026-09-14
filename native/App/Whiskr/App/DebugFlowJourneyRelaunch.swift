#if DEBUG
import AppKit
import WhiskrKit

/// The journey across quitting (`Journey`): the first run leaves three workspaces, a split and a waiting
/// Claude, and writes down what it left (`Expectation`); the next, on the same folder, checks everything
/// came back as it was, the same processes, nothing typed, the cat as it was, then quits with ⌥⌘Q; the
/// last checks that nothing of it still runs.
extension Journey {
    /// What a run leaves for the next one to find.
    struct Expectation: Codable {
        struct Space: Codable {
            var id: UUID
            var name: String
            var tabs: [TabPlace]
        }
        struct TabPlace: Codable {
            var id: UUID
            var name: String?
            var panes: [UUID]
            var focused: UUID
        }
        var workspaces: [Space]
        /// Each pane's shell, as the session host runs it.
        var pids: [UUID: Int32]
        /// Each pane's screen: its rows, trimmed, without the empty ones.
        var screens: [UUID: [String]]
        var claude: UUID?
        var claudeStatus: String?
        /// The session host's own process.
        var host: Int32?
    }

    func expectation() async -> Expectation {
        var pids: [UUID: Int32] = [:]
        // The panes' own (a tab closed within its ⌘Z moment still runs, until it ends by itself).
        for terminal in await workbench.host.terminals() where !terminal.closing && workbench.panes[terminal.id] != nil { pids[terminal.id] = terminal.pid }
        var screens: [UUID: [String]] = [:]
        for (id, pane) in workbench.panes { screens[id] = suite.screen(pane).filter { !$0.isEmpty } }
        let claude = claudePane.flatMap { workbench.panes[$0] }
        return Expectation(workspaces: workbench.workspaces.map { workspace in
            Expectation.Space(id: workspace.id, name: workspace.name, tabs: workspace.tabs.map {
                Expectation.TabPlace(id: $0.id, name: $0.name, panes: $0.tree.panes, focused: $0.focusedPane)
            })
        }, pids: pids, screens: screens, claude: claude?.id, claudeStatus: claude.flatMap(workbench.status(of:)).map { "\($0)" },
           host: MachineLoad.hostPID(log: PerfSuite.hostLog))
    }

    func write(_ expectation: Expectation) {
        try? JSONEncoder().encode(expectation).write(to: Self.expectationFile)
    }

    static func readExpectation() -> Expectation? {
        (try? Data(contentsOf: expectationFile)).flatMap { try? JSONDecoder().decode(Expectation.self, from: $0) }
    }

    // MARK: Step 6: leaving

    /// A split in the repository's first tab, a line printed in every terminal, the Claude waiting; then what
    /// is left is written down. The run then quits as ⌘Q does (`--leave-host`).
    func leaveForRelaunch() async {
        step("leaving for the relaunch")
        guard let shop = workbench.workspaces.first(where: { $0.name == "shop" }), let tab = shop.tabs.first(where: { $0.id != workbench.workspace(of: claudePane ?? UUID())?.1.id }) else {
            return check("relaunch: the repository's workspace still open", false)
        }
        workbench.select(tab: tab)
        if tab.tree.panes.count == 1 { shortcut("cmd+d") }
        for pane in workbench.panes.values where !pane.agentRunning {
            _ = await suite.shellReady(pane)
            pane.type("clear; echo left-\(pane.id.uuidString.prefix(4))\r")
        }
        await PerfWait.sleep(1500)
        workbench.goHome()
        await PerfWait.sleep(500)
        let left = await expectation()
        write(left)
        check("relaunch: what is left is written down", left.workspaces.count >= 3 && left.pids.count == workbench.panes.count && left.claude != nil,
              "\(left.workspaces.map { "\($0.name) (\($0.tabs.count) tabs)" }), \(left.pids.count) terminals, Claude \(left.claudeStatus ?? "none")")
        print("journey: left \(left.workspaces.map { "\($0.name): \($0.tabs.map { $0.panes.count })" }), Claude \(left.claudeStatus ?? "-"), host \(left.host.map(String.init) ?? "-")")
    }

    // MARK: The run after a relaunch

    func relaunched() async {
        beginWatching()
        step("relaunch: back")
        guard let left = Self.readExpectation() else { return check("relaunch: the last run left its expectation", false) }
        check("relaunch: lands on Home, titled “Whiskr”", workbench.isHome && window.title == "Whiskr", "on \(workbench.selectedWorkspace?.name ?? "Home"), “\(window.title)”")
        let keyed = await PerfWait.until(2000) { self.homeHasKeyboard }
        check("relaunch: Home has the keyboard", keyed != nil, "first responder \(describe(window.firstResponder))")
        let now = workbench.workspaces.map { workspace in
            Expectation.Space(id: workspace.id, name: workspace.name, tabs: workspace.tabs.map {
                Expectation.TabPlace(id: $0.id, name: $0.name, panes: $0.tree.panes, focused: $0.focusedPane)
            })
        }
        let same = now.map { "\($0.id) \($0.name) \($0.tabs.map { "\($0.id) \($0.name ?? "") \($0.panes) \($0.focused)" })" }
            == left.workspaces.map { "\($0.id) \($0.name) \($0.tabs.map { "\($0.id) \($0.name ?? "") \($0.panes) \($0.focused)" })" }
        check("relaunch: every workspace, tab, split and focused pane back as it was, in order", same,
              "now \(now.map { "\($0.name): \($0.tabs.map { $0.panes.count })" }), was \(left.workspaces.map { "\($0.name): \($0.tabs.map { $0.panes.count })" })")
        // The same processes, still running.
        var pids: [UUID: Int32] = [:]
        for terminal in await workbench.host.terminals() where !terminal.closing { pids[terminal.id] = terminal.pid }
        check("relaunch: every terminal is the same process as before the quit", pids == left.pids && left.pids.values.allSatisfy { kill($0, 0) == 0 },
              "now \(pids.count) terminals, \(pids.filter { left.pids[$0.key] == $0.value }.count) the same")
        check("relaunch: the session host is the one left running", MachineLoad.hostPID(log: PerfSuite.hostLog) == left.host,
              "\(MachineLoad.hostPID(log: PerfSuite.hostLog).map(String.init) ?? "-") (was \(left.host.map(String.init) ?? "-"))")
        // Nothing typed: each screen as it was (redrawn from what the host kept).
        await PerfWait.sleep(1500)
        var changed: [String] = []
        for (id, was) in left.screens {
            guard let pane = workbench.panes[id] else { changed.append("\(id) gone"); continue }
            let shown = suite.screen(pane).filter { !$0.isEmpty }
            // Redrawn from what the host kept, a screen can differ from the live one it was (a prompt drawn again
            // for a resize); typed text would show on its last line, the prompt's.
            if shown.last != was.last { changed.append("“\(workbench.name(of: pane))”: \(was.suffix(2)) → \(shown.suffix(2))") }
        }
        check("relaunch: nothing typed into any terminal, every screen as it was", changed.isEmpty, changed.joined(separator: "; "))
        // The cat as it was.
        if let id = left.claude, let pane = workbench.panes[id] {
            let back = await PerfWait.until(3000) { pane.agentRunning && self.workbench.status(of: pane).map { "\($0)" } == left.claudeStatus }
            check("relaunch: the Claude's cat is back as it was (\(left.claudeStatus ?? "-"))", back != nil,
                  "running \(pane.agentRunning), status \(workbench.status(of: pane).map { "\($0)" } ?? "none")")
            await agree("after the relaunch", pane, .request)
        } else {
            check("relaunch: the Claude's pane is back", false)
        }
        // Each workspace opens on the tab it was left on, every pane at its size.
        for workspace in workbench.workspaces {
            workbench.select(workspace: workspace)
            guard let tab = workbench.selectedTab else { continue }
            let expected = left.workspaces.first { $0.id == workspace.id }?.tabs.first { $0.id == tab.id }?.focused
            _ = await PerfWait.until(2000) { self.workbench.focusedPane.map(self.suite.focused) == true }
            check("relaunch: “\(workspace.name)” opens on its pane, with the keyboard", workbench.focusedPane?.id == expected && workbench.focusedPane.map(suite.focused) == true,
                  "first responder \(describe(window.firstResponder))")
            if tab.tree.panes.allSatisfy({ !(workbench.panes[$0]?.agentRunning ?? true) }) { await sizes(tab, "relaunched “\(workspace.name)”") }
        }
        workbench.goHome()
        // The next launch must not resume the Claude by typing `claude --resume` (that would be the real
        // one): Settings › Resume Claude in restored panes, off for this run's folder.
        Preferences.shared.resumeClaude = false
        var stopped = await expectation()
        stopped.host = MachineLoad.hostPID(log: PerfSuite.hostLog)
        write(stopped)
        finishStalls()
        // ⌥⌘Q ends the app at once: the report goes out first. A run whose checks failed ends as a failed
        // run does instead (`DebugPerf`).
        guard suite.passed, let out = DebugScenario.value("--perf") else { return }
        let text = suite.report()
        print(text)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: out))
        print("journey: Quit and Stop All Terminals (⌥⌘Q)")
        shortcut("cmd+opt+q")
        check("⌥⌘Q quits", false, "still running")
    }

    // MARK: The run after Quit and Stop All Terminals

    func afterStopping() async {
        beginWatching()
        defer { finishStalls() }
        step("after ⌥⌘Q")
        guard let left = Self.readExpectation() else { return check("after ⌥⌘Q: the last run left its expectation", false) }
        let alive = left.pids.values.filter { kill($0, 0) == 0 }
        check("after ⌥⌘Q: none of the last run's terminals is running", alive.isEmpty, "still running: \(alive)")
        check("after ⌥⌘Q: its session host has gone", left.host.map { kill($0, 0) != 0 } ?? false, "host \(left.host.map(String.init) ?? "-")")
        check("after ⌥⌘Q: the launch lands on Home", workbench.isHome && window.title == "Whiskr")
        // As designed: the workspaces come back as fresh shells in their folders, nothing running, no cat.
        check("after ⌥⌘Q: the workspaces come back, each terminal a fresh shell", workbench.workspaces.map(\.id) == left.workspaces.map(\.id)
              && workbench.panes.keys.allSatisfy { left.pids[$0] != nil },
              "\(workbench.workspaces.map(\.name)) (was \(left.workspaces.map(\.name)))")
        // Each fresh shell starts once its view is laid out, or a moment later in a tab not shown.
        var pids: [UUID: Int32] = [:]
        for _ in 0..<20 where pids.count < workbench.panes.count {
            await PerfWait.sleep(250)
            pids = [:]
            for terminal in await workbench.host.terminals() { pids[terminal.id] = terminal.pid }
        }
        check("after ⌥⌘Q: every terminal is a new process", pids.count == workbench.panes.count && pids.allSatisfy { left.pids[$0.key] != $0.value },
              "\(pids.count) terminals for \(workbench.panes.count) panes")
        await PerfWait.sleep(3000)
        let claudes = workbench.panes.values.filter(\.agentRunning)
        let typed = workbench.panes.values.filter { pane in suite.screen(pane).contains { $0.contains("claude") } }
        check("after ⌥⌘Q: no Claude, no cat, and nothing typed (resuming is off in this run's settings)", claudes.isEmpty && typed.isEmpty && workbench.monitor.sessions.isEmpty,
              "Claudes \(claudes.count), typed into \(typed.map(workbench.name(of:)))")
    }
}
#endif
