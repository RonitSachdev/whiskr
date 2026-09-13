import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskrKit

/// The current workspace's tabs, in the row under the top bar over the work area (docs/DESIGN.md), in
/// the chrome's colour with the selected tab in the terminal's own, so it reads as the top of the
/// terminal below.
///
/// It begins with the workspace these tabs belong to: its blanket's colour and name, a button whose menu
/// lists Home and every open workspace (each one click away, ⌥⌘1…9), so opening another never looks as if
/// this one had closed. Then each tab: its state mark, its title, a close button on hover at its leading
/// edge, and the to-do progress of a Claude in it; "+" at the end, as Safari, Terminal and herdr have it.
/// On Home the row stays, calm: "Home" where the workspace button sits, with the same menu, and no tabs.
///
/// Clicks are AppKit's, not SwiftUI tap gestures: a tab is chosen the moment the button goes down (as
/// in Safari), a second click renames it, and the close button closes at once (a double-tap gesture
/// would hold every single click back by the double-click interval). Tabs drag to a new place, or onto
/// another workspace's blanket.
struct TabStrip: View {
    let workbench: Workbench
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 4) {
            if let workspace = workbench.selectedWorkspace {
                WorkspaceButton(workbench: workbench, workspace: workspace)
                    .padding(.trailing, 4)
                ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabButton(workbench: workbench, tab: tab, index: index, selected: workspace.selectedTab === tab)
                        .onDrop(of: [TabDrag.type], delegate: TabDropTarget(workbench: workbench, workspace: workspace, index: index))
                        .transition(.opacity)
                }
                NewTabButton { workbench.newTab() }
                    .onDrop(of: [TabDrag.type], delegate: TabDropTarget(workbench: workbench, workspace: workspace, index: workspace.tabs.count))
            } else {
                HomeButton(workbench: workbench)
            }
            EmptyStretch { workbench.newTab() }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .chromeBackground()
        .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: workbench.selectedWorkspace?.tabs.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tabs", comment: "Accessibility label of the tab strip"))
    }
}

/// The stretch of the row with nothing on it: a double-click opens a tab, as in Safari and Terminal.
private struct EmptyStretch: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> StretchView { StretchView() }

    func updateNSView(_ view: StretchView, context: Context) {
        view.onDoubleClick = onDoubleClick
    }

    final class StretchView: NSView {
        var onDoubleClick: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick() }
        }
    }
}

