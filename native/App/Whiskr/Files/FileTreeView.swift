import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WhiskrKit

/// The workspace's files as a native outline: folders first, read as they open, git letters on the
/// right, ignored paths faint, kept live as files change on disk. A click opens a file in the preview tab
/// (⌥-click beside), a double-click keeps it; Return renames, ⌘⌫ moves to the Trash, Space is Quick Look,
/// and a file dragged onto a terminal pastes its path.
final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let repository: Repository
    private let workbench: Workbench
    private let scrollView = NSScrollView()
    let outline = FileOutline()
    private var statusObserver: Observing?
    private var appearanceObserver: Observing?
    /// A file or folder just made: its name is edited at once, and a file opens once named.
    private var fresh: URL?
    private var revealing: URL?

    init(repository: Repository, workbench: Workbench) {
        self.repository = repository
        self.workbench = workbench
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.tree = self
        outline.setAccessibilityLabel(String(localized: "Files in \(repository.name)", comment: "Accessibility: the file tree"))
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        repository.onFolderLoaded[ObjectIdentifier(self)] = { [weak self] node in self?.folderLoaded(node) }
        statusObserver = Observing { [weak self] in
            guard let self else { return }
            _ = self.repository.status
            self.refreshVisibleRows()
        }
        appearanceObserver = Observing { [weak self] in
            _ = ThemeStore.shared.palette
            self?.refreshVisibleRows()
        }
        repository.load(repository.rootNode)
    }

    required init?(coder: NSCoder) {
        fatalError("FileTreeView is created in code")
    }

    isolated deinit {
        repository.onFolderLoaded[ObjectIdentifier(self)] = nil
    }

    // MARK: Data

    private func node(_ item: Any?) -> FileNode { (item as? FileNode) ?? repository.rootNode }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = node(item)
        guard let children = node.children else {
            repository.load(node)
            return 0
        }
        return min(children.count, shown[ObjectIdentifier(node)] ?? children.count)
    }

    /// A folder of thousands of files reaches the outline a thousand rows at a time, one batch per turn of
    /// the run loop, so opening it never holds the main thread (the outline asks about every row it gets).
    private static let batch = 1000
    private var shown: [ObjectIdentifier: Int] = [:]

    private func showMore(of node: FileNode) {
        let key = ObjectIdentifier(node)
        guard let total = node.children?.count, let count = shown[key], count < total else {
            shown[key] = nil
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shown[key] == count, node.children?.count == total else { return }
            let next = min(total, count + Self.batch)
            self.shown[key] = next
            let parent: Any? = node === self.repository.rootNode ? nil : node
            self.outline.insertItems(at: IndexSet(integersIn: count..<next), inParent: parent, withAnimation: [])
            self.showMore(of: node)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { node(item).isFolder }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        cell.textField?.delegate = self
        cell.show(node(item), repository: repository)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { FileRowView() }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        node(item).url as NSURL
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        if node.children == nil { repository.load(node) }
    }

    private func folderLoaded(_ node: FileNode) {
        let item: Any? = node === repository.rootNode ? nil : node
        // A folder not in the outline (its parent closed) has nothing to show yet.
        if let item, outline.row(forItem: item) < 0 { return continueReveal() }
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
        shown[ObjectIdentifier(node)] = min(node.children?.count ?? 0, Self.batch)
        outline.reloadItem(item, reloadChildren: true)
        showMore(of: node)
        if node.children?.isEmpty == false, let item, outline.isItemExpanded(item) == false, revealing != nil { outline.expandItem(item) }
        let rows = IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if !rows.isEmpty { outline.selectRowIndexes(rows, byExtendingSelection: false) }
        if let fresh, let made = node.children?.first(where: { $0.url.standardizedFileURL == fresh.standardizedFileURL }) {
            self.fresh = nil
            let row = outline.row(forItem: made)
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                DispatchQueue.main.async { [weak self] in self?.beginRename(row: row, fresh: made.url) }
            }
        }
        continueReveal()
    }

    /// The rows that have views (those on screen and near it) take the new git state; others get it when
    /// they are made.
    private func refreshVisibleRows() {
        outline.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? FileCell)?.show(node(outline.item(atRow: row)), repository: repository)
        }
    }

    // MARK: Opening

    @objc private func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isFolder {
            if outline.isItemExpanded(node) { outline.animator().collapseItem(node) } else { outline.animator().expandItem(node) }
            return
        }
        let beside = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        workbench.open(file: node.url.path, mode: beside ? .beside : .preview)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, !node.isFolder else { return }
        workbench.open(file: node.url.path, mode: .keep)
    }

    /// ⌘↓ or ⌘O on the selection: opens what is selected, each in a tab of its own.
    func openSelection() {
        for node in selectedNodes where !node.isFolder { workbench.open(file: node.url.path, mode: .keep) }
    }

    var selectedNodes: [FileNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
    }

    /// The folder new files go into: the selected folder, the selected file's folder, or the top.
    var targetFolder: FileNode {
        guard let node = selectedNodes.first else { return repository.rootNode }
        return node.isFolder ? node : node.parent ?? repository.rootNode
    }

    // MARK: Revealing

    /// Shows a file in the tree: its folders open (read first where needed), it is selected and scrolled to.
    func reveal(_ url: URL) {
        revealing = url.standardizedFileURL
        continueReveal()
    }

    private func continueReveal() {
        guard let target = revealing, let relative = repository.relativePath(of: target) else { return }
        var node = repository.rootNode
        for part in relative.split(separator: "/") {
            guard let children = node.children else {
                repository.load(node)
                return
            }
            guard let next = children.first(where: { $0.name == String(part) }) else {
                revealing = nil
                return
            }
            if next.isFolder, next.url.standardizedFileURL != target {
                outline.expandItem(next)
                if next.children == nil {
                    repository.load(next)
                    return
                }
            }
            node = next
        }
        revealing = nil
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    func collapseAll() {
        outline.collapseItem(nil, collapseChildren: true)
    }

    // MARK: Changing files

    /// File › New File… (⌥⌘N) and New Folder: made at once as "untitled" (numbered if taken), its name
    /// selected for typing; a file opens once named.
    func makeNew(folder isFolder: Bool) {
        let parent = targetFolder
        let base = isFolder ? String(localized: "untitled folder") : String(localized: "untitled")
        var url = parent.url.appendingPathComponent(base, isDirectory: isFolder)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.url.appendingPathComponent("\(base) \(number)", isDirectory: isFolder)
            number += 1
        }
        do {
            if isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            return present(error)
        }
        fresh = url
        if parent !== repository.rootNode, !outline.isItemExpanded(parent) { outline.expandItem(parent) }
        repository.load(parent)
    }

    /// Return on a row, or Rename…: the name becomes editable in place.
    func beginRename(row: Int? = nil, fresh: URL? = nil) {
        let row = row ?? outline.selectedRow
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell, let field = cell.textField else { return }
        cell.renamingFresh = fresh
        field.isEditable = true
        field.isSelectable = true
        window?.makeFirstResponder(field)
        // The name without its extension is selected, as Finder does.
        if let editor = field.currentEditor() {
            let name = field.stringValue as NSString
            let dot = name.range(of: ".", options: .backwards)
            let isFolder = (outline.item(atRow: row) as? FileNode)?.isFolder ?? false
            editor.selectedRange = NSRange(location: 0, length: !isFolder && dot.location != NSNotFound && dot.location > 0 ? dot.location : name.length)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField {
            // Esc puts the old name back.
            let row = outline.row(for: field)
            if row >= 0 { field.stringValue = node(outline.item(atRow: row)).name }
            window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.isEditable = false
        let row = outline.row(for: field)
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell
        let fresh = cell?.renamingFresh
        cell?.renamingFresh = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { window?.makeFirstResponder(outline) }
        guard !name.isEmpty, !name.contains("/"), name != node.name else {
            field.stringValue = node.name
            if let fresh, !node.isFolder { workbench.open(file: fresh.path, mode: .keep) }
            return
        }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: node.isFolder)
        do {
            try FileManager.default.moveItem(at: node.url, to: destination)
            workbench.files.moved(from: node.url, to: destination)
            retitlePages(from: node.url, to: destination)
            if let parent = node.parent { repository.load(parent) }
            revealing = destination
            if fresh != nil, !node.isFolder { workbench.open(file: destination.path, mode: .keep) }
        } catch {
            field.stringValue = node.name
            present(error)
        }
    }

    /// Tabs showing a moved file now name it by its new name and path.
    private func retitlePages(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path, newPath = new.standardizedFileURL.path
        for (id, page) in workbench.pages {
            let path = page.path
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { continue }
            let moved = newPath + path.dropFirst(oldPath.count)
            switch page {
            case .file: workbench.pages[id] = .file(path: moved)
            case .changes(_, let staged): workbench.pages[id] = .changes(path: moved, staged: staged)
            }
        }
        workbench.scheduleSave()
    }

    /// ⌘⌫, Move to Trash: as Finder does it, without asking (the Trash keeps them).
    func trashSelection() {
        let urls = selectedNodes.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.present(error) }
        }
    }

    func copyPaths(relative: Bool) {
        let paths = selectedNodes.map { relative ? ($0.relativePath.isEmpty ? "." : $0.relativePath) : $0.url.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private func present(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The row right-clicked joins the selection, or replaces it when it was not part of it.
        let clicked = outline.clickedRow
        if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) { outline.selectRowIndexes([clicked], byExtendingSelection: false) }
        let nodes = selectedNodes
        let files = nodes.filter { !$0.isFolder }
        if !files.isEmpty {
            menu.addItem(closureMenuItem(title: String(localized: "Open")) { [weak self] in self?.openSelection() })
            menu.addItem(closureMenuItem(title: String(localized: "Open to the Side")) { [weak self] in
                guard let self else { return }
                for file in files { self.workbench.open(file: file.url.path, mode: .beside) }
            })
            if files.count == 1, let repository = Optional(repository), let relative = repository.relativePath(of: files[0].url),
               let state = repository.status?.decorations[relative], state != .untracked {
                menu.addItem(closureMenuItem(title: String(localized: "Open Changes")) { [weak self] in
                    self?.workbench.openChanges(path: files[0].url.path, staged: false, mode: .keep)
                })
            }
            menu.addItem(.separator())
        }
        if !nodes.isEmpty {
            menu.addItem(closureMenuItem(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(nodes.map(\.url)) })
            if files.count == 1 {
                menu.addItem(closureMenuItem(title: String(localized: "Open with Default App")) { NSWorkspace.shared.open(files[0].url) })
            }
            menu.addItem(closureMenuItem(title: String(localized: "Copy Path")) { [weak self] in self?.copyPaths(relative: false) })
            menu.addItem(closureMenuItem(title: String(localized: "Copy Relative Path")) { [weak self] in self?.copyPaths(relative: true) })
            menu.addItem(.separator())
        }
        menu.addItem(closureMenuItem(title: String(localized: "New File…")) { [weak self] in self?.makeNew(folder: false) })
        menu.addItem(closureMenuItem(title: String(localized: "New Folder")) { [weak self] in self?.makeNew(folder: true) })
        menu.addItem(closureMenuItem(title: String(localized: "Collapse All Folders")) { [weak self] in self?.collapseAll() })
        if nodes.count == 1 {
            menu.addItem(.separator())
            menu.addItem(closureMenuItem(title: String(localized: "Rename…")) { [weak self] in self?.beginRename() })
        }
        if !nodes.isEmpty {
            if nodes.count != 1 { menu.addItem(.separator()) }
            menu.addItem(closureMenuItem(title: String(localized: "Move to Trash")) { [weak self] in self?.trashSelection() })
        }
    }

    // MARK: Quick Look

    var previewURLs: [URL] { selectedNodes.map(\.url) }
}

