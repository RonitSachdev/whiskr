import Foundation
import WhiskrKit

/// Git worktrees (as herdr has them): a checkout of another branch of a repository in a folder of its own, opened
/// as a workspace of its own. In the meadow its blanket lies beside its repository's, joined by a path;
/// in menus and the list it sits under its repository. All git work runs off the main thread, through
/// the `git` executable (`Worktrees`); a branch is never deleted.
extension Workbench {
    /// The repository a workspace's folder belongs to, as its main checkout: for a worktree, the
    /// repository it is a worktree of. nil outside a repository.
    func repositoryRoot(of workspace: Workspace) -> String? {
        guard let git = workspace.git else { return nil }
        return git.repository ?? git.root
    }

    /// The open workspace of the repository this worktree belongs to.
    func repositoryWorkspace(of workspace: Workspace) -> Workspace? {
        guard let repository = workspace.git?.repository.map(Self.canonical) else { return nil }
        return workspaces.first { $0 !== workspace && $0.git?.isWorktree == false && $0.git.map { Self.canonical($0.root) } == repository }
    }

    /// The open worktrees of a repository's workspace.
    func worktreeWorkspaces(of workspace: Workspace) -> [Workspace] {
        workspaces.filter { repositoryWorkspace(of: $0) === workspace }
    }

    /// A worktree's workspace goes beside its repository's (after the repository's other worktrees), once
    /// it is known to be one; nothing else ever reorders.
    func nestWorktree(_ workspace: Workspace) {
        guard let repository = repositoryWorkspace(of: workspace), let from = workspaces.firstIndex(where: { $0 === workspace }),
              let home = workspaces.firstIndex(where: { $0 === repository }) else { return }
        var end = home + 1
        while end < workspaces.count, workspaces[end] === workspace || repositoryWorkspace(of: workspaces[end]) === repository { end += 1 }
        // Already within its repository's group.
        if from > home && from < end { return }
        move(workspace: workspace, to: from < home ? end - 1 : end)
        scheduleSave()
    }

    /// Opens a worktree's folder as a workspace (or shows the one open there), beside its repository's.
    func openWorktree(at path: String) {
        if let open = workspaces.first(where: { Self.canonical($0.folder) == Self.canonical(path) }) {
            select(workspace: open)
            return
        }
        newWorkspace(folder: path)
    }

    /// Makes a worktree of `repository` (its main checkout's folder) on `branch` (a new one from `base`,
    /// or an existing one checked out), in the worktrees folder, and opens it beside the repository's
    /// workspace. `done` gets git's own words when it fails.
    func newWorktree(repository: String, branch: String, base: String?, done: @escaping (String?) -> Void) {
        let path = Self.worktreePath(repository: repository, branch: branch)
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do throws(GitError) {
                    try Worktrees.create(repository: repository, branch: branch, base: base, at: path.path, git: GitRunner())
                    return nil
                } catch {
                    return error.message
                }
            }.value
            if failure == nil { openWorktree(at: path.path) }
            done(failure)
        }
    }

    /// Where a new worktree of `repository` on `branch` goes (Settings › General).
    static func worktreePath(repository: String, branch: String) -> URL {
        Worktrees.defaultPath(folder: Preferences.shared.worktreeFolder, repositoryName: URL(fileURLWithPath: repository).lastPathComponent, branch: branch)
    }

    /// A path in one spelling, so a folder git names (`/private/var/…`) and the same one named otherwise
    /// (`/var/…`) compare equal.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