/// Where the workspace button sits while on Home: a house and "Home", whose menu is the workspace
/// button's (Home, then every open workspace).
private struct HomeButton: View {
    let workbench: Workbench
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "house")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ink2)
            Text(String(localized: "Home", comment: "The tab row's place name while on Home"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink)
            if !workbench.workspaces.isEmpty {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.ink3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .background(MenuAnchor(menu: { WorkspaceMenu.make(workbench: workbench) }))
        .onHover { hovering = $0 }
        .help(String(localized: "Home: every open workspace is in this menu (⌥⌘1…9) and in the meadow"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Home", comment: "The tab row's place name while on Home"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Shows every open workspace"))
    }
}

/// The workspace these tabs belong to, in its blanket's colour; its menu lists every open workspace.
/// Double-click (or Rename Workspace…) edits its name in place.
private struct WorkspaceButton: View {
    let workbench: Workbench
    let workspace: Workspace
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        let count = workbench.workspaces.count
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Colors.accountColor(index: workspace.colorIndex))
                .frame(width: 10, height: 10)
            if workbench.renamingWorkspaceID == workspace.id {
                TextField(String(localized: "Workspace name"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 80, maxWidth: 180)
                    .focused($editing)
                    .onSubmit { commit() }
                    .onExitCommand { workbench.renamingWorkspaceID = nil }
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                    .onAppear {
                        draft = workspace.customName ?? workspace.name
                        editing = true
                    }
            } else {
                // The name itself is in the top bar's field; here only which of how many.
                if count > 1 {
                    Text("\(index + 1)/\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.ink3)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.ink3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .background(MenuAnchor(menu: { WorkspaceMenu.make(workbench: workbench) }, onDoubleClick: { workbench.renamingWorkspaceID = workspace.id }))
        .onHover { hovering = $0 }
        .help(String(localized: "\(workspace.displayPath): every open workspace is in this menu (⌥⌘1…9) and in the meadow"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Workspace \(workspace.name), \(index + 1) of \(count)", comment: "Accessibility: the tab bar's workspace button"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Shows every open workspace"))
    }

    private var index: Int { workbench.workspaces.firstIndex { $0 === workspace } ?? 0 }

    private func commit() {
        guard workbench.renamingWorkspaceID == workspace.id else { return }
        workbench.rename(workspace: workspace, to: draft)
        workbench.renamingWorkspaceID = nil
    }
}

/// The workspaces menu: Home, then every open workspace (colour, name, where and which branch, a count
/// of its requests, ⌥⌘ and its number), then New Workspace, Go to…, Rename and Close.
enum WorkspaceMenu {
    static func make(workbench: Workbench) -> NSMenu {
        let menu = NSMenu()
        let home = closureMenuItem(title: String(localized: "Home", comment: "Go menu and the workspace menu: no workspace selected")) { workbench.goHome() }
        home.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        home.keyEquivalent = "h"
        home.keyEquivalentModifierMask = [.command, .shift]
        home.state = workbench.isHome ? .on : .off
        menu.addItem(home)
        if !workbench.workspaces.isEmpty { menu.addItem(.separator()) }
        for (index, workspace) in workbench.workspaces.enumerated() {
            let item = closureMenuItem(title: workspace.name) { workbench.select(workspace: workspace) }
            item.image = swatch(workspace.colorIndex)
            item.subtitle = [workspace.displayPath, workspace.branch.map { "⑂ \($0)" }].compactMap { $0 }.joined(separator: " · ")
            item.state = workspace === workbench.selectedWorkspace ? .on : .off
            if index < 9 {
                item.keyEquivalent = "\(index + 1)"
                item.keyEquivalentModifierMask = [.command, .option]
            }
            let waiting = workbench.agentRows.filter { $0.workspaceID == workspace.id && $0.status == .blocked }.count
            if waiting > 0 { item.badge = NSMenuItemBadge(count: waiting) }
            // A worktree sits under its repository.
            let nested = workbench.repositoryWorkspace(of: workspace) != nil
            if nested { item.indentationLevel = 1 }
            menu.addItem(item)
            // Terminals its Claudes started with no tab of their own: one click to look at them.
            for helper in workbench.looseHelpers(in: workspace) {
                let entry = closureMenuItem(title: workbench.name(of: helper)) { workbench.selectPane(helper.id) }
                entry.image = NSImage(systemSymbolName: "pawprint", accessibilityDescription: String(localized: "Helper terminal"))
                entry.subtitle = [helper.address, helper.terminalName].compactMap { $0 }.joined(separator: " · ")
                entry.indentationLevel = nested ? 2 : 1
                if workbench.status(of: helper) == .blocked { entry.badge = NSMenuItemBadge(count: 1) }
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "New Workspace"), #selector(MainWindowController.newWorkspace(_:)), "n", [.command]))
        menu.addItem(actionItem(String(localized: "Go to…"), #selector(MainWindowController.goTo(_:)), "p", [.command]))
        guard let selected = workbench.selectedWorkspace else { return menu }
        if workbench.repositoryRoot(of: selected) != nil {
            menu.addItem(.separator())
            menu.addItem(actionItem(String(localized: "New Worktree…"), #selector(MainWindowController.newWorktree(_:)), "n", [.command, .shift]))
            menu.addItem(actionItem(String(localized: "Open Worktree…"), #selector(MainWindowController.openWorktree(_:)), "", []))
            if selected.git?.isWorktree == true {
                menu.addItem(actionItem(String(localized: "Remove Worktree…"), #selector(MainWindowController.removeWorktree(_:)), "", []))
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "Rename Workspace…"), #selector(MainWindowController.renameWorkspace(_:)), "", []))
        menu.addItem(actionItem(String(localized: "Close Workspace"), #selector(MainWindowController.closeWorkspace(_:)), "", []))
        return menu
    }

    private static func actionItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// The blanket's colour as a small rounded square, for menus.
    static func swatch(_ colorIndex: Int) -> NSImage {
        let color = NSColor(Colors.accountColor(index: colorIndex))
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }
}

/// Pops a menu under the view it backs when clicked (and calls `onDoubleClick` on a second click).
struct MenuAnchor: NSViewRepresentable {
    let menu: () -> NSMenu
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.menu = nil
        view.makeMenu = menu
        view.onDoubleClick = onDoubleClick
    }

    final class AnchorView: NSView {
        var makeMenu: () -> NSMenu = { NSMenu() }
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick { return onDoubleClick() }
            makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        }

        override var isFlipped: Bool { true }
    }
}

private struct NewTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "New Tab (⌘T)"))
        .accessibilityLabel(String(localized: "New Tab"))
    }
}

private struct TabButton: View {
    let workbench: Workbench
    let tab: Tab
    let index: Int
    let selected: Bool
    @State private var hovering = false
    @State private var draft = ""
    @State private var showingTasks = false
    @FocusState private var editing: Bool

    var body: some View {
        let renaming = workbench.renamingTabID == tab.id
        let status = workbench.status(of: tab)
        let failed = tab.tree.panes.compactMap { workbench.panes[$0] }.contains { workbench.session(of: $0)?.failed ?? false }
        let pinned = tab.tree.panes.contains(where: workbench.pinnedPanes.contains)
        let edited = workbench.hasEditedFile(in: tab)
        let preview = workbench.isPreview(tab)
        let page = workbench.pages[tab.focusedPane]
        HStack(spacing: 6) {
            // Drawn here, clicked through `TabMouse`, which closes the moment the button goes down. A file
            // with unsaved changes shows a dot in its place until the pointer comes, as Xcode and Safari do.
            ZStack {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
                if edited && !hovering {
                    Circle().fill(Color.ink2).frame(width: 7, height: 7)
                }
            }
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .accessibilityHidden(true)
            if let status { StateMark(status: status, failed: failed) }
            if let page {
                Image(systemName: page.isDiff ? "arrow.left.arrow.right" : FileIcon.symbol(for: page.title, folder: false))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ink3)
                    .accessibilityHidden(true)
            }
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.ink3).rotationEffect(.degrees(30))
                    .accessibilityLabel(String(localized: "Pinned"))
            }
            if renaming {
                TextField(String(localized: "Tab name"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 80, maxWidth: 180)
                    .focused($editing)
                    .onSubmit { commit() }
                    .onExitCommand { workbench.renamingTabID = nil }
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                    .onAppear {
                        draft = workbench.title(of: tab)
                        editing = true
                    }
            } else {
                Text(workbench.title(of: tab))
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .italic(preview)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let progress = progress {
                Button { showingTasks.toggle() } label: {
                    ProgressMark(done: progress.done, total: progress.total)
                }
                .buttonStyle(.plain)
                .help(String(localized: "To-do list: \(progress.done) of \(progress.total) done"))
                .popover(isPresented: $showingTasks, arrowEdge: .bottom) { TaskList(tasks: tasks) }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .frame(minWidth: 56, idealWidth: 180, maxWidth: 220, minHeight: 26, maxHeight: 26)
        .background(TabMouse(tab: tab.id, select: { workbench.select(tab: tab) }, close: { workbench.requestClose(tab: tab) },
                             rename: {
                                 // A second click on a preview keeps it (as in Xcode); on any other tab it renames.
                                 if workbench.isPreview(tab) { workbench.keep(page: tab.focusedPane) } else { workbench.renamingTabID = tab.id }
                             }, menu: { TabMenu.make(workbench: workbench, tab: tab) }))
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color(nsColor: Colors.terminalBackground) : hovering ? Color.primary.opacity(0.06) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(selected ? 0.1 : 0)))
        .onHover { hovering = $0 }
        .help(index < 8 ? String(localized: "\(workbench.title(of: tab)) (⌘\(index + 1))") : workbench.title(of: tab))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility(status: status, failed: failed, pinned: pinned))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { workbench.select(tab: tab) }
        .accessibilityAction(named: String(localized: "Close Tab")) { workbench.requestClose(tab: tab) }

        .accessibilityAction(named: String(localized: "Rename Tab…")) { workbench.renamingTabID = tab.id }
    }

    /// The to-do list of the first Claude in the tab, when it keeps one.
    private var tasks: [TaskItem] {
        for pane in tab.tree.panes.compactMap({ workbench.panes[$0] }) {
            if let session = workbench.session(of: pane), let detail = workbench.monitor.details[session.id], !detail.tasks.isEmpty {
                return detail.tasks
            }
        }
        return []
    }

    private var progress: TaskProgress? {
        let tasks = tasks
        guard !tasks.isEmpty else { return nil }
        return TaskProgress(done: tasks.filter { $0.state == .completed }.count, total: tasks.count)
    }

    private func accessibility(status: AgentStatus?, failed: Bool, pinned: Bool) -> String {
        var parts = [String(localized: "Tab \(index + 1), \(workbench.title(of: tab))", comment: "Accessibility: a tab's number and title")]
        if let status, status == .blocked || status == .done { parts.append(failed ? String(localized: "Error") : status.label) }
        if pinned { parts.append(String(localized: "Pinned")) }
        if workbench.hasEditedFile(in: tab) { parts.append(String(localized: "Edited")) }
        if workbench.isPreview(tab) { parts.append(String(localized: "Preview")) }
        return parts.joined(separator: ", ")
    }

    private func commit() {
        guard workbench.renamingTabID == tab.id else { return }
        workbench.rename(tab: tab, to: draft)
        workbench.renamingTabID = nil
    }
}

/// A tab's right-click menu (§3): Rename Tab…, Move to Workspace ▸, Pin, Mark as Unread, Close Tab,
/// Close Other Tabs.
enum TabMenu {
    static func make(workbench: Workbench, tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(closureMenuItem(title: String(localized: "Rename Tab…")) { workbench.renamingTabID = tab.id })
        let move = NSMenuItem(title: String(localized: "Move to Workspace"), action: nil, keyEquivalent: "")
        let targets = NSMenu()
        for workspace in workbench.workspaces where !workspace.tabs.contains(where: { $0 === tab }) {
            let item = closureMenuItem(title: workspace.name) { workbench.move(tab: tab, to: workspace) }
            item.image = WorkspaceMenu.swatch(workspace.colorIndex)
            targets.addItem(item)
        }
        move.submenu = targets
        move.isEnabled = targets.numberOfItems > 0
        menu.addItem(move)
        menu.autoenablesItems = false
        let claude = tab.tree.panes.first { workbench.panes[$0]?.agentRunning ?? false }
        if let claude {
            menu.addItem(.separator())
            let pinned = workbench.pinnedPanes.contains(claude)
            menu.addItem(closureMenuItem(title: pinned ? String(localized: "Unpin Claude") : String(localized: "Pin Claude")) { workbench.togglePin(pane: claude) })
            let unread = closureMenuItem(title: String(localized: "Mark as Unread")) { workbench.markUnread(pane: claude) }
            unread.isEnabled = workbench.canMarkUnread(pane: claude)
            menu.addItem(unread)
        }
        if let path = workbench.pages[tab.focusedPane]?.path {
            menu.addItem(.separator())
            if workbench.isPreview(tab) {
                menu.addItem(closureMenuItem(title: String(localized: "Keep Open")) { workbench.keep(page: tab.focusedPane) })
            }
            menu.addItem(closureMenuItem(title: String(localized: "Reveal in Files")) { workbench.revealInFiles(path: path) })
            menu.addItem(closureMenuItem(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
            menu.addItem(closureMenuItem(title: String(localized: "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            })
        }
        menu.addItem(.separator())
        menu.addItem(closureMenuItem(title: String(localized: "Close Tab")) { workbench.requestClose(tab: tab) })
        let others = closureMenuItem(title: String(localized: "Close Other Tabs")) {
            workbench.requestClose(tabs: (workbench.workspaces.first { $0.tabs.contains { $0 === tab } }?.tabs ?? []).filter { $0 !== tab })
        }
        others.isEnabled = (workbench.workspaces.first { $0.tabs.contains { $0 === tab } }?.tabs.count ?? 0) > 1
        menu.addItem(others)
        return menu
    }
}

/// What a tab being dragged carries, and which tab it is while the drag lasts (the drag starts and ends
/// in this app, so the tab is known without reading the pasteboard back).
enum TabDrag {
    static let type = UTType(exportedAs: "app.whiskr.tab")
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
    @MainActor static var current: UUID?
}

/// The mouse on a tab, in AppKit: chosen on mouse down, renamed on a second click, dragged after a few
/// points of movement, its menu on a right click.
private struct TabMouse: NSViewRepresentable {
    let tab: UUID
    let select: () -> Void
    let close: () -> Void
    let rename: () -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> TabMouseView { TabMouseView() }

    func updateNSView(_ view: TabMouseView, context: Context) {
        view.tab = tab
        view.onSelect = select
        view.onClose = close
        view.onRename = rename
        view.makeMenu = menu
    }
}

final class TabMouseView: NSView, NSDraggingSource {
    var tab = UUID()
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var onRename: () -> Void = {}
    var makeMenu: () -> NSMenu = { NSMenu() }
    private var downAt: NSPoint?

    /// The close button's reach at the tab's leading edge (its 16 pt circle and a little round it).
    static let closeReach: CGFloat = 24

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < Self.closeReach { return onClose() }
        downAt = event.locationInWindow
        if event.clickCount == 2 { onRename() } else { onSelect() }
    }

    /// The close button's tooltip, over the button.
    override func layout() {
        super.layout()
        removeAllToolTips()
        addToolTip(NSRect(x: 0, y: 0, width: Self.closeReach, height: bounds.height),
                   owner: String(localized: "Close Tab (⌥⌘W)") as NSString, userData: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        downAt = nil
        let item = NSPasteboardItem()
        item.setString(tab.uuidString, forType: TabDrag.pasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // The tab itself follows the pointer: its picture, taken from the bar.
        let frame = bounds
        if let host = superview, let rep = host.bitmapImageRepForCachingDisplay(in: convert(frame, to: host)) {
            host.cacheDisplay(in: convert(frame, to: host), to: rep)
            let image = NSImage(size: frame.size)
            image.addRepresentation(rep)
            dragging.setDraggingFrame(frame, contents: image)
        } else {
            dragging.setDraggingFrame(frame, contents: nil)
        }
        TabDrag.current = tab
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        downAt = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect()
        return makeMenu()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        TabDrag.current = nil
    }
}

/// Dragging a tab along the bar moves it as you go, as Safari does.
private struct TabDropTarget: DropDelegate {
    let workbench: Workbench
    let workspace: Workspace
    let index: Int

    func validateDrop(info: DropInfo) -> Bool { TabDrag.current != nil }

    func dropEntered(info: DropInfo) {
        guard let id = TabDrag.current, let from = workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
        // Entering a tab to the right puts the dragged one after it; to the left, before it.
        workbench.move(tab: workspace.tabs[from], toIndex: index > from ? index + 1 : index)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool { TabDrag.current != nil }
}

/// A small ring filled as far as the to-do list is done.
private struct ProgressMark: View {
    let done: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(done) / CGFloat(max(total, 1)))
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(String(localized: "\(done) of \(total) to-dos done"))
    }
}

/// The to-do list, short and read-only.
private struct TaskList: View {
    let tasks: [TaskItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: task.state == .completed ? "checkmark.circle.fill" : task.state == .inProgress ? "circle.dotted" : "circle")
                        .foregroundStyle(task.state == .completed ? Color.secondary : Color.primary)
                    Text(task.state == .inProgress && !task.activeForm.isEmpty ? task.activeForm : task.subject)
                        .foregroundStyle(task.state == .completed ? .secondary : .primary)
                        .strikethrough(task.state == .completed)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(minWidth: 220, maxWidth: 360, alignment: .leading)
    }
}
