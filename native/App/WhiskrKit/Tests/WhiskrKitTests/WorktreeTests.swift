import Foundation
import Testing
@testable import WhiskrKit

/// A throwaway repository in the temporary folder, with one commit, removed afterwards.
private struct Scratch {
    let folder: URL
    let repository: URL
    let git = GitRunner()

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-worktrees-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // git reports real paths (/private/var/…, not /var/…).
        var real = made.path
        if let resolved = realpath(made.path, nil) {
            real = String(cString: resolved)
            free(resolved)
        }
        folder = URL(fileURLWithPath: real, isDirectory: true)
        repository = folder.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git("init", "--quiet", "--initial-branch=main")
        try git("config", "user.email", "test@example.invalid")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")
        try write("README.md", "hello\n")
        try git("add", "README.md")
        try git("commit", "--quiet", "-m", "first")
    }

    @discardableResult
    func git(_ arguments: String..., in place: URL? = nil) throws -> String {
        try git.run(arguments, in: (place ?? repository).path)
    }

    func write(_ name: String, _ text: String, in place: URL? = nil) throws {
        try Data(text.utf8).write(to: (place ?? repository).appendingPathComponent(name))
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

@Suite("Worktrees")
struct WorktreeTests {
    @Test func parsesTheList() {
        let text = """
        worktree /code/shop
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /wt/shop/fix-cart
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/fix/cart
        locked reason here

        worktree /wt/shop/old
        HEAD 3333333333333333333333333333333333333333
        detached
        prunable gitdir file points to non-existent location

        """
        let list = Worktrees.parseList(text)
        #expect(list.count == 3)
        #expect(list[0] == Worktree(path: "/code/shop", head: "1111111111111111111111111111111111111111", branch: "main", isMain: true))
        #expect(list[1].branch == "fix/cart" && list[1].isLocked && !list[1].isMain)
        #expect(list[2].branch == nil && list[2].isDetached && list[2].isPrunable)
    }

    @Test func parsesABareRepository() {
        let list = Worktrees.parseList("worktree /code/shop.git\nbare\n\nworktree /wt/a\nHEAD abc\nbranch refs/heads/a\n")
        #expect(list.map(\.isBare) == [true, false])
        #expect(list[0].isMain && list[0].head == nil)
        #expect(list[1].branch == "a")
    }

    @Test func slugs() {
        #expect(Worktrees.branchSlug("feature/login fix") == "feature-login-fix")
        #expect(Worktrees.branchSlug("wt/mittens") == "wt-mittens")
        #expect(Worktrees.branchSlug(".hidden") == "hidden")
        #expect(Worktrees.branchSlug("///") == "worktree")
        #expect(Worktrees.branchSlug("v1.2_rc") == "v1.2_rc")
    }

    @Test func defaultPathsAreUnique() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.folder.appendingPathComponent("worktrees", isDirectory: true)
        let first = Worktrees.defaultPath(folder: root, repositoryName: "shop", branch: "fix/cart")
        #expect(first.path == root.appendingPathComponent("shop/fix-cart").path)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        #expect(Worktrees.defaultPath(folder: root, repositoryName: "shop", branch: "fix/cart").lastPathComponent == "fix-cart-2")
    }

    @Test func suggestionsAreStableAndFree() {
        let one = Worktrees.suggestBranch(existing: [], seed: 7)
        #expect(one == Worktrees.suggestBranch(existing: [], seed: 7))
        #expect(one.hasPrefix("wt/"))
        let taken = Set(Worktrees.words.map { "wt/\($0)" })
        let next = Worktrees.suggestBranch(existing: taken, seed: 3)
        #expect(!taken.contains(next) && next.hasSuffix("-2"))
        #expect(Worktrees.suggestBranch(existing: [one], seed: 7) != one)
    }

    @Test func validBranchNames() {
        let git = GitRunner()
        #expect(Worktrees.isValidBranchName("fix/cart", git: git))
        #expect(!Worktrees.isValidBranchName("bad..name", git: git))
        #expect(!Worktrees.isValidBranchName("-x", git: git))
        #expect(!Worktrees.isValidBranchName("", git: git))
    }

    @Test func createsListsAndRemoves() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let repo = scratch.repository.path
        #expect(try Worktrees.currentBranch(repository: repo, git: scratch.git) == "main")
        let path = scratch.folder.appendingPathComponent("worktrees/shop/fix-cart").path
        try Worktrees.create(repository: repo, branch: "fix-cart", base: "main", at: path, git: scratch.git)
        let list = try Worktrees.list(repository: repo, git: scratch.git)
        #expect(list.map(\.branch) == ["main", "fix-cart"])
        #expect(list[1].path == path)
        #expect(try Worktrees.localBranches(repository: repo, git: scratch.git).sorted() == ["fix-cart", "main"])

        // The checkout knows its repository without running git.
        let head = try #require(GitHead.find(from: path))
        #expect(head.branch == "fix-cart")
        // In the same form as `root` (standardised: /var/…, as Foundation spells it).
        #expect(head.repository == URL(fileURLWithPath: repo).standardizedFileURL.path)
        #expect(head.isWorktree)
        #expect(GitHead.find(from: repo)?.repository == nil)

        // Removing keeps the branch.
        try Worktrees.remove(repository: repo, path: path, force: false, git: scratch.git)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try Worktrees.localBranches(repository: repo, git: scratch.git).contains("fix-cart"))

        // An existing branch is checked out rather than made again.
        let again = scratch.folder.appendingPathComponent("worktrees/shop/again").path
        try Worktrees.create(repository: repo, branch: "fix-cart", base: nil, at: again, git: scratch.git)
        #expect(GitHead.find(from: again)?.branch == "fix-cart")
    }

    @Test func dirtyRemovalAsksFirst() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let repo = scratch.repository.path
        let path = scratch.folder.appendingPathComponent("worktrees/shop/wip").path
        try Worktrees.create(repository: repo, branch: "wip", base: nil, at: path, git: scratch.git)
        try scratch.write("README.md", "changed\n", in: URL(fileURLWithPath: path))
        try scratch.write("new.txt", "new\n", in: URL(fileURLWithPath: path))
        #expect(try Worktrees.uncommittedChanges(at: path, git: scratch.git) == 2)
        #expect(throws: WorktreeRemovalError.dirty(changes: 2)) {
            try Worktrees.remove(repository: repo, path: path, force: false, git: scratch.git)
        }
        #expect(FileManager.default.fileExists(atPath: path))
        try Worktrees.remove(repository: repo, path: path, force: true, git: scratch.git)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try Worktrees.localBranches(repository: repo, git: scratch.git).contains("wip"))
    }

    @Test func aFolderDeletedByHandIsForgotten() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let repo = scratch.repository.path
        let path = scratch.folder.appendingPathComponent("worktrees/shop/gone").path
        try Worktrees.create(repository: repo, branch: "gone", base: nil, at: path, git: scratch.git)
        try FileManager.default.removeItem(atPath: path)
        try Worktrees.remove(repository: repo, path: path, force: false, git: scratch.git)
        #expect(try Worktrees.list(repository: repo, git: scratch.git).count == 1)
    }

    @Test func errorsAreCleaned() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let repo = scratch.repository.path
        let path = scratch.folder.appendingPathComponent("worktrees/shop/one").path
        try Worktrees.create(repository: repo, branch: "one", base: nil, at: path, git: scratch.git)
        do {
            try Worktrees.create(repository: repo, branch: "two", base: nil, at: path, git: scratch.git)
            Issue.record("a second worktree in the same folder was made")
        } catch {
            #expect(error.status != 0)
            #expect(!error.message.hasPrefix("fatal:"))
            #expect(error.message.contains("already exists"))
        }
        #expect(GitError.cleaned("hint: try this\nfatal: bad thing\n") == "bad thing")
    }
}

@Suite("GitStatus from git")
struct GitStatusReadTests {
    @Test func aheadBehindAndChanges() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // A local branch stands in for the upstream.
        try scratch.git("branch", "upstream")
        try scratch.git("branch", "--set-upstream-to=upstream")
        try scratch.write("a.txt", "a\n")
        try scratch.git("add", "a.txt")
        try scratch.git("commit", "--quiet", "-m", "ahead")
        try scratch.git("checkout", "--quiet", "upstream")
        try scratch.write("b.txt", "b\n")
        try scratch.git("add", "b.txt")
        try scratch.git("commit", "--quiet", "-m", "behind")
        try scratch.git("checkout", "--quiet", "main")

        var status = try scratch.git.status(in: scratch.repository.path)
        #expect(status.branch == "main")
        #expect(status.upstream == "upstream")
        #expect(status.ahead == 1 && status.behind == 1)
        #expect(status.changeCount == 0)

        try scratch.write("README.md", "edited\n")
        try scratch.write("loose.txt", "x\n")
        status = try scratch.git.status(in: scratch.repository.path)
        #expect(status.changeCount == 2)
    }

    @Test func outsideARepositoryFails() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-not-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: GitError.self) { try GitRunner().status(in: folder.path) }
    }
}