/// The outline itself: its keys (Return renames, ⌘↓ opens, ⌘⌫ trashes, Space is Quick Look) and the
/// Quick Look panel's data.
final class FileOutline: NSOutlineView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var tree: FileTreeView?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (36, []), (76, []):
            tree?.beginRename()
        case (125, .command), (125, [.command, .numericPad, .function]):
            tree?.openSelection()
        case (51, .command):
            tree?.trashSelection()
        case (49, []):
            togglePreviewPanel()
        default:
            super.keyDown(with: event)
        }
    }

    private func togglePreviewPanel() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { tree?.previewURLs.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        tree?.previewURLs[index] as NSURL?
    }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }
}

/// A row's selection: a soft rounded fill, the accent's when the tree has the keyboard.
private final class FileRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 1)
        let focused = window?.firstResponder === superview && window?.isKeyWindow == true
        (focused ? NSColor.controlAccentColor.withAlphaComponent(0.22) : Colors.line.withAlphaComponent(0.9)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// One file or folder: its symbol, its name, and its git state's letter (or a dot on a folder holding
/// changes); faint when git ignores it.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    /// A name being typed for a file just made (it opens once named).
    var renamingFresh: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyDown
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12.5)
        name.cell?.isScrollable = false
        name.isEditable = false
        name.focusRingType = .none
        badge.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        badge.alignment = .right
        for view in [icon, name, badge] { addSubview(view) }
        textField = name
        imageView = icon
    }

    /// Laid out by hand: a folder of thousands of rows makes many cells, and frames cost far less than
    /// constraints.
    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 2, y: (height - 16) / 2, width: 16, height: 16)
        let badgeWidth = badge.stringValue.isEmpty ? 0 : max(10, badge.intrinsicContentSize.width)
        badge.frame = NSRect(x: bounds.width - 12 - badgeWidth, y: (height - badge.intrinsicContentSize.height) / 2, width: badgeWidth, height: badge.intrinsicContentSize.height)
        let nameHeight = name.intrinsicContentSize.height
        let nameRight = badgeWidth > 0 ? badge.frame.minX - 6 : bounds.width - 12
        name.frame = NSRect(x: 24, y: (height - nameHeight) / 2, width: max(0, nameRight - 24), height: nameHeight)
    }

    required init?(coder: NSCoder) {
        fatalError("FileCell is created in code")
    }

    /// Symbols are made once each: a folder of thousands of files shows a handful of kinds.
    private static var images: [String: NSImage] = [:]

    private static func image(_ symbol: String) -> NSImage? {
        if let image = images[symbol] { return image }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        images[symbol] = image
        return image
    }

    func show(_ node: FileNode, repository: Repository) {
        let status = repository.status
        let ignored = status?.isIgnored(node.isFolder ? node.relativePath + "/" : node.relativePath) ?? false || (status?.isIgnored(node.relativePath) ?? false)
        let state = node.isFolder ? status?.folderDecorations[node.relativePath] : status?.decorations[node.relativePath]
        icon.image = Self.image(FileIcon.symbol(for: node.name, folder: node.isFolder))
        icon.contentTintColor = node.isFolder ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor(Color.ink2)
        if name.currentEditor() == nil { name.stringValue = node.name }
        name.textColor = NSColor(Color.ink)
        if let state {
            badge.stringValue = node.isFolder ? "•" : state.letter
            badge.textColor = GitColors.color(state)
            badge.font = node.isFolder ? .systemFont(ofSize: 13, weight: .bold) : .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
            if !node.isFolder { name.textColor = GitColors.color(state) }
        } else {
            badge.stringValue = ""
        }
        needsLayout = true
        alphaValue = ignored ? 0.45 : 1
        var label = node.name
        if let state, !node.isFolder { label += ", " + GitColors.name(state) }
        if node.isFolder, state != nil { label += ", " + String(localized: "has changes") }
        if ignored { label += ", " + GitColors.name(.ignored) }
        setAccessibilityLabel(label)
        badge.setAccessibilityElement(false)
        icon.setAccessibilityElement(false)
    }
}

