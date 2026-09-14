import AppKit
import Observation
import WhiskrKit

/// One file or folder in the file tree. A folder's children are read when it is first opened, off the
/// main thread (where the nodes for them are made too), and again when the disk says they changed. Once
/// handed to the tree, a node is only touched on the main thread.
nonisolated final class FileNode: @unchecked Sendable {
    let url: URL
    let name: String
    let isFolder: Bool
    /// Relative to the repository's top folder, '/' separated ("" for the top itself).
    let relativePath: String
    weak var parent: FileNode?
    /// nil until read.
    var children: [FileNode]?
    var isLoading = false

    init(url: URL, isFolder: Bool, relativePath: String, parent: FileNode?) {
        self.url = url
        name = url.lastPathComponent
        self.isFolder = isFolder
        self.relativePath = relativePath
        self.parent = parent
    }

    func child(named name: String) -> FileNode? { children?.first { $0.name == name } }
}

/// A workspace's folder as the side panel shows it: its files (a lazy tree, kept live by an FSEvents
/// stream), its git status, and the git commands the Changes list offers. One per folder, shared by the
/// workspaces opened on it.
@Observable
final class Repository {
    /// The repository's top folder (or the workspace's folder outside one), symbolic links resolved.
    let root: URL
    let isGit: Bool
    /// nil outside a repository, or until the first status has been read.
    private(set) var status: GitStatus?
    /// A git command's failure, shown under the commit box until the next success.
    var lastError: String?
    /// The commit message being written, kept while the panel is closed or another workspace is shown.
    var commitMessage = ""
    private(set) var isCommitting = false
    /// Goes up when the tree's listings change, for views that show counts.
    private(set) var treeVersion = 0
    /// Goes up whenever anything changed on disk here (a file's content too), for diffs that follow it.
    private(set) var diskVersion = 0

    @ObservationIgnored let rootNode: FileNode
    /// Called when a folder's children were read again: the tree reloads that folder.
    @ObservationIgnored var onFolderLoaded: [ObjectIdentifier: (FileNode) -> Void] = [:]
    /// Paths that changed on disk, for the open documents (absolute).
    @ObservationIgnored var onPathsChanged: (([String]) -> Void)?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var statusRunning = false
    @ObservationIgnored private var statusAgain = false
    @ObservationIgnored private var statusScheduled = false
    @ObservationIgnored private var index: PathIndex?
    @ObservationIgnored private var indexing: Task<PathIndex, Never>?

    init(root: URL, isGit: Bool) {
        self.root = root
        self.isGit = isGit
        rootNode = FileNode(url: root, isFolder: true, relativePath: "", parent: nil)
        watcher = FolderWatcher(folder: root) { [weak self] paths in self?.changed(paths) }
        if isGit { refreshStatus() }
    }

    var name: String { root.lastPathComponent }

    func relativePath(of url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().path
        let top = root.path
        if path == top { return "" }
        guard path.hasPrefix(top + "/") else { return nil }
        return String(path.dropFirst(top.count + 1))
    }

    // MARK: The tree

