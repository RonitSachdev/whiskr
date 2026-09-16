import Foundation
import WhiskrKit

/// What the meadow scene reads (`SceneSnapshot`, in the Kit; `MeadowMapping` turns it into the scene's
/// world). Reading `scene` inside an observation (`Observing`) runs again when anything in it changes.
///
/// Mapping (docs/DESIGN.md): one blanket per workspace, in the workspaces' order, under a flag
/// with its name, branch and how the branch stands, in its own colour; a cat for every pane of any of its
/// tabs with Claude in it (its helpers beside it, and the terminals it started with `paw` as helpers
/// too, tab or no tab); a lantern after dark for every other pane, and its shell's command marks for the
/// blanket's camp kettle. A worktree's blanket lies beside its repository's, joined by a path.
extension Workbench {
    var scene: SceneSnapshot {
        SceneSnapshot(
            spaces: workspaces.map { workspace in
                SceneSnapshot.Space(
                    id: workspace.id, name: workspace.name, folder: workspace.folder, status: status(of: workspace),
                    blankets: [SceneSnapshot.Blanket(
                        id: workspace.id, title: workspace.name, status: status(of: workspace),
                        panes: (workspace.tabs.flatMap(\.tree.panes).compactMap { panes[$0] } + looseHelpers(in: workspace)).map(scenePane),
                        colorIndex: workspace.colorIndex, branch: workspace.branch, pinned: isPinned(workspace),
                        changes: workspace.git == nil ? nil : branchChanges[workspace.id], joinedTo: repositoryWorkspace(of: workspace)?.id)])
            },
            // A helper peeked at over the panes is what is shown, so its cat is the one ringed.
            selectedSpace: selectedWorkspace?.id, selectedBlanket: selectedWorkspace?.id, focusedPane: peekedPane ?? focusedPane?.id, focusedAgent: focusedAgent)
    }

    private func scenePane(_ pane: Pane) -> SceneSnapshot.Pane {
        let kind: SceneSnapshot.Kind
        if let status = status(of: pane) {
            let session = session(of: pane)
            kind = .agent(status: status, accountIndex: accountIndex(configDir: pane.sessionConfigDir), failed: session?.failed ?? false,
                          agents: session?.agents.familyOrder ?? [])
        } else if pane.exited {
            kind = .terminal(lantern: (pane.exitCode ?? 0) == 0 ? .dark : .failed(code: pane.exitCode ?? 0), command: .idle)
        } else {
            // Lit while a command runs in front of the shell; dark while the shell waits for you, or
            // red while its last command's failure is unseen (the shell's marks, OSC 133). The kettle goes by
            // the marks alone.
            let command: SceneSnapshot.Command = pane.failedCommand != nil ? .failed : pane.commandRunning ? .running : pane.commandSucceeded ? .finished : .idle
            kind = .terminal(lantern: pane.foreground != nil ? .lit : pane.failedCommand.map { .failed(code: $0) } ?? .dark, command: command)
        }
        return SceneSnapshot.Pane(id: pane.id, name: name(of: pane), kind: kind, parent: pane.origin?.parent)
    }

    /// The meadow chose a blanket: its workspace is shown, on the tab and pane you were last in.
    func selectBlanket(_ id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        select(workspace: workspace)
    }

    /// The meadow chose a cat or a lantern: its pane is shown and focused. A helper has no terminal of its
    /// own; its story shows in the boss's tab, with the helper remembered as the one you chose.
    func selectPane(_ id: UUID, agent: String? = nil) {
        // A helper terminal with no tab: its real terminal, peeked at over the panes.
        if agent == nil, let pane = panes[id], isLooseHelper(pane) { return peek(id) }
        if peekedPane != nil { peekedPane = nil }
        focus(pane: id, agent: agent)
    }
}
