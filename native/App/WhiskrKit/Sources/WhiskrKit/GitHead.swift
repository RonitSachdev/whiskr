import Foundation

/// A folder's git repository and the branch checked out there, read straight from the repository's
/// files (no `git` process): the `.git` folder (or, in a worktree or submodule, the `.git` file naming
/// it) and its `HEAD`. Cheap enough to read again whenever `HEAD` changes.
public struct GitHead: Sendable, Equatable {
    /// The repository's top folder (the one holding `.git`).
    public let root: String
    /// The file to watch: it changes when you switch branch.
    public let headFile: String
    /// The branch, or the first seven characters of the commit when none is checked out (detached);
    /// nil when `HEAD` cannot be read.
    public let branch: String?
    /// The repository's own checkout (its top folder) when this is a linked worktree of it; nil for the
    /// main checkout, a submodule, or a worktree of a bare repository.
    public let repository: String?

    /// A linked worktree: another checkout of `repository`, on a branch of its own.
    public var isWorktree: Bool { repository != nil }

    /// The repository's name, as the workspace is named after it (herdr's rule): its top folder's name.
    public var name: String { URL(fileURLWithPath: root).lastPathComponent }

    /// The repository `folder` is in, looking up through its parents; nil outside one.
    public static func find(from folder: String, fileManager: FileManager = .default) -> GitHead? {
        var url = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        while true {
            let dotGit = url.appendingPathComponent(".git")
            var isFolder: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isFolder) {
                let gitDir = isFolder.boolValue ? dotGit.path : Self.linkedFolder(file: dotGit, base: url)
                if let gitDir {
                    let head = URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD").path
                    let contents = fileManager.contents(atPath: head).flatMap { String(data: $0, encoding: .utf8) }
                    return GitHead(root: url.path, headFile: head, branch: contents.flatMap(branch(head:)),
                                   repository: isFolder.boolValue ? nil : mainCheckout(gitDir: gitDir, fileManager: fileManager))
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path || url.path == "/" { return nil }
            url = parent
        }
    }

    /// The branch named by a `HEAD` file's contents: "ref: refs/heads/fix-cart" is "fix-cart"; a bare
    /// commit id is its first seven characters.
    public static func branch(head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let heads = "refs/heads/"
            let name = ref.hasPrefix(heads) ? String(ref.dropFirst(heads.count)) : ref
            return name.isEmpty ? nil : name
        }
        guard line.count >= 7, line.allSatisfy(\.isHexDigit) else { return nil }
        return String(line.prefix(7))
    }

    /// For a linked worktree's git folder (`<repo>/.git/worktrees/<name>`), the main checkout's top
    /// folder: its `commondir` file names the repository's own git folder, whose parent that is. nil when
    /// there is no `commondir` (a submodule) or the common folder is not a `.git` folder (a bare repository).
    static func mainCheckout(gitDir: String, fileManager: FileManager = .default) -> String? {
        let file = URL(fileURLWithPath: gitDir).appendingPathComponent("commondir")
        guard let text = fileManager.contents(atPath: file.path).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let common = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: gitDir).appendingPathComponent(path)).standardizedFileURL
        guard common.lastPathComponent == ".git" else { return nil }
        return common.deletingLastPathComponent().path
    }

    /// A `.git` file ("gitdir: ../.git/worktrees/x") names the real folder, maybe relative to its own.
    static func linkedFolder(file: URL, base: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("gitdir:") {
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            return path.hasPrefix("/") ? path : base.appendingPathComponent(path).standardizedFileURL.path
        }
        return nil
    }
}
