import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskrKit

/// The current workspace's tabs, in the row under the top bar over the work area (docs/DESIGN.md), as
/// Cursor's and Xcode's: the row in the chrome's colour with a line along its foot, each tab a flush
/// cell with a line after it, and the selected tab in the content's colour, open at the bottom into
/// its panes, with the focus line along its top. Tabs share the row up to `maxTab` each; below
/// `minTab` they stop shrinking and the row shows those around the selected tab (`TabCells`).
///
/// It begins with the workspace these tabs belong to: its blanket's colour and name, a button whose menu
/// lists Home and every open workspace (each one click away, ⌥⌘1…9), so opening another never looks as if
/// this one had closed. Each tab shows what it is (a terminal, a file, changes; a Claude's state mark in
/// its place), its title, and a close button at its end: always on the selected tab, on the others under
/// the pointer, a dot instead while a file is unsaved. "+" stays at the end of the row. The row's empty
/// stretch is the window's (it drags, and a double-click does what Desktop & Dock says a title bar's
/// does) and never opens a tab. On Home the row stays, calm: "Home" where the workspace button sits, with
/// the same menu, and no tabs.
///
/// Clicks are AppKit's, not SwiftUI tap gestures: a tab is chosen the moment the button goes down (as
/// in Safari), a second click renames it, the close button closes at once, and a middle click closes
/// too (a double-tap gesture would hold every single click back by the double-click interval). Tabs
/// drag to a new place, or onto another workspace's blanket.
struct TabStrip: View {
    let workbench: Workbench

    static let height = Look.Height.tabRow
    static let minTab: CGFloat = 128
    static let maxTab: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let workspace = workbench.selectedWorkspace {
                    WorkspaceButton(workbench: workbench, workspace: workspace)
                } else {
                    HomeButton(workbench: workbench)
                }
            }
            .padding(.horizontal, Look.Space.s)
            if let workspace = workbench.selectedWorkspace {
                Color.line.frame(width: 1)
                TabCells(workbench: workbench, workspace: workspace)
                NewTabButton { workbench.newTab() }
                    .padding(.horizontal, Look.Space.xs)
                    // The room round "+" moves the window, as the rest of the row's empty stretch does.
                    .background(WindowDragArea())
                    .onDrop(of: [TabDrag.type], delegate: TabDropTarget(workbench: workbench, workspace: workspace, index: workspace.tabs.count))
            } else {
                WindowDragArea()
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        // In a window that is not the one in use, the first click acts as well as bringing it forward, on
        // every control of the row as on its tabs (`TabMouseView`), as the top bar and the status bar do.
        .allowsWindowActivationEvents()
        // The line along the foot is under the tabs: the selected one covers it and opens into its panes.
        .background(alignment: .bottom) { Color.line.frame(height: 1) }
        .chromeBackground()
        // Tabs move (`TabCells`), but only their pictures: where a click lands is where the tabs end up, at
        // once, so a closed tab is never under the pointer for the next click (an earlier fade left it
        // there, unclickable, and took the click).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tabs", comment: "Accessibility label of the tab strip"))
    }
}

/// The tabs themselves (`TabRowLayout`): equal shares of the room up to `TabStrip.maxTab`; when even
/// `minTab` each will not fit them all, as many as fit, a run that always holds the selected tab whole,
/// and the list of every tab after them. No scrolling: every tab in sight is wholly there, its close
/// button in reach, and every click is AppKit's (`TabMouse`). The stretch after the tabs belongs to the
/// window, as the top bar's empty stretches do: it moves the window, and a double-click does what a title
/// bar's does. It never opens a tab.
///
/// The row is drawn twice over the same places (docs/DESIGN.md, "Motion of the interface"). Underneath,
/// where clicks and drops land (`TabHit`): every tab at its new place the moment the tabs change, never
/// animated, so a click goes to the tab that is there now and a closed tab takes none. On top, what you
/// see (`TabButton`, which takes no click but its own to-do button's): the same tabs easing into those
/// places at `Look.Motion.standard`, a new one opening out from its leading edge, a closed one folding
/// into it as its neighbour slides over, and the selected tab's fill and line moving across at
/// `Look.Motion.quick`. With Reduce Motion the pictures are where the tabs are, at once.
private struct TabCells: View {
    let workbench: Workbench
    let workspace: Workspace
    /// Where the run of tabs began last time: it moves only when the selected tab would leave it.
    @State private var start = 0
    /// The tab under the pointer, as AppKit follows it (`TabMouseView`).
    @State private var hovered: UUID?
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What moves the tabs' pictures when it changes: which tabs are in sight, in what order, how wide.
    private struct Arrangement: Equatable {
        let tabs: [UUID]
        let width: Double
        let overflowing: Bool
    }