    /// Reads a folder's children off the main thread (folders first, then by name as Finder sorts), keeping
    /// the nodes it already had so open folders stay open.
    func load(_ node: FileNode) {
        guard node.isFolder, !node.isLoading else { return }
        node.isLoading = true
        let url = node.url
        let old = Dictionary((node.children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let relativePath = node.relativePath
        Task { [weak self] in
            // Listing, sorting and making the nodes all happen off the main thread: a folder of ten
            // thousand files costs the main thread only the outline's reload.
            let children = await Task.detached(priority: .userInitiated) { () -> [FileNode] in
                Self.list(url).map { entry in
                    if let kept = old[entry.name], kept.isFolder == entry.isFolder { return kept }
                    let relative = relativePath.isEmpty ? entry.name : relativePath + "/" + entry.name
                    return FileNode(url: url.appendingPathComponent(entry.name, isDirectory: entry.isFolder), isFolder: entry.isFolder, relativePath: relative, parent: node)
                }
            }.value
            guard let self else { return }
            node.isLoading = false
            node.children = children
            self.treeVersion += 1
            for callback in self.onFolderLoaded.values { callback(node) }
        }
    }

    private struct Entry: Sendable {
        let name: String
        let isFolder: Bool
    }

    /// A folder's entries, without `.git` and `.DS_Store`; a symbolic link to a folder counts as a file
    /// (a link loop never hangs the tree).
    nonisolated private static func list(_ url: URL) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        var entries: [Entry] = []
        entries.reserveCapacity(names.count)
        for name in names where name != ".git" && name != ".DS_Store" {
            var info = stat()
            let isFolder = lstat(url.appendingPathComponent(name).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            entries.append(Entry(name: name, isFolder: isFolder))
        }
        return entries.sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The node for a path, if its folders have been read.
    func node(for relativePath: String) -> FileNode? {
        guard !relativePath.isEmpty else { return rootNode }
        var node = rootNode
        for part in relativePath.split(separator: "/") {
            guard let next = node.child(named: String(part)) else { return nil }
            node = next
        }
        return node
    }

    /// The disk changed: folders on screen are read again, the status too, and open documents are told.
    private func changed(_ paths: [String]) {
        var folders: Set<String> = []
        var touchesGit = false
        var touchesTree = false
        let top = root.path
        for path in paths {
            if path.hasPrefix(top + "/.git/") || path == top + "/.git" {
                // The index, HEAD and refs change with stage, commit and checkout; objects and logs don't matter.
                let inside = path.dropFirst(top.count + 6)
                if inside.hasPrefix("index") || inside.hasPrefix("HEAD") || inside.hasPrefix("refs") || inside.hasPrefix("MERGE") { touchesGit = true }
                continue
            }
            touchesTree = true
            let parent = (path as NSString).deletingLastPathComponent
            folders.insert(parent)
            folders.insert(path)
        }
        if touchesTree || touchesGit {
            scheduleStatus()
            diskVersion += 1
        }
        guard touchesTree else { return }
        index = nil
        for folder in folders {
            guard let relative = relativePath(of: URL(fileURLWithPath: folder)), let node = node(for: relative), node.isFolder, node.children != nil else { continue }
            load(node)
        }
        onPathsChanged?(paths)
    }

    // MARK: Status

    /// Reads the status again soon (a burst of changes is one read).
    func scheduleStatus() {
        guard isGit, !statusScheduled else { return }
        statusScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.statusScheduled = false
            self?.refreshStatus()
        }
    }

    func refreshStatus() {
        guard isGit else { return }
        guard !statusRunning else {
            statusAgain = true
            return
        }
        statusRunning = true
        let root = root
        Task { [weak self] in
            let data = try? await Git.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"], in: root)
            guard let self else { return }
            self.statusRunning = false
            if let data {
                let status = GitStatus.parse(data)
                if status != self.status { self.status = status }
            }
            if self.statusAgain {
                self.statusAgain = false
                self.refreshStatus()
            }
        }
    }

    // MARK: Git commands (each from a click)

    /// Stages files (their deletions too).
    func stage(_ paths: [String]) { write(["add", "-A"], paths: paths) }

    /// Unstages files, keeping their changes in the working tree. Before the first commit there is no HEAD
    /// to restore from, so they leave the index instead.
    func unstage(_ paths: [String]) {
        if status?.commit == nil {
            write(["rm", "--cached", "-r", "-q"], paths: paths)
        } else {
            write(["restore", "--staged"], paths: paths)
        }
    }

    /// Throws away unstaged changes to tracked files (back to the index); untracked files go to the Trash,
    /// where they can still be found. Only ever after the user confirmed.
    func discard(_ entries: [GitStatusEntry]) {
        let untracked = entries.filter(\.isUntracked).map { root.appendingPathComponent($0.path) }
        let tracked = entries.filter { !$0.isUntracked }.map(\.path)
        if !untracked.isEmpty {
            NSWorkspace.shared.recycle(untracked) { [weak self] _, error in
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let message { self?.lastError = message }
                    self?.scheduleStatus()
                }
            }
        }
        if !tracked.isEmpty { write(["restore", "--worktree"], paths: tracked) }
    }

    /// Commits what is staged with `message`; calls back with whether it worked.
    func commit(message: String, done: @escaping (Bool) -> Void) {
        guard !isCommitting else { return }
        isCommitting = true
        let root = root
        Task { [weak self] in
            do {
                _ = try await Git.run(["commit", "-F", "-"], in: root, input: Data(message.utf8), writes: true)
                self?.lastError = nil
                done(true)
            } catch {
                self?.lastError = error.localizedDescription
                done(false)
            }
            self?.isCommitting = false
            self?.refreshStatus()
        }
    }

    private func write(_ arguments: [String], paths: [String]) {
        let root = root
        Task { [weak self] in
            do {
                _ = try await Git.run(arguments, paths: paths, in: root, writes: true)
                self?.lastError = nil
            } catch {
                self?.lastError = error.localizedDescription
            }
            self?.refreshStatus()
        }
    }

    /// Applies a patch of one change (`DiffPatch`) off the main thread: to the index (`cached`: stage, or
    /// with `reverse` unstage) or to the working file (`reverse`: revert it). Calls back with whether it
    /// worked; a failure is shown under the commit box, as any git command's.
    func apply(_ patch: String, cached: Bool, reverse: Bool, done: @escaping (Bool) -> Void) {
        let root = root
        var arguments = ["apply", "--whitespace=nowarn"]
        if cached { arguments.append("--cached") }
        if reverse { arguments.append("-R") }
        arguments.append("-")
        Task { [weak self] in
            do {
                _ = try await Git.run(arguments, in: root, input: Data(patch.utf8), writes: true)
                self?.lastError = nil
                done(true)
            } catch {
                self?.lastError = error.localizedDescription
                done(false)
            }
            self?.refreshStatus()
        }
    }

    /// A file as the index holds it (`git show :0:path`): the new side of its staged changes. The stage
    /// is named, so a path that itself starts with a digit and a colon is still read as a path.
    func indexText(path: String) async -> String? {
        guard let data = try? await Git.run(["show", ":0:" + path], in: root) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The unified diff of one file: its unstaged changes, or its staged ones, in the form a single
    /// change's patch is made from whatever the user's git settings (`DiffPatch.diffArguments`).
    func diff(path: String, staged: Bool) async -> String {
        let data = (try? await Git.run(DiffPatch.diffArguments(staged: staged), paths: [path], in: root)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Finding files

    /// The repository's files for Go to: `git ls-files` (tracked and untracked, ignored left out), or a
    /// walk of the folder outside a repository (bounded, tool output skipped). Built once, again after the
    /// disk changes.
    func pathIndex() async -> PathIndex {
        if let index { return index }
        if let indexing { return await indexing.value }
        let root = root, isGit = isGit
        let task = Task.detached(priority: .userInitiated) { () -> PathIndex in
            if isGit, let data = try? await Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root) {
                let paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                return PathIndex(paths: Array(Set(paths)).sorted())
            }
            return PathIndex(paths: Self.walk(root, limit: 50_000))
        }
        indexing = task
        let built = await task.value
        indexing = nil
        index = built
        return built
    }

    nonisolated private static func walk(_ root: URL, limit: Int) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        let top = root.path.count + 1
        while let url = walker.nextObject() as? URL, paths.count < limit {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if PathWalk.skippedFolders.contains(name) || name.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            if name == ".DS_Store" { continue }
            paths.append(String(url.path.dropFirst(top)))
        }
        return paths
    }
}
