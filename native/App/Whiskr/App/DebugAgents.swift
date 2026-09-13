#if DEBUG
import AppKit
import TerminalHost
import WhiskrKit

/// Debug builds only: command-line steps for agents starting agents and for worktrees, so each can be
/// looked at in a background snapshot. Run from `DebugScenario.run`, after its own flags.
///
///   --demo-helpers          with --demo: the busy Claude starts two helper terminals with no tab of their
///                           own (as `paw run --bg` does, through the session host), driven by hook events
///   --peek-after <s>        looks at the first such helper (as a click on its cat does)
///   --report-after <s>      the first helper reports to its boss (as `paw send` does): the meadow acts it out
///   --new-worktree <branch> [--worktree-after <s>]  makes a worktree of the selected workspace's repository
///   --worktree-panel create|open [--worktree-panel-after <s>]  shows New Worktree or Open Worktree
@MainActor
enum DebugAgents {
    private static func value(_ flag: String) -> String? { DebugScenario.value(flag) }
    private static func has(_ flag: String) -> Bool { DebugScenario.has(flag) }

    static func run(workbench: Workbench, window: MainWindowController, boss: UUID?) {
        if has("--demo-helpers"), let boss { startHelpers(workbench: workbench, boss: boss) }
        if let delay = value("--peek-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let helper = workbench.panes.values.first(where: workbench.isLooseHelper) else { return print("peek: no helper") }
                workbench.selectPane(helper.id)
            }
        }
        if let delay = value("--report-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let helper = workbench.panes.values.first(where: workbench.isLooseHelper), let boss = workbench.boss(of: helper) else { return print("report: no helper") }
                workbench.onPassed?(PassedMessage(from: helper.id, to: boss.id, kind: .message))
            }
        }
        if let branch = value("--new-worktree") {
            let delay = value("--worktree-after").flatMap(Double.init) ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let workspace = workbench.selectedWorkspace, let repository = workbench.repositoryRoot(of: workspace) else { return print("worktree: no repository") }
                workbench.newWorktree(repository: repository, branch: branch, base: nil) { failure in print("worktree \(branch): \(failure ?? "made")") }
            }
        }
        if let mode = value("--worktree-panel") {
            let delay = value("--worktree-panel-after").flatMap(Double.init) ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                window.window?.makeFirstResponder(nil)
                if mode == "open" { window.openWorktree(nil) } else { window.newWorktree(nil) }
            }
        }
    }

    /// Two helper terminals started from `boss` through the host, as `paw run --bg` would; once the app
    /// has them, hook events make one read and the other ask for permission.
    private static func startHelpers(workbench: Workbench, boss: UUID) {
        guard workbench.host.speaksAgents, let connection = workbench.host.connect(HostConnection.Handlers()) else { return print("helpers: host speaks no agents") }
        connection.send(.hello(HostProtocol.current, client: "debug"))
        let folder = workbench.panes[boss]?.currentFolder ?? NSHomeDirectory()
        let helpers: [(String, [(String, [String: JSONValue])])] = [
            ("review", [("UserPromptSubmit", [:]), ("PreToolUse", ["tool_name": "Read", "tool_use_id": "r1", "tool_input": ["file_path": .string("\(folder)/cart.ts")]])]),
            ("tests", [("UserPromptSubmit", [:]), ("PreToolUse", ["tool_name": "Bash", "tool_use_id": "b1", "tool_input": ["command": "npm test"]]),
                       ("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]])]),
        ]
        for (index, helper) in helpers.enumerated() {
            let id = UUID()
            let run = RunRequest(terminal: id, parent: boss, command: "sleep 3600", task: nil, name: helper.0, directory: folder, background: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 1.5) {
                connection.send(.run(run))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    for (event, extra) in helper.1 {
                        var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string("demo-\(helper.0)"), "cwd": .string(folder)]
                        payload.merge(extra) { _, new in new }
                        workbench.monitor.simulate(paneID: id, payload: .object(payload))
                    }
                }
            }
        }
        // Kept for the run's life: closing it would not end the helpers, but it is the run's.
        withExtendedLifetime(connection) {}
        retained = connection
    }

    private static var retained: HostConnection?
}
#endif
