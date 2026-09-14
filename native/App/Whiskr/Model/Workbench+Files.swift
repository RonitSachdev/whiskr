import AppKit
import SwiftTerm
import WhiskrKit

/// Files and diffs in tabs, beside terminals: opening them (a preview tab while you browse, kept once you
/// edit), giving them the keyboard, closing them (asking first when there are unsaved changes), the side
/// panel, and what is saved for the next launch.
extension Workbench {
    enum OpenMode {
        /// Into the workspace's preview tab, which the next click reuses.
        case preview
        /// A tab of its own.
        case keep
        /// Beside what has the keyboard, in the same tab.
        case beside
    }

    // MARK: Reading

    /// The page with the keyboard in the selected tab, when a page has it.
    var focusedPageID: UUID? {
        guard let tab = selectedTab, pages[tab.focusedPane] != nil else { return nil }
        return tab.focusedPane
    }

    var focusedPage: TabPage? { focusedPageID.flatMap { pages[$0] } }

    /// The document of the focused file page.
    var focusedDocument: FileDocument? {
        guard case .file(let path) = focusedPage else { return nil }
        return files.openDocument(path)
    }

    /// The tab and workspace holding a page.
    func place(ofPage id: UUID) -> (Workspace, Tab)? { workspace(of: id) }

    /// The documents of a tab's file pages.
    func documents(in tab: Tab) -> [FileDocument] {
        tab.tree.panes.compactMap { id in
            guard case .file(let path) = pages[id] else { return nil }
            return files.openDocument(path)
        }
    }

    /// Whether this tab is the workspace's preview tab.
    func isPreview(_ tab: Tab) -> Bool {
        tab.tree.panes.count == 1 && files.previewPages.contains(tab.focusedPane)
    }

    /// Whether any tab shows a file with unsaved changes.
    func hasEditedFile(in tab: Tab) -> Bool { documents(in: tab).contains(where: \.isEdited) }

    /// The repository the side panel shows for the selected workspace.
    var selectedRepository: Repository? { selectedWorkspace.map(files.repository(for:)) }

    // MARK: Opening

    /// Opens a file in the selected workspace (or `workspace`): the tab already showing it, else the
    /// preview tab, a tab of its own or a split beside, by `mode`. `line` (1-based) is scrolled to.
    func open(file path: String, in workspace: Workspace? = nil, mode: OpenMode = .keep, line: Int? = nil, column: Int? = nil) {
        guard let workspace = workspace ?? selectedWorkspace else { return }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        files.noteOpened(path)
        show(.file(path: path), in: workspace, mode: mode)
        if let line, let id = focusedPageID { files.reveal(page: id, line: line, column: column) }
    }

    /// Opens a file's changes (from the Changes list, or Compare with HEAD).
    func openChanges(path: String, staged: Bool, in workspace: Workspace? = nil, mode: OpenMode = .preview) {
        guard let workspace = workspace ?? selectedWorkspace else { return }
        show(.changes(path: URL(fileURLWithPath: path).standardizedFileURL.path, staged: staged), in: workspace, mode: mode)
    }

    private func show(_ page: TabPage, in workspace: Workspace, mode: OpenMode) {
        if focusedAgent != nil { focusedAgent = nil }
        // Already open in this workspace: that tab (kept, if it was asked to be).
        for tab in workspace.tabs {
            if let id = tab.tree.panes.first(where: { pages[$0] == page }) {
                if mode != .preview { files.previewPages.remove(id) }
                focus(page: id)
                return
            }
        }
        let id = UUID()
        pages[id] = page
        if case .file(let path) = page { _ = files.document(for: path) }
        switch mode {
        case .beside:
            if let tab = workspace.selectedTab, selectedWorkspace === workspace {
                tab.zoomedPane = nil
                tab.tree = tab.tree.splitting(tab.focusedPane, axis: .horizontal, new: id)
                tab.focus(id)
                focus(page: id)
                scheduleSave()
                return
            }
            fallthrough
        case .keep:
            addPageTab(id, to: workspace)
        case .preview:
            if let tab = workspace.tabs.first(where: isPreview) {
                let old = tab.focusedPane
                tab.tree = tab.tree.replacing(old, with: id)
                tab.focus(id)
                pages[old] = nil
                files.previewPages.remove(old)
                files.previewPages.insert(id)
                focus(page: id)
            } else {
                files.previewPages.insert(id)
                addPageTab(id, to: workspace)
            }
        }
        prunePages()
        scheduleSave()
    }