    var body: some View {
        GeometryReader { room in
            let tabs = workspace.tabs
            let selected = tabs.firstIndex { $0 === workspace.selectedTab } ?? 0
            let layout = TabRowLayout(width: Double(room.size.width), tabs: tabs.count, selected: selected, previousStart: start,
                                      minimum: Double(TabStrip.minTab), maximum: Double(TabStrip.maxTab), listWidth: Double(TabListButton.width))
            // Each tab keeps its views by its own id, so a tab opened or closed before it rebuilds nothing.
            let shown = layout.range.map { (index: $0, tab: tabs[$0]) }
            let arrangement = Arrangement(tabs: shown.map(\.tab.id), width: layout.tabWidth, overflowing: layout.overflowing)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(shown, id: \.tab.id) { index, tab in
                        TabHit(workbench: workbench, tab: tab, index: index, selected: workspace.selectedTab === tab, last: tabs.count == 1,
                               hover: { inside in
                                   if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
                               })
                            .frame(width: CGFloat(layout.tabWidth))
                            .onDrop(of: [TabDrag.type], delegate: TabDropTarget(workbench: workbench, workspace: workspace, index: index))
                    }
                    if layout.overflowing { Color.clear.frame(width: TabListButton.width) }
                }
                .transaction { $0.animation = nil }
                HStack(spacing: 0) {
                    ForEach(shown, id: \.tab.id) { index, tab in
                        TabButton(workbench: workbench, tab: tab, index: index, selected: workspace.selectedTab === tab,
                                  hovering: hovered == tab.id, selection: selection)
                            .frame(width: CGFloat(layout.tabWidth))
                            .transition(.tabOpening)
                    }
                    if layout.overflowing {
                        TabListButton(workbench: workbench, workspace: workspace, hidden: tabs.count - layout.count)
                            // It fades in, but goes at once: fading where a tab now is, it would take that tab's
                            // click (`make perf`'s rapid × found it).
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
                // The arrangement's ease wins over the selection's when both change (a new tab chosen).
                .animation(reduceMotion ? nil : Look.Motion.animation(Look.Motion.standard), value: arrangement)
                .animation(reduceMotion ? nil : Look.Motion.animation(Look.Motion.quick), value: workspace.selectedTab?.id)
            }
            .frame(width: room.size.width, alignment: .leading)
            // Never past the row's end, under "+" (`TabRowLayout` keeps within it; this is the guarantee).
            .clipped()
            .background(WindowDragArea())
            .onChange(of: layout.start) { _, value in start = value }
        }
    }
}

private extension AnyTransition {
    /// A tab opening out from its leading edge, or folding into it as it closes: revealed rather than
    /// squeezed, so its title never stretches.
    static var tabOpening: AnyTransition {
        .modifier(active: TabReveal(shown: 0), identity: TabReveal(shown: 1))
    }
}

/// How much of a tab is shown, from its leading edge (`AnyTransition.tabOpening`).
private struct TabReveal: ViewModifier {
    let shown: CGFloat

    func body(content: Content) -> some View {
        content.mask(alignment: .leading) {
            Rectangle().scaleEffect(x: shown, y: 1, anchor: .leading)
        }
    }
}

