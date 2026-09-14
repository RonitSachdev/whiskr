import AppKit
import UniformTypeIdentifiers
import WhiskrKit

/// The window's file commands: File › New File, Save, Save As, Revert; View › Files, Changes and the
/// preview; Editor › indentation, line endings, wrapping, invisibles, compare, next and previous change,
/// Reveal in Files. Each acts on the file with the keyboard (the selected tab's focused page) and is
/// enabled only when it can.
extension MainWindowController {
    // MARK: Pages

    /// The page a view belongs to, if it is inside a file or a diff.
    func page(containing view: NSView) -> UUID? {
        var current: NSView? = view
        while let next = current {
            if let page = next as? FilePageView { return page.pageID }
            if let page = next as? DiffPageView { return page.pageID }
            current = next.superview
        }
        return nil
    }

    private var focusedFilePage: FilePageView? {
        workbench.focusedPageID.flatMap { terminals.paneArea.pageView($0) as? FilePageView }
    }

    private var focusedDiffPage: DiffPageView? {
        workbench.focusedPageID.flatMap { terminals.paneArea.pageView($0) as? DiffPageView }
    }

    // MARK: File

    /// File › New File… (⌥⌘N): in the Files panel, made in the selected folder and named in place.
    @objc func newFile(_ sender: Any?) { makeNew(folder: false) }
    @objc func newFolder(_ sender: Any?) { makeNew(folder: true) }

    private func makeNew(folder: Bool) {
        guard let workspace = workbench.selectedWorkspace else { return }
        workbench.files.setPanel(workspace.id) { panel in
            panel.shown = true
            panel.mode = .files
        }
        workbench.scheduleSave()
        // The tree is built as the panel shows; it makes the file once it is there.
        DispatchQueue.main.async { [weak self] in self?.terminals.sidePanel.fileTree?.makeNew(folder: folder) }
    }

    @objc func collapseFolders(_ sender: Any?) { terminals.sidePanel.fileTree?.collapseAll() }

    /// File › Save (⌘S).
    @objc func saveDocument(_ sender: Any?) {
        guard let document = workbench.focusedDocument else { return }
        workbench.save(document)
    }

    /// File › Save All (⌥⌘S, as in VS Code): every file with unsaved changes that a tab shows, in every
    /// workspace; stops at one that cannot be written, saying why.
    @objc func saveAllDocuments(_ sender: Any?) {
        for document in editedDocumentsInTabs where !workbench.save(document) { return }
    }