    private func addPageTab(_ id: UUID, to workspace: Workspace) {
        let tab = Tab(tree: .pane(id))
        let after = workspace.selectedTab.flatMap { current in workspace.tabs.firstIndex { $0 === current } }
        workspace.tabs.insert(tab, at: after.map { $0 + 1 } ?? workspace.tabs.count)
        focus(page: id)
    }

    /// A preview stops being one: you edited it, double-clicked it, or opened it again to keep.
    func keep(page id: UUID) {
        guard files.previewPages.contains(id) else { return }
        files.previewPages.remove(id)
    }

    /// Shows a page and gives it the keyboard.
    func focus(page id: UUID) {
        guard let (workspace, tab) = workspace(of: id), pages[id] != nil else { return }
        if selectedWorkspaceID != workspace.id { selectedWorkspaceID = workspace.id }
        if workspace.selectedTabID != tab.id { workspace.selectedTabID = tab.id }
        if let zoomed = tab.zoomedPane, zoomed != id { tab.zoomedPane = nil }
        tab.focus(id)
        noteVisit(tab)
        DispatchQueue.main.async { [weak self] in self?.files.onFocusPage?(id) }
    }

    /// A page took the keyboard by a click.
    func pageTookFocus(_ id: UUID) {
        guard let (workspace, tab) = workspace(of: id) else { return }
        if selectedWorkspaceID != workspace.id { selectedWorkspaceID = workspace.id }
        if workspace.selectedTabID != tab.id { workspace.selectedTabID = tab.id }
        if focusedAgent != nil { focusedAgent = nil }
        tab.focus(id)
    }

    /// File › Split Right / Down while a page has the keyboard: a terminal beside it, in the workspace's folder.
    func splitBesidePage(_ axis: PaneTree.Axis) {
        guard let id = focusedPageID, let (workspace, tab) = workspace(of: id) else { return }
        let folder = pages[id].map { ($0.path as NSString).deletingLastPathComponent } ?? workspace.folder
        let pane = makePane(folder: FileManager.default.fileExists(atPath: folder) ? folder : workspace.folder)
        tab.zoomedPane = nil
        tab.tree = tab.tree.splitting(id, axis: axis, new: pane.id)
        focus(pane: pane.id)
        scheduleSave()
    }

    // MARK: Closing

    /// ⌘W on a page: it goes; the last leaf of a tab takes its tab with it. Unsaved changes are asked about first.
    func close(page id: UUID) {
        guard let (_, tab) = workspace(of: id) else { return }
        let documents = pages[id].flatMap { page -> FileDocument? in
            guard case .file(let path) = page, tab.tree.panes.filter({ pages[$0] == page }).count == 1 else { return nil }
            return files.openDocument(path)
        }
        confirmClosing([documents].compactMap { $0 }) { [weak self] in
            guard let self else { return }
            guard tab.tree.panes.count > 1 else { return self.close(tab: tab) }
            _ = tab.remove(id)
            self.pages[id] = nil
            self.files.previewPages.remove(id)
            if self.selectedTab === tab {
                if self.panes[tab.focusedPane] != nil { self.focus(pane: tab.focusedPane) } else { self.focus(page: tab.focusedPane) }
            }
            self.prunePages()
            self.scheduleSave()
        }
    }

    /// The tab's ×, Close Tab: asks about unsaved files first, then closes as any tab closes (⌘Z brings it back).
    func requestClose(tab: Tab) {
        confirmClosing(documents(in: tab)) { [weak self] in
            self?.close(tab: tab)
            self?.pruneSoon()
        }
    }

    /// Close Other Tabs, asking once about all their unsaved files.
    func requestClose(tabs: [Tab]) {
        confirmClosing(tabs.flatMap(documents(in:))) { [weak self] in
            // One ⌘Z brings them all back.
            self?.undoManager?.beginUndoGrouping()
            for tab in tabs { self?.close(tab: tab) }
            self?.undoManager?.endUndoGrouping()
            self?.pruneSoon()
        }
    }

    /// Whether a workspace holds files with unsaved changes (Close Workspace asks about them).
    func editedDocuments(in workspace: Workspace) -> [FileDocument] {
        workspace.tabs.flatMap(documents(in:)).filter(\.isEdited)
    }

