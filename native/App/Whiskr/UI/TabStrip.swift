import AppKit
import SwiftUI
import WhiskrKit

/// The current workspace's tabs, in the row under the top bar over the work area (docs/DESIGN.md), as
/// Cursor's and Xcode's: the row in the chrome's colour with a line along its foot, each tab a flush
/// cell with a line after it, and the selected tab in the content's colour, open at the bottom into
/// its panes, with the focus line along its top. A tab split into panes is one tab of joined segments, one
/// per pane, as Chrome draws a split view (`TabCells`). "+" follows the last tab.
///
/// It begins with the workspace these tabs belong to: its blanket's colour and name, a button whose menu
/// lists Home and every open workspace (each one click away, ⌥⌘1…9), so opening another never looks as if
/// this one had closed. The row's empty stretch after "+" is the window's (it drags, and a double-click
/// does what Desktop & Dock says a title bar's does) and never opens a tab. On Home the row stays, calm:
/// "Home" where the workspace button sits, with the same menu, and no tabs.
struct TabStrip: View {
    let workbench: Workbench

    static let height = Look.Height.tabRow
    /// A titled segment's least and greatest width (a tab of one pane is one segment).
    static let minTab: CGFloat = 128
    static let maxTab: CGFloat = 220
    /// A segment shown by its icon alone, once the row is too tight for every pane's title.
    static let iconSegment: CGFloat = 36

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
struct TabListButton: View {
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

/// A small ring filled as far as the to-do list is done.
struct ProgressMark: View {
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
struct TaskList: View {
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