/// Where the workspace button sits while on Home: a house and "Home", whose menu is the workspace
/// button's (New Workspace and Open Folder…, Home, then every open workspace).
private struct HomeButton: View {
    let workbench: Workbench

    var body: some View {
        PlaceButton(id: "bar.place-home", label: String(localized: "Home", comment: "The tab row's place name while on Home"),
                    help: String(localized: "Home: every open workspace is in this menu (⌥⌘1…9) and in the meadow"),
                    menu: { WorkspaceMenu.make(workbench: workbench) }) {
            Image(systemName: "house")
                .font(Look.smallIcon.weight(.medium))
                .foregroundStyle(Color.ink2)
            Text(String(localized: "Home", comment: "The tab row's place name while on Home"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink)
        }
    }
}

/// The button at the start of the tab row naming the place the tabs belong to, with a chevron saying it
/// opens a menu: a pop-up button, as Xcode's scheme and VS Code's window picker are (`barMenu`).
private struct PlaceButton<Label: View>: View {
    let id: String
    let label: String
    let help: String
    let menu: () -> NSMenu
    var onDoubleClick: (() -> Void)?
    @ViewBuilder let content: Label

    var body: some View {
        HStack(spacing: Look.Space.s) {
            content
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.ink3)
        }
        .padding(.horizontal, Look.Space.m)
        .frame(height: Look.Height.control)
        .barMenu(id, label: label, help: help, hint: String(localized: "Shows every open workspace"), onDoubleClick: onDoubleClick, menu: menu)
    }
}