    /// Save / Don't Save / Cancel, as a Mac app asks: one file by name, several by count. `proceed` runs
    /// after saving or not saving, never after Cancel (or a save that failed).
    func confirmClosing(_ documents: [FileDocument], cancelled: (() -> Void)? = nil, proceed: @escaping () -> Void) {
        var seen = Set<ObjectIdentifier>()
        let edited = documents.filter { $0.isEdited && seen.insert(ObjectIdentifier($0)).inserted }
        guard !edited.isEmpty, let window = files.window else { return proceed() }
        let alert = NSAlert()
        if edited.count == 1 {
            alert.messageText = String(localized: "Do you want to save the changes you made to “\(edited[0].name)”?")
        } else {
            alert.messageText = String(localized: "Do you want to save the changes you made to \(edited.count) files?")
        }
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: edited.count == 1 ? String(localized: "Save") : String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let discard = alert.addButton(withTitle: String(localized: "Don’t Save"))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = [.command]
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                for document in edited {
                    guard self?.save(document) == true else { return cancelled?() ?? () }
                }
                proceed()
            case .alertThirdButtonReturn:
                proceed()
                // Not saved is not kept. A closed tab's document lingers while ⌘Z can bring the tab back,
                // and a file opened again meanwhile would still hold the changes you chose not to save.
                guard let self else { return }
                let shown = Set(self.workspaces.flatMap(\.tabs).flatMap(\.tree.panes).compactMap { self.pages[$0]?.path })
                for document in edited where !shown.contains(document.url.standardizedFileURL.path) { document.revert() }
            default:
                cancelled?()
            }
        }
    }

    /// Saves a document, showing why when it could not be written. Returns whether it was.
    @discardableResult
    func save(_ document: FileDocument) -> Bool {
        do {
            try document.save()
            return true
        } catch {
            if let window = files.window {
                let alert = NSAlert()
                alert.messageText = String(localized: "“\(document.name)” could not be saved.")
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
            return false
        }
    }

    /// Pages that no tab shows, and no closed tab can bring back, are let go, and their documents with them.
    func prunePages() {
        let shown = Set(workspaces.flatMap(\.tabs).flatMap(\.tree.panes) + closing.flatMap(\.tree.panes))
        for id in pages.keys where !shown.contains(id) {
            pages[id] = nil
            files.previewPages.remove(id)
        }
        files.forgetDocuments(keeping: Set(pages.values.compactMap { page -> String? in
            if case .file(let path) = page { return path }
            return nil
        }))
        // Folders no workspace shows any more stop being watched.
        files.forgetRepositories(keeping: workspaces)
    }

    /// After a close: once its ⌘Z has gone, its pages go too.
    private func pruneSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds + 0.5) { [weak self] in self?.prunePages() }
    }

    // MARK: The side panel

    /// View › Files (⇧⌘E) and Changes (⇧⌘C): shows the panel in that mode, or hides it when it already shows it.
    func togglePanel(_ mode: FilesCenter.Panel.Mode) {
        guard let workspace = selectedWorkspace else { return }
        files.setPanel(workspace.id) { panel in
            if panel.shown && panel.mode == mode {
                panel.shown = false
            } else {
                panel.shown = true
                panel.mode = mode
            }
        }
        scheduleSave()
    }

    /// Reveal in Files (⇧⌘J): the panel opens on Files with the file selected, its folders opened.
    func revealInFiles(path: String) {
        guard let workspace = selectedWorkspace else { return }
        files.setPanel(workspace.id) { panel in
            panel.shown = true
            panel.mode = .files
        }
        scheduleSave()
        files.onReveal?(URL(fileURLWithPath: path))
    }

    func setPanelShown(_ shown: Bool) {
        guard let workspace = selectedWorkspace else { return }
        files.setPanel(workspace.id) { $0.shown = shown }
        scheduleSave()
    }

    // MARK: Links in terminals

    /// ⌘-click on something a terminal printed: a web link opens in the browser (any other kind of link
    /// asks first, `openTerminalURL`); a file path (relative to the pane's folder, with ":line" or
    /// ":line:column" after it) opens in the editor at that line; a folder shows in Finder.
    func openLink(_ link: String, folder: String) {
        let url = URL(string: link).flatMap { $0.scheme?.lowercased() == "file" ? nil : $0 }
        if let url, let scheme = url.scheme, scheme.count > 1, !scheme.contains(".") {
            return openTerminalURL(url)
        }
        let location = FileLocation(link, folder: folder)
        var isFolder: ObjCBool = false
        guard let location, FileManager.default.fileExists(atPath: location.path, isDirectory: &isFolder) else {
            // Not a file after all ("c:…", "name.x:…"): a link to some app, which asks first. Nothing is
            // handed to the system to open as it likes: a "file:" link to a script or an app would run it.
            if let url, url.scheme != nil { return openTerminalURL(url) }
            return AlertCenter.beep()
        }
        if isFolder.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location.path)])
        } else {
            open(file: location.path, mode: .keep, line: location.line, column: location.column)
        }
    }

    /// A path or web link the app found in a terminal's text (`TerminalLink`): opened (a file in the
    /// editor at its line, a folder in Finder, a web link in the browser), shown in Files, or copied.
    func act(on link: TerminalLink, _ action: TerminalLinkAction, folder: String) {
        switch link.target {
        case .url(let url):
            switch action {
            case .open, .reveal: if let url = URL(string: url) { openTerminalURL(url) }
            case .copy: copyToPasteboard(url)
            }
        case .file(let path, let line, let column):
            let resolved = existingPath(of: path, folder: folder)
            switch action {
            case .open:
                guard let resolved else { return AlertCenter.beep() }
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: resolved, isDirectory: &isFolder)
                if isFolder.boolValue {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resolved)])
                } else {
                    open(file: resolved, mode: .keep, line: line, column: column)
                }
            case .reveal:
                guard let resolved else { return AlertCenter.beep() }
                revealInFiles(path: resolved)
            case .copy:
                copyToPasteboard(resolved ?? path)
            }
        }
    }

    /// A link from a terminal: http, https and mailto open at once. Any other scheme hands the link to
    /// whichever app claims it (`x-apple.systempreferences:`, `smb://`, an installed app's own scheme),
    /// and a program can print a link (OSC 8) whose text shows a file name while it leads there, so the
    /// real link is shown and the user is asked first: they clicked, so a sheet is what they expect, and
    /// a link that did nothing at all would look broken. A link no app opens just beeps.
    private func openTerminalURL(_ url: URL) {
        guard !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: url) else { return AlertCenter.beep() }
        guard let window = files.window else { return }
        let name = FileManager.default.displayName(atPath: application.path)
        let alert = NSAlert()
        alert.messageText = String(localized: "Open this link in \(name)?", comment: "Asked before a link a terminal printed opens in another app; the app's name")
        alert.informativeText = url.absoluteString + "\n\n"
            + String(localized: "A program in the terminal printed this link. Its text can differ from where it leads.",
                     comment: "Under the real link, when a terminal's link would open another app")
        let open = alert.addButton(withTitle: String(localized: "Open Link"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        // Return cancels: opening takes a deliberate click.
        open.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    /// Where a path printed in a terminal is on disk: the first of its readings that exists.
    func existingPath(of path: String, folder: String) -> String? {
        TerminalLink.candidates(for: path, folder: folder).first { FileManager.default.fileExists(atPath: $0) }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Saving and restoring

    /// The files and diffs in a tab's tree, for the layout file.
    func savedPages(of tab: Tab) -> [LayoutSnapshot.Page]? {
        let saved = tab.tree.panes.compactMap { id -> LayoutSnapshot.Page? in
            switch pages[id] {
            case .file(let path): LayoutSnapshot.Page(id: id, kind: .file, path: path)
            case .changes(let path, let staged): LayoutSnapshot.Page(id: id, kind: staged ? .stagedChanges : .changes, path: path)
            default: nil
            }
        }
        return saved.isEmpty ? nil : saved
    }

    /// Puts back a saved tab's files and diffs (a file that has gone since shows a page saying so).
    func restorePages(_ saved: [LayoutSnapshot.Page]?) {
        for page in saved ?? [] {
            switch page.kind {
            case .file:
                pages[page.id] = .file(path: page.path)
                _ = files.document(for: page.path)
            case .changes: pages[page.id] = .changes(path: page.path, staged: false)
            case .stagedChanges: pages[page.id] = .changes(path: page.path, staged: true)
            }
        }
    }
}
