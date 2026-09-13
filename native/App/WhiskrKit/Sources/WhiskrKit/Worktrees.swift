import Foundation

/// One checkout of a repository, as `git worktree list` reports it: the main one, or a linked worktree.
public struct Worktree: Sendable, Equatable, Identifiable {
    public var path: String
    /// The commit checked out; nil in a bare repository.
    public var head: String?
    /// The branch checked out ("main", not "refs/heads/main"); nil when detached or bare.
    public var branch: String?
    /// The repository's own checkout, the first one listed.
    public var isMain: Bool
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    /// Its folder has gone; `git worktree prune` would forget it.
    public var isPrunable: Bool

    public var id: String { path }

    public init(path: String, head: String? = nil, branch: String? = nil, isMain: Bool = false, isBare: Bool = false, isDetached: Bool = false,
                isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Removing a worktree failed: it has uncommitted changes (asked again before forcing), or git refused.
public enum WorktreeRemovalError: Error, Sendable, Equatable {
    case dirty(changes: Int)
    case git(GitError)
}

/// Worktrees (as herdr has them): more checkouts of one repository, each on its own branch in its own folder, so
/// several Claudes can work on one project without stepping on each other. Everything goes through the
/// `git` executable (`GitRunner`), so it blocks: call it off the main thread. A branch is never deleted:
/// removing a worktree removes its folder only.
public enum Worktrees {
    // MARK: Reading

    /// `git worktree list --porcelain`: blocks of "key value" lines separated by blank lines, the main
    /// checkout first.
    public static func parseList(_ porcelain: String) -> [Worktree] {
        var list: [Worktree] = []
        var current: Worktree?
        func finish() {
            if var done = current {
                done.isMain = list.isEmpty
                list.append(done)
            }
            current = nil
        }
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                finish()
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            let key = parts[0], value = parts.count > 1 ? String(parts[1]) : ""
            if key == "worktree" {
                finish()
                current = Worktree(path: value)
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked": current?.isLocked = true
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        finish()
        return list
    }

    public static func list(repository: String, git: GitRunner) throws(GitError) -> [Worktree] {
        parseList(try git.run(["worktree", "list", "--porcelain"], in: repository))
    }

    public static func localBranches(repository: String, git: GitRunner) throws(GitError) -> [String] {
        try git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: repository)
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The branch checked out in `repository`; nil when detached (or before the first commit on an
    /// unborn branch, git still names it).
    public static func currentBranch(repository: String, git: GitRunner) throws(GitError) -> String? {
        let name = try git.run(["branch", "--show-current"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Whether git would accept `name` as a new branch's name.
    public static func isValidBranchName(_ name: String, git: GitRunner) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        return (try? git.run(["check-ref-format", "--branch", name], in: NSTemporaryDirectory())) != nil
    }

    /// Changed, staged and untracked files in the checkout at `path`.
    public static func uncommittedChanges(at path: String, git: GitRunner) throws(GitError) -> Int {
        try git.run(["status", "--porcelain", "--untracked-files=all"], in: path).split(whereSeparator: \.isNewline).count
    }

    // MARK: Places and names

    /// A branch as one folder name: anything but letters, digits, "." "_" "-" becomes "-", runs of them
    /// one, and none at either end ("feature/login fix" is "feature-login-fix").
    public static func branchSlug(_ branch: String) -> String {
        var slug = ""
        for scalar in branch.unicodeScalars {
            let keep = CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-"
            if keep { slug.unicodeScalars.append(scalar) } else if !slug.hasSuffix("-") { slug += "-" }
        }
        while slug.hasPrefix("-") || slug.hasPrefix(".") { slug.removeFirst() }
        while slug.hasSuffix("-") || slug.hasSuffix(".") { slug.removeLast() }
        return slug.isEmpty ? "worktree" : slug
    }

    /// Where a new worktree goes: `<folder>/<repository>/<branch slug>`, with "-2", "-3"… added when
    /// that folder already exists.
    public static func defaultPath(folder: URL, repositoryName: String, branch: String, fileManager: FileManager = .default) -> URL {
        let parent = folder.appendingPathComponent(branchSlug(repositoryName), isDirectory: true)
        let slug = branchSlug(branch)
        var candidate = parent.appendingPathComponent(slug, isDirectory: true)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(slug)-\(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }

    /// Short, friendly words for a new worktree's branch; the prefix keeps them together in branch lists.
    static let words = ["mittens", "biscuit", "clover", "pebble", "maple", "muffin", "tofu", "button", "pumpkin", "willow",
                        "sesame", "pepper", "mochi", "acorn", "hazel", "bramble", "juniper", "toffee", "fern", "nutmeg"]
    static let prefix = "wt/"

    /// A branch name for a new worktree that no branch has yet: one of the friendly words (chosen by
    /// `seed`, so the same seed suggests the same name), with a number once they are all taken.
    public static func suggestBranch(existing: Set<String>, seed: UInt64) -> String {
        let start = Int(seed % UInt64(words.count))
        for round in 1... {
            for step in 0..<words.count {
                let word = words[(start + step) % words.count]
                let name = round == 1 ? "\(prefix)\(word)" : "\(prefix)\(word)-\(round)"
                if !existing.contains(name) { return name }
            }
        }
        return prefix + words[start]
    }

    // MARK: Changing

    /// A new checkout at `path` on `branch`: the branch is made from `base` (default: what is checked out
    /// now) unless a local branch of that name exists, which is then checked out there.
    public static func create(repository: String, branch: String, base: String?, at path: String, git: GitRunner) throws(GitError) {
        let exists = (try? git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repository)) != nil
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw GitError(message: "\(parent.path) could not be made: \(error.localizedDescription)", status: -1)
        }
        if exists {
            try git.run(["worktree", "add", "--", path, branch], in: repository, timeout: 120)
        } else {
            try git.run(["worktree", "add", "-b", branch, "--", path] + (base.map { [$0] } ?? []), in: repository, timeout: 120)
        }
    }

    /// Removes the checkout at `path`; its branch stays. Without `force` a checkout with uncommitted
    /// changes is refused (`.dirty`), so the caller can ask again before throwing them away.
    public static func remove(repository: String, path: String, force: Bool, git: GitRunner) throws(WorktreeRemovalError) {
        if !force, FileManager.default.fileExists(atPath: path) {
            let changes: Int
            do { changes = try uncommittedChanges(at: path, git: git) } catch { throw .git(error) }
            if changes > 0 { throw .dirty(changes: changes) }
        }
        do {
            // Twice forced also removes a locked worktree, which a person asked for by confirming.
            try git.run(["worktree", "remove"] + (force ? ["--force", "--force"] : []) + ["--", path], in: repository, timeout: 120)
        } catch {
            // A folder deleted by hand: git only needs to forget it.
            if !FileManager.default.fileExists(atPath: path) {
                do { try git.run(["worktree", "prune"], in: repository) } catch { throw .git(error) }
                return
            }
            if !force, isDirtyRemoveMessage(error.message) { throw .dirty(changes: (try? uncommittedChanges(at: path, git: git)) ?? 1) }
            throw .git(error)
        }
    }

    /// git's refusal to remove a worktree with changes ("contains modified or untracked files, use --force").
    static func isDirtyRemoveMessage(_ message: String) -> Bool {
        message.contains("modified or untracked files") || message.contains("use --force")
    }
}