    private var editedDocumentsInTabs: [FileDocument] {
        var seen = Set<ObjectIdentifier>()
        return workbench.workspaces.flatMap { workbench.editedDocuments(in: $0) }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// File › Save As… (⇧⌘S): the standard save panel; the tab then shows the new file.
    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window, let document = workbench.focusedDocument, let page = workbench.focusedPageID else { return }
        let panel = NSSavePanel()
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.nameFieldStringValue = document.name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let old = document.url
            do {
                try document.save(as: url)
                self.workbench.files.moved(from: old, to: url)
                self.workbench.pages[page] = .file(path: url.standardizedFileURL.path)
                self.workbench.scheduleSave()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// File › Revert to Saved: asks, then the disk's version replaces your changes.
    @objc func revertDocumentToSaved(_ sender: Any?) {
        guard let window, let document = workbench.focusedDocument, document.isEdited else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Revert “\(document.name)” to the version on disk?")
        alert.informativeText = String(localized: "Your unsaved changes will be lost.")
        alert.addButton(withTitle: String(localized: "Revert"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { document.revert() }
        }
    }

    // MARK: View

    /// View › Files (⇧⌘E) and Changes (⇧⌘C).
    @objc func showFilesPanel(_ sender: Any?) { workbench.togglePanel(.files) }
    @objc func showChangesPanel(_ sender: Any?) { workbench.togglePanel(.changes) }

    /// View › Show Preview (⌥⌘P): Markdown or SVG between its source and its preview.
    @objc func togglePreview(_ sender: Any?) {
        guard let page = focusedFilePage else { return }
        page.setMode(page.mode == .source ? .preview : .source)
    }

    @objc func togglePreviewSideBySide(_ sender: Any?) {
        guard let page = focusedFilePage else { return }
        page.setMode(page.mode == .sideBySide ? .source : .sideBySide)
    }

    // MARK: Editor

    @objc func setIndentation(_ sender: NSMenuItem) {
        guard let document = workbench.focusedDocument else { return }
        document.indentation = sender.tag == 0 ? Indentation(usesTabs: true, width: document.indentation.width) : Indentation(usesTabs: false, width: sender.tag)
    }

    @objc func setLineEnding(_ sender: NSMenuItem) {
        guard let document = workbench.focusedDocument, LineEnding.allCases.indices.contains(sender.tag) else { return }
        document.setLineEnding(LineEnding.allCases[sender.tag])
    }

    @objc func toggleWrapLines(_ sender: Any?) { EditorPreferences.shared.wrapLines.toggle() }
    @objc func toggleInvisibles(_ sender: Any?) { EditorPreferences.shared.showInvisibles.toggle() }

    /// Editor › Compare with HEAD: the file's changes in a tab beside it.
    @objc func compareWithHEAD(_ sender: Any?) {
        guard let document = workbench.focusedDocument else { return }
        workbench.openChanges(path: document.url.path, staged: false, mode: .keep)
    }

    @objc func nextChange(_ sender: Any?) { focusedDiffPage?.step(next: true) }
    @objc func previousChange(_ sender: Any?) { focusedDiffPage?.step(next: false) }

    /// Editor › Reveal in Files (⇧⌘J).
    @objc func revealInFiles(_ sender: Any?) {
        guard let path = workbench.focusedPage?.path else { return }
        workbench.revealInFiles(path: path)
    }

    // MARK: Validation

    /// The file commands' state, or nil for a command that is not one of them.
    func validateFilesItem(_ item: NSMenuItem) -> Bool? {
        let document = workbench.focusedDocument
        let hasWorkspace = workbench.selectedWorkspace != nil
        let panel = workbench.selectedWorkspace.map { workbench.files.panel($0.id) }
        switch item.action {
        case #selector(newFile(_:)), #selector(newFolder(_:)), #selector(collapseFolders(_:)):
            return hasWorkspace
        case #selector(saveDocument(_:)):
            return document?.isText == true
        case #selector(saveDocumentAs(_:)):
            return document?.isText == true
        case #selector(saveAllDocuments(_:)):
            return !editedDocumentsInTabs.isEmpty
        case #selector(revertDocumentToSaved(_:)):
            return document?.isEdited == true
        case #selector(showFilesPanel(_:)):
            item.state = panel?.shown == true && panel?.mode == .files ? .on : .off
            return hasWorkspace
        case #selector(showChangesPanel(_:)):
            item.state = panel?.shown == true && panel?.mode == .changes ? .on : .off
            return hasWorkspace
        case #selector(togglePreview(_:)):
            let page = focusedFilePage
            item.title = page?.mode == .preview ? String(localized: "Show Source") : String(localized: "Show Preview")
            return page?.previewable == true
        case #selector(togglePreviewSideBySide(_:)):
            let page = focusedFilePage
            item.state = page?.mode == .sideBySide ? .on : .off
            return page?.previewable == true
        case #selector(setIndentation(_:)):
            guard let document, document.isText else { return false }
            item.state = (item.tag == 0 ? document.indentation.usesTabs : !document.indentation.usesTabs && document.indentation.width == item.tag) ? .on : .off
            return true
        case #selector(setLineEnding(_:)):
            guard let document, document.isText else { return false }
            item.state = LineEnding.allCases.indices.contains(item.tag) && document.format.lineEnding == LineEnding.allCases[item.tag] ? .on : .off
            return true
        case #selector(toggleWrapLines(_:)):
            item.state = EditorPreferences.shared.wrapLines ? .on : .off
            return true
        case #selector(toggleInvisibles(_:)):
            item.state = EditorPreferences.shared.showInvisibles ? .on : .off
            return true
        case #selector(compareWithHEAD(_:)):
            guard let document, let repository = workbench.files.repository(containing: document.url),
                  let relative = repository.relativePath(of: document.url) else { return false }
            return repository.status?.decorations[relative].map { $0 != .untracked } ?? false
        case #selector(nextChange(_:)), #selector(previousChange(_:)):
            return focusedDiffPage != nil
        case #selector(revealInFiles(_:)):
            return workbench.focusedPage != nil
        default:
            return nil
        }
    }
}

extension LineEnding {
    /// As the Line Endings menu names them.
    var label: String {
        switch self {
        case .lf: String(localized: "LF (macOS and Linux)", comment: "Line endings menu")
        case .crlf: String(localized: "CRLF (Windows)", comment: "Line endings menu")
        case .cr: String(localized: "CR (Classic Mac)", comment: "Line endings menu")
        }
    }
}
