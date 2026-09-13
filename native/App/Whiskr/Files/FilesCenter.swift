import AppKit
import Observation
import WhiskrKit

/// Everything the files side of the window holds beside the workbench's terminals: each workspace's side
/// panel, the repositories behind them, the open documents (one per file, however many tabs show it),
/// which tab is a preview, and the files opened lately.
@Observable
final class FilesCenter {
    typealias Panel = LayoutSnapshot.Panel

    /// Each workspace's side panel (absent: closed, Files, 280 pt).
    var panels: [UUID: Panel] = [:]
    /// Pages showing a file only until another is clicked (an italic tab title; editing or double-
    /// clicking keeps it).
    var previewPages: Set<UUID> = []

    @ObservationIgnored private(set) var repositories: [String: Repository] = [:]
    /// Changes after a repository is added or replaced (a folder is first a plain one, until git is found
    /// there): what looked one up by a file's path looks again.
    private(set) var repositoryGeneration = 0
    @ObservationIgnored private(set) var documents: [String: FileDocument] = [:]
    /// Files opened lately, newest first (absolute paths), for Go to before anything is typed.
    @ObservationIgnored private(set) var recentFiles: [String] = []
    /// Gives a page the keyboard (set by the window).
    @ObservationIgnored var onFocusPage: ((UUID) -> Void)?
    /// Selects a file in the side panel's tree (set by the window).
    @ObservationIgnored var onReveal: ((URL) -> Void)?
    /// The window sheets are shown on.
    @ObservationIgnored weak var window: NSWindow?
    /// Lines to scroll to when a page shows (Go to Line from a terminal's path, ⌘-click).
    @ObservationIgnored private(set) var pendingReveal: [UUID: (line: Int, column: Int?)] = [:]

    static let revealLine = Notification.Name("Whiskr.RevealLine")

    static let panelMinimum: Double = 200
    static let panelDefault: Double = 280

    func panel(_ workspace: UUID) -> Panel { panels[workspace] ?? Panel(width: Self.panelDefault) }

    func setPanel(_ workspace: UUID, _ change: (inout Panel) -> Void) {
        var panel = panel(workspace)
        change(&panel)
        if panels[workspace] != panel { panels[workspace] = panel }
    }

    // MARK: Repositories

    /// The repository (or plain folder) the panel shows for a workspace: its git top folder, else its folder.
    func repository(for workspace: Workspace) -> Repository {
        let isGit = workspace.git != nil
        let path = URL(fileURLWithPath: workspace.git?.root ?? workspace.folder, isDirectory: true).resolvingSymlinksInPath().path
        if let known = repositories[path], known.isGit == isGit { return known }
        let repository = Repository(root: URL(fileURLWithPath: path, isDirectory: true), isGit: isGit)
        repository.onPathsChanged = { [weak self] paths in self?.pathsChanged(paths) }
        repositories[path] = repository
        // Told after the current update: this is often asked while a view is being drawn.
        DispatchQueue.main.async { [weak self] in self?.repositoryGeneration += 1 }
        return repository
    }

    /// The repository holding a file, among those open.
    func repository(containing url: URL) -> Repository? {
        let path = url.resolvingSymlinksInPath().path
        return repositories.values.filter { path.hasPrefix($0.root.path + "/") }.max { $0.root.path.count < $1.root.path.count }
    }

    /// Repositories no workspace shows any more stop watching.
    func forgetRepositories(keeping workspaces: [Workspace]) {
        let kept = Set(workspaces.map { URL(fileURLWithPath: $0.git?.root ?? $0.folder).resolvingSymlinksInPath().path })
        for path in repositories.keys where !kept.contains(path) && !documents.keys.contains(where: { $0.hasPrefix(path + "/") }) {
            repositories[path] = nil
        }
    }

    // MARK: Documents

    /// The document for a file, opened (and read) the first time it is asked for.
    func document(for path: String) -> FileDocument {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        if let open = documents[key] { return open }
        let document = FileDocument(url: URL(fileURLWithPath: key))
        documents[key] = document
        return document
    }

    func openDocument(_ path: String) -> FileDocument? { documents[URL(fileURLWithPath: path).standardizedFileURL.path] }

    /// Documents no page shows any more are let go.
    func forgetDocuments(keeping paths: Set<String>) {
        for key in documents.keys where !paths.contains(key) { documents[key] = nil }
    }

    var editedDocuments: [FileDocument] { documents.values.filter(\.isEdited).sorted { $0.name < $1.name } }

    /// A file or folder was renamed or moved in the tree: documents inside follow it.
    func moved(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        for (key, document) in documents where key == oldPath || key.hasPrefix(oldPath + "/") {
            let moved = URL(fileURLWithPath: new.standardizedFileURL.path + key.dropFirst(oldPath.count))
            documents[key] = nil
            documents[moved.path] = document
            document.moved(to: moved)
        }
    }

    /// Asks a file page to show a line (now, or once it is on screen).
    func reveal(page: UUID, line: Int, column: Int?) {
        pendingReveal[page] = (line, column)
        NotificationCenter.default.post(name: Self.revealLine, object: page)
    }

    func takeReveal(page: UUID) -> (line: Int, column: Int?)? {
        pendingReveal.removeValue(forKey: page)
    }

    func noteOpened(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 30 { recentFiles.removeLast() }
    }

    /// Changes on disk reach the documents for those paths (and the documents inside a folder that moved).
    private func pathsChanged(_ paths: [String]) {
        // FSEvents names paths with links resolved (/private/tmp for /tmp).
        let changed = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for document in documents.values {
            let real = document.url.resolvingSymlinksInPath().path
            if changed.contains(real) || changed.contains((real as NSString).deletingLastPathComponent) { document.diskMayHaveChanged() }
        }
    }

    /// The app came back to the front: every open document looks at the disk once (a change made while
    /// the Mac slept, or on a volume FSEvents does not watch).
    func checkAllDocuments() {
        for document in documents.values { document.diskMayHaveChanged() }
    }
}
