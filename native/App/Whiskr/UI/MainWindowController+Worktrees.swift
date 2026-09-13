import AppKit
import WhiskrKit

/// File › New Worktree…, Open Worktree… and Remove Worktree… (also in the workspace button's menu, the
/// blanket's, the Start page and the palette), for the repository of the selected workspace.
extension MainWindowController {
    /// The selected workspace's repository (its main checkout), when it is in one.
    var selectedRepository: String? {
        workbench.selectedWorkspace.flatMap { workbench.repositoryRoot(of: $0) }
    }

    @objc func newWorktree(_ sender: Any?) {
        guard let repository = selectedRepository, let window else { return }
        if layout.mode == .meadowOnly { showMeadowAndTerminals(nil) }
        WorktreeController.shared.show(.create, repository: repository, over: window, workbench: workbench)
    }

    @objc func openWorktree(_ sender: Any?) {
        guard let repository = selectedRepository, let window else { return }
        if layout.mode == .meadowOnly { showMeadowAndTerminals(nil) }
        WorktreeController.shared.show(.open, repository: repository, over: window, workbench: workbench)
    }

    /// Asks once; asks again, plainly, when the checkout has changes that would be lost; never deletes
    /// the branch. Its workspace closes once the folder is gone.
    @objc func removeWorktree(_ sender: Any?) {
        guard let workspace = workbench.selectedWorkspace, let git = workspace.git, let repository = git.repository, let window else { return }
        let name = workspace.name
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove the worktree “\(name)”?", comment: "Remove Worktree: the question")
        var words = String(localized: "Its folder \(abbreviatingHome(git.root)) is deleted and its workspace closes. The branch \(git.branch ?? name) stays.",
                           comment: "Remove Worktree: what happens")
        if workbench.isBusy(workspace) {
            words += " " + String(localized: "What is running there stops.", comment: "Remove Worktree: a program or Claude runs in it")
        }
        alert.informativeText = words
        alert.addButton(withTitle: String(localized: "Remove Worktree"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.remove(worktree: git.root, of: repository, workspace: workspace, force: false)
        }
    }

    private func remove(worktree path: String, of repository: String, workspace: Workspace, force: Bool) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> WorktreeRemovalError? in
                do throws(WorktreeRemovalError) {
                    try Worktrees.remove(repository: repository, path: path, force: force, git: GitRunner())
                    return nil
                } catch {
                    return error
                }
            }.value
            guard let window else { return }
            switch result {
            case nil:
                workbench.close(workspace: workspace)
            case .dirty(let changes):
                let alert = NSAlert()
                alert.messageText = String(localized: "“\(workspace.name)” has \(changes) uncommitted changes", comment: "Remove Worktree: it has changes")
                alert.informativeText = String(localized: "Removing it deletes them for good. The branch stays.", comment: "Remove Worktree: removing anyway")
                alert.addButton(withTitle: String(localized: "Remove Anyway"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                alert.buttons[0].hasDestructiveAction = true
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    self?.remove(worktree: path, of: repository, workspace: workspace, force: true)
                }
            case .git(let failure):
                let alert = NSAlert()
                alert.messageText = String(localized: "The worktree could not be removed", comment: "Remove Worktree: git refused")
                alert.informativeText = failure.message
                alert.beginSheetModal(for: window) { _ in }
            }
        }
    }

    /// Whether the worktree commands apply to the selected workspace.
    func validateWorktree(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(removeWorktree(_:)): workbench.selectedWorkspace?.git?.isWorktree == true
        default: selectedRepository != nil
        }
    }
}