/// The workspace these tabs belong to: its blanket's colour and name; its menu lists every open
/// workspace. Double-click (or Rename Workspace…) edits its name in place.
private struct WorkspaceButton: View {
    let workbench: Workbench
    let workspace: Workspace
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        if workbench.renamingWorkspaceID == workspace.id {
            // The name in a field where the button was: the field is the control while it lasts.
            HStack(spacing: Look.Space.s) {
                swatch
                TextField(String(localized: "Workspace name"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 80, maxWidth: 180)
                    .focused($editing)
                    .onSubmit { commit() }
                    .onExitCommand {
                        workbench.renamingWorkspaceID = nil
                        editing = false
                    }
                    // The keyboard goes back to the tab once the field has gone, not nowhere.
                    .onDisappear { workbench.returnKeyboardIfLost() }
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                    .onAppear {
                        draft = workspace.customName ?? workspace.name
                        editing = true
                    }
            }
            .padding(.horizontal, Look.Space.m)
            .frame(height: Look.Height.control)
        } else {
            PlaceButton(id: "bar.workspace",
                        label: String(localized: "Workspace \(workspace.name), \(index + 1) of \(workbench.workspaces.count)", comment: "Accessibility: the tab bar's workspace button"),
                        help: String(localized: "\(workspace.displayPath): every open workspace is in this menu (⌥⌘1…9) and in the meadow"),
                        menu: { WorkspaceMenu.make(workbench: workbench) }, onDoubleClick: { workbench.renamingWorkspaceID = workspace.id }) {
                swatch
                Text(workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// The blanket's colour.
    private var swatch: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Colors.accountColor(index: workspace.colorIndex))
            .frame(width: 10, height: 10)
    }

    private var index: Int { workbench.workspaces.firstIndex { $0 === workspace } ?? 0 }

    private func commit() {
        guard workbench.renamingWorkspaceID == workspace.id else { return }
        workbench.rename(workspace: workspace, to: draft)
        workbench.renamingWorkspaceID = nil
        // Let go of the field's focus as it goes: still set, the next rename's field would not take the keyboard.
        editing = false
    }
}

/// The workspaces menu, as the workspace button and Home's button open it: first the ways to open one
/// (New Workspace, Open Folder…); Home and every open workspace (colour, name, where and which branch, a
/// count of its requests, ⌥⌘ and its number, the terminals its Claudes started); the selected workspace's
/// worktrees; Go to…; then Rename and Close for the workspace shown.
enum WorkspaceMenu {
    static func make(workbench: Workbench) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem(String(localized: "New Workspace"), #selector(MainWindowController.newWorkspace(_:)), "n", [.command]))
        menu.addItem(actionItem(String(localized: "Open Folder…"), #selector(MainWindowController.openFolder(_:)), "o", [.command]))
        menu.addItem(.separator())
        let home = closureMenuItem(title: String(localized: "Home", comment: "Go menu and the workspace menu: no workspace selected")) { workbench.goHome() }
        home.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        home.keyEquivalent = "h"
        home.keyEquivalentModifierMask = [.command, .shift]
        home.state = workbench.isHome ? .on : .off
        menu.addItem(home)
        if !workbench.workspaces.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Workspaces", comment: "Sidebar list heading")))
        }
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
        let selected = workbench.selectedWorkspace
        if let selected, workbench.repositoryRoot(of: selected) != nil {
            menu.addItem(.separator())
            menu.addItem(actionItem(String(localized: "New Worktree…"), #selector(MainWindowController.newWorktree(_:)), "n", [.command, .shift]))
            menu.addItem(actionItem(String(localized: "Open Worktree…"), #selector(MainWindowController.openWorktree(_:)), "", []))
            if selected.git?.isWorktree == true {
                menu.addItem(actionItem(String(localized: "Remove Worktree…"), #selector(MainWindowController.removeWorktree(_:)), "", []))
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "Go to…"), #selector(MainWindowController.goTo(_:)), "p", [.command]))
        guard selected != nil else { return menu }
        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "Rename Workspace…"), #selector(MainWindowController.renameWorkspace(_:)), "", []))
        menu.addItem(actionItem(String(localized: "Close Workspace"), #selector(MainWindowController.closeWorkspace(_:)), "", []))
        return menu
    }

    /// An item for an action of the window (its controller takes it, through the responder chain).
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

/// Every tab of the workspace in a menu, for a row too full to show them all: the way to reach a tab
/// out of sight and to read each title whole. Shown only while some tabs are out of sight, with how many.
private struct TabListButton: View {
    let workbench: Workbench
    let workspace: Workspace
    let hidden: Int

    static let width: CGFloat = 32

    var body: some View {
        HStack(spacing: Look.Space.xxs) {
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            Text(verbatim: "\(hidden)").font(.system(size: 11).monospacedDigit())
        }
        .foregroundStyle(Color.ink2)
        .frame(width: Self.width, height: Look.Height.control)
        .barMenu("bar.tabs.all", label: String(localized: "All tabs", comment: "Tab row: the menu listing every tab when they do not fit"),
                 help: String(localized: "All tabs: \(hidden) more out of sight", comment: "Tab row: the menu listing every tab when they do not fit"),
                 value: String(localized: "\(hidden) more out of sight", comment: "Tab row: how many tabs do not fit"), menu: menu)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        for (index, tab) in workspace.tabs.enumerated() {
            let item = closureMenuItem(title: workbench.title(of: tab)) { workbench.select(tab: tab) }
            item.state = workspace.selectedTab === tab ? .on : .off
            if index < 8 {
                item.keyEquivalent = "\(index + 1)"
                item.keyEquivalentModifierMask = .command
            }
            menu.addItem(item)
        }
        return menu
    }
}

private struct NewTabButton: View {
    let action: () -> Void

    var body: some View {
        ChromeIcon(symbol: "plus")
            .barButton("bar.tabs.new", label: String(localized: "New Tab"), help: String(localized: "New Tab (⌘T)"), action: action)
    }
}

/// A tab as you see it (`TabCells` draws it over its `TabHit`): what it is, its title, its close button,
/// and, chosen, the content's fill with the focus line along its top. It takes no click itself (they
/// reach `TabMouse` under it), but its to-do button's and its rename field's.
private struct TabButton: View {
    let workbench: Workbench
    let tab: Tab
    let index: Int
    let selected: Bool
    /// The pointer is on the tab (AppKit's account of it, from `TabMouse`).
    let hovering: Bool
    /// Where the selected tab's fill and line move between tabs.
    let selection: Namespace.ID
    @State private var draft = ""
    @State private var showingTasks = false
    @FocusState private var editing: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let renaming = workbench.renamingTabID == tab.id
        let title = workbench.title(of: tab)
        let tasks = tasks
        let progress = Self.progress(of: tasks)
        let status = workbench.status(of: tab)
        let failed = tab.tree.panes.compactMap { workbench.panes[$0] }.contains { workbench.session(of: $0)?.failed ?? false }
        let pinned = tab.tree.panes.contains(where: workbench.pinnedPanes.contains)
        let edited = workbench.hasEditedFile(in: tab)
        let preview = workbench.isPreview(tab)
        HStack(spacing: Look.Space.s) {
            // What the tab is: a Claude's state when it has one to show, a bell rung out of sight, else a
            // terminal, a file or changes.
            TabKindMark(workbench: workbench, tab: tab, selected: selected)
            .frame(width: 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.ink3).rotationEffect(.degrees(30))
                    .allowsHitTesting(false)
                    .accessibilityLabel(String(localized: "Pinned"))
            }
            if renaming {
                TextField(String(localized: "Tab name"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 60, maxWidth: .infinity)
                    .focused($editing)
                    .onSubmit { commit() }
                    .onExitCommand {
                        workbench.renamingTabID = nil
                        editing = false
                    }
                    // The keyboard goes back to the tab once the field has gone, not nowhere.
                    .onDisappear { workbench.returnKeyboardIfLost() }
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                    .onAppear {
                        draft = title
                        editing = true
                    }
            } else {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .italic(preview)
                    .foregroundStyle(selected ? Color.ink : Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The title takes the room; the close button stays at the end.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
            if let progress {
                Button { showingTasks.toggle() } label: {
                    ProgressMark(done: progress.done, total: progress.total)
                }
                .buttonStyle(.plain)
                .help(String(localized: "To-do list: \(progress.done) of \(progress.total) done"))
                .popover(isPresented: $showingTasks, arrowEdge: .bottom) { TaskList(tasks: tasks) }
            }
            // Drawn here, clicked through `TabMouse`, which closes the moment the button goes down. A file
            // with unsaved changes shows a dot in its place until the pointer comes, as Xcode and VS Code do.
            ZStack {
                if edited && !hovering {
                    Circle().fill(Color.ink2).frame(width: 7, height: 7)
                } else if selected || hovering {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Color.ink : Color.ink2)
                }
            }
            .frame(width: TabMouseView.closeSize, height: TabMouseView.closeSize)
            .background(RoundedRectangle(cornerRadius: Look.Radius.small).fill(hovering ? Look.Fill.hover : .clear))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(.leading, Look.Space.l - 2)
        .padding(.trailing, Look.Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if selected {
                // The content's fill and, where the keys go, the focus line along the top (as the focused
                // pane has): one mark, which moves to the tab chosen.
                Color.content
                    .overlay(alignment: .top) { Look.focusLine(active: activeState.inUse).frame(height: Look.focusLineWidth) }
                    .matchedGeometryEffect(id: "selection", in: selection)
                    // One mark that moves, not two crossing fades.
                    .transition(.identity)
                    .allowsHitTesting(false)
            } else if hovering {
                Look.Fill.hover.allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) { Color.line.frame(width: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility(title: title, status: status, failed: failed, pinned: pinned, edited: edited, preview: preview))
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

    private static func progress(of tasks: [TaskItem]) -> TaskProgress? {
        guard !tasks.isEmpty else { return nil }
        return TaskProgress(done: tasks.filter { $0.state == .completed }.count, total: tasks.count)
    }

    private func accessibility(title: String, status: AgentStatus?, failed: Bool, pinned: Bool, edited: Bool, preview: Bool) -> String {
        var parts = [String(localized: "Tab \(index + 1), \(title)", comment: "Accessibility: a tab's number and title")]
        if let status, status == .blocked || status == .done { parts.append(failed ? String(localized: "Error") : status.label) }
        if workbench.rang(in: tab) { parts.append(String(localized: "Bell", comment: "A terminal rang its bell while out of sight")) }
        if pinned { parts.append(String(localized: "Pinned")) }
        if edited { parts.append(String(localized: "Edited")) }
        if preview { parts.append(String(localized: "Preview")) }
        return parts.joined(separator: ", ")
    }

    private func commit() {
        guard workbench.renamingTabID == tab.id else { return }
        workbench.rename(tab: tab, to: draft)
        workbench.renamingTabID = nil
        // Let go of the field's focus as it goes: still set, the next rename's field would not take the keyboard.
        editing = false
    }
}

/// Where a tab takes its clicks, drags and drops (`TabCells` lays these out under the tabs' pictures, at
/// the tabs' places at once): AppKit's `TabMouse`, and the tab's tooltip. `make perf`'s closing check
/// clicks every part of every tab.
private struct TabHit: View {
    let workbench: Workbench
    let tab: Tab
    let index: Int
    let selected: Bool
    /// The workspace's only tab: closing it closes the workspace and goes Home, which its close button says.
    let last: Bool
    let hover: (Bool) -> Void

    var body: some View {
        let title = workbench.title(of: tab)
        TabMouse(tab: tab.id, last: last, select: { workbench.select(tab: tab) }, close: { workbench.requestClose(tab: tab) },
                 shown: { workbench.selectedTab?.id }, show: { id in
                     // A drag shows the panes it can be dropped beside: those of the tab shown before.
                     if let before = workbench.selectedWorkspace?.tabs.first(where: { $0.id == id }) { workbench.select(tab: before) }
                 },
                 rename: {
                     // A second click on a preview keeps it (as in Xcode); on any other tab it renames.
                     if workbench.isPreview(tab) { workbench.keep(page: tab.focusedPane) } else { workbench.renamingTabID = tab.id }
                 }, menu: { TabMenu.make(workbench: workbench, tab: tab) },
                 // One account of the pointer, AppKit's (in any window, key or not): the close button is drawn
                 // where a click closes, and nowhere else.
                 selected: selected, hover: hover)
            .help(index < 8 ? String(localized: "\(title) (⌘\(index + 1))") : title)
            .accessibilityHidden(true)
    }
}

/// A tab's right-click menu (§3): Rename Tab…, Move to Workspace ▸, Pin, Mark as Unread, Zoom Pane (in
/// a split), Close Tab, Close Other Tabs.
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
        if tab.tree.panes.count > 1 {
            menu.addItem(.separator())
            let zoom = closureMenuItem(title: tab.zoomedPane == nil ? String(localized: "Zoom Pane") : String(localized: "Restore Panes")) {
                workbench.select(tab: tab)
                workbench.toggleZoom()
            }
            zoom.keyEquivalent = "\r"
            zoom.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(zoom)
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

/// The mouse on a tab, in AppKit: chosen on mouse down, renamed on a second click, closed by its close
/// button or a middle click, dragged after a few points of movement, its menu on a right click.
private struct TabMouse: NSViewRepresentable {
    let tab: UUID
    let last: Bool
    let select: () -> Void
    let close: () -> Void
    let shown: () -> UUID?
    let show: (UUID) -> Void
    let rename: () -> Void
    let menu: () -> NSMenu
    let selected: Bool
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> TabMouseView { TabMouseView() }

    func updateNSView(_ view: TabMouseView, context: Context) {
        view.tab = tab
        view.isLast = last
        view.onSelect = select
        view.shownTab = shown
        view.onShow = show
        view.onClose = close
        view.onRename = rename
        view.makeMenu = menu
        view.isSelected = selected
        view.onHover = hover
    }
}

final class TabMouseView: NSView, NSDraggingSource, NSViewToolTipOwner {
    var tab = UUID()
    /// The workspace's only tab: its close button's tooltip says the workspace closes and Home comes.
    var isLast = false {
        didSet { if isLast != oldValue { needsLayout = true } }
    }
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var onRename: () -> Void = {}
    var makeMenu: () -> NSMenu = { NSMenu() }
    var shownTab: () -> UUID? = { nil }
    var onShow: (UUID) -> Void = { _ in }
    /// The close button is drawn on the selected tab, and on another while the pointer is on it.
    var isSelected = false
    var onHover: (Bool) -> Void = { _ in }
    private var isHovered = false {
        didSet { if isHovered != oldValue { onHover(isHovered) } }
    }
    private var hoverArea: NSTrackingArea?
    private var downAt: NSPoint?
    /// The tab shown before this one was pressed: a drag goes back to it, so the tab can be dropped
    /// beside its panes.
    private var shownBefore: UUID?

    /// The close button, drawn by the tab at its trailing end, and its reach: the button and the tab's
    /// padding after it, the row's full height.
    static let closeSize: CGFloat = 20
    static let closeReach: CGFloat = 30

    private var closeRect: NSRect {
        NSRect(x: bounds.width - Self.closeReach, y: 0, width: Self.closeReach, height: bounds.height)
    }

    /// The middle of the close button (where `DebugPerf` clicks it).
    var closePoint: NSPoint { NSPoint(x: closeRect.midX, y: bounds.midY) }

    /// A tab chosen (or closed) in a window that is not the key one takes effect at once, as in Safari
    /// and the Finder: the click is not spent on bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pointer, followed in every window (key or not, the app active or not), so that a first click in
    /// a background window finds the close button exactly where it is drawn. Over the tab's own bounds, set
    /// again whenever they change: inside a hosting view a platform view's visible rectangle can reach far
    /// past it (`.inVisibleRect` then hovered tabs the pointer was not on).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        hoverFromPointer()
    }

    /// The tabs moved under a pointer that did not (one closed and the next took its place): the tab now
    /// under it shows its close button at once, ready for the next click, without waiting for a move. AppKit
    /// sends no entered event for an area that comes under a resting pointer, and does not always ask a view
    /// that only moved to update its areas, so every change of place asks where the pointer is (in any window,
    /// key or not: the tracking is `.activeAlways`, so a first click in a window behind others closes too).
    private func hoverFromPointer() {
        guard let window else { return }
        isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        hoverFromPointer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hoverFromPointer()
    }

    #if DEBUG
    /// Debug builds (`DebugAnimations`): the tab counts the pointer as on it.
    var debugIsHovered: Bool { isHovered }
    #endif


    override func mouseDown(with event: NSEvent) {
        // The close button's reach closes only where the button is drawn; elsewhere the tab is chosen.
        if isSelected || isHovered, closeRect.contains(convert(event.locationInWindow, from: nil)) { return onClose() }
        downAt = event.locationInWindow
        shownBefore = shownTab()
        if event.clickCount == 2 { onRename() } else { onSelect() }
    }

    /// A middle click closes the tab, as in every browser and editor.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() } else { super.otherMouseDown(with: event) }
    }

    /// The close button's tooltip, over the button. The view answers for it itself: AppKit does not keep a
    /// tooltip's owner, and a string handed over as one was gone by the time the tooltip came up (a crash
    /// with the pointer resting on ×).
    override func layout() {
        super.layout()
        removeAllToolTips()
        addToolTip(closeRect, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        isLast
            ? String(localized: "Close Tab (⌥⌘W): the workspace's last tab, so the workspace closes and you go Home", comment: "Tooltip of the close button on a workspace's only tab")
            : String(localized: "Close Tab (⌥⌘W)")
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
        if let before = shownBefore, before != tab { onShow(before) }
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
        // The whole ring is the button, not only its stroke: a click in its middle went to the tab.
        .contentShape(Rectangle())
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
