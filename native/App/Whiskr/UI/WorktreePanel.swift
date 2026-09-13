import AppKit
import SwiftUI
import WhiskrKit

/// New Worktree… and Open Worktree… (as herdr has them), as one small panel over the terminals in the palette's
/// style: no form. New is a branch name, offered already (a free friendly name, selected so typing
/// replaces it), and the branch it starts from; Return makes it and opens it. Open lists the repository's
/// checkouts, filtered as you type; Return opens one. Esc, or a click elsewhere, puts it away. Git's own
/// words show calmly in the panel when something fails.
@MainActor
final class WorktreeController: NSObject, NSWindowDelegate {
    static let shared = WorktreeController()

    enum Mode { case create, open }

    private var panel: WorktreePanelWindow?
    private weak var parent: NSWindow?
    private weak var returnFocus: NSResponder?

    /// Shows the panel for `repository` (its main checkout's folder). `opened` runs once a worktree has
    /// been opened from it.
    func show(_ mode: Mode, repository: String, over window: NSWindow, workbench: Workbench, opened: (() -> Void)? = nil) {
        close()
        parent = window
        returnFocus = window.firstResponder
        let model = WorktreeModel(mode: mode, repository: repository, workbench: workbench)
        model.onClose = { [weak self] in self?.close() }
        model.onOpened = { [weak self] in
            self?.close()
            opened?()
        }
        let panel = WorktreePanelWindow(contentRect: NSRect(x: 0, y: 0, width: WorktreeView.width, height: 200),
                                 styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        let host = NSHostingController(rootView: WorktreeView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        place(panel, over: window)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKey()
        self.panel = panel
        if window.isVisible && !DebugPlaces.isBackground { panel.orderFront(nil) }
        model.load()
    }

    /// Centred over the terminals, a fifth of the way down, where the palette shows.
    private func place(_ panel: NSPanel, over window: NSWindow) {
        let terminals = window.contentViewController.flatMap { ($0 as? NSSplitViewController)?.splitViewItems.last?.viewController.view }
        let region = terminals.flatMap { view -> NSRect? in
            guard let host = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return host.convertToScreen(view.convert(view.bounds, to: nil))
        } ?? window.frame
        let size = panel.frame.size
        panel.setFrameTopLeftPoint(NSPoint(x: max(window.frame.minX + 12, region.midX - size.width / 2), y: region.maxY - min(140, region.height * 0.18)))
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let parent, parent.isVisible {
            parent.makeKey()
            if let returnFocus { parent.makeFirstResponder(returnFocus) }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !DebugPlaces.isBackground else { return }
        close()
    }

    /// Debug: the panel as it is, for a snapshot.
    var panelForSnapshot: NSWindow? { panel }
}

/// What the panel shows and does.
@MainActor @Observable
final class WorktreeModel {
    let mode: WorktreeController.Mode
    let repository: String
    @ObservationIgnored private let workbench: Workbench
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onOpened: () -> Void = {}

    /// New: the branch to make (or check out), and the one to start from.
    var branch = ""
    var base: String?
    private(set) var branches: [String] = []
    /// Open: the checkouts, and what is typed to filter them.
    private(set) var checkouts: [Worktree] = []
    var filter = ""
    var highlighted: String?
    private(set) var busy = false
    /// What went wrong, in git's words.
    private(set) var problem: String?

    init(mode: WorktreeController.Mode, repository: String, workbench: Workbench) {
        self.mode = mode
        self.repository = repository
        self.workbench = workbench
    }

    var repositoryName: String { URL(fileURLWithPath: repository).lastPathComponent }

    /// Where the new worktree will go, as it will be shown.
    var destination: String {
        let name = branch.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "" }
        return abbreviatingHome(Workbench.worktreePath(repository: repository, branch: name).path)
    }

    /// Reads the branches (and checkouts) off the main thread.
    func load() {
        let repository = repository
        busy = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> (branches: [String], current: String?, checkouts: [Worktree], problem: String?) in
                let git = GitRunner()
                do throws(GitError) {
                    let branches = try Worktrees.localBranches(repository: repository, git: git)
                    let current = try Worktrees.currentBranch(repository: repository, git: git)
                    let checkouts = try Worktrees.list(repository: repository, git: git)
                    return (branches, current, checkouts, nil)
                } catch {
                    return ([], nil, [], error.message)
                }
            }.value
            busy = false
            branches = found.branches
            base = found.current ?? found.branches.first
            checkouts = found.checkouts.filter { !$0.isBare }
            problem = found.problem
            if branch.isEmpty {
                // A free, friendly name: one not taken by any branch.
                let taken = Set(found.branches)
                branch = Worktrees.suggestBranch(existing: taken, seed: UInt64(UInt(bitPattern: repository.hashValue)))
            }
            highlighted = shownCheckouts.first?.path
        }
    }

    // MARK: New

    func create() {
        let name = branch.trimmingCharacters(in: .whitespaces)
        guard !busy, !name.isEmpty else { return }
        guard Worktrees.isValidBranchName(name, git: GitRunner()) else {
            problem = String(localized: "“\(name)” cannot be a branch name.", comment: "New Worktree: an invalid branch name")
            return
        }
        busy = true
        problem = nil
        workbench.newWorktree(repository: repository, branch: name, base: branches.contains(name) ? nil : base) { [weak self] failure in
            guard let self else { return }
            self.busy = false
            if let failure { self.problem = failure } else { self.onOpened() }
        }
    }

    // MARK: Open

    var shownCheckouts: [Worktree] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return checkouts }
        return checkouts.filter { checkout in
            [checkout.branch ?? "", checkout.path].contains { FuzzyMatch.match(query, in: $0) != nil }
        }
    }

    /// Whether a checkout is open as a workspace already.
    func isOpen(_ checkout: Worktree) -> Bool {
        workbench.workspaces.contains { Workbench.canonical($0.folder) == Workbench.canonical(checkout.path) }
    }

    func move(_ step: Int) {
        let rows = shownCheckouts
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.path == highlighted } ?? -1
        highlighted = rows[min(max(index + step, 0), rows.count - 1)].path
    }

    func open(_ path: String? = nil) {
        guard let path = path ?? highlighted ?? shownCheckouts.first?.path else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            problem = String(localized: "That checkout's folder is gone. git worktree prune forgets it.", comment: "Open Worktree: a listed checkout whose folder was deleted")
            return
        }
        workbench.openWorktree(at: path)
        onOpened()
    }
}

/// A panel that takes the keyboard although it has no title bar; Esc puts it away.
final class WorktreePanelWindow: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// The panel itself.
struct WorktreeView: View {
    @Bindable var model: WorktreeModel
    @FocusState private var fieldFocused: Bool

    static let width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink3)
                    .accessibilityHidden(true)
                Text(model.mode == .create
                     ? String(localized: "New worktree of \(model.repositoryName)", comment: "New Worktree panel's title")
                     : String(localized: "Open a worktree of \(model.repositoryName)", comment: "Open Worktree panel's title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if model.mode == .create { create } else { open }
            if let problem = model.problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .accessibilityLabel(String(localized: "Problem: \(problem)", comment: "Accessibility: a worktree command failed"))
            }
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { fieldFocused = true }
        .accessibilityElement(children: .contain)
    }

    private var create: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(String(localized: "Branch", comment: "New Worktree: the branch field"), text: $model.branch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($fieldFocused)
                    .onSubmit { model.create() }
                    .onExitCommand { model.onClose() }
                    .accessibilityLabel(String(localized: "Branch for the new worktree"))
                if !model.branches.isEmpty && !model.branches.contains(model.branch.trimmingCharacters(in: .whitespaces)) {
                    Menu {
                        ForEach(model.branches, id: \.self) { branch in
                            Button(branch) { model.base = branch }
                        }
                    } label: {
                        Text(String(localized: "from \(model.base ?? "HEAD")", comment: "New Worktree: the branch a new one starts from"))
                            .font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(String(localized: "The branch the new one starts from"))
                } else if model.branches.contains(model.branch.trimmingCharacters(in: .whitespaces)) {
                    Text(String(localized: "existing branch", comment: "New Worktree: the name typed is a branch already, which is checked out"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink3)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)).padding(.horizontal, 8))
            HStack(spacing: 6) {
                Text(model.destination.isEmpty ? " " : model.destination)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(String(localized: "↩ Create · Esc Cancel", comment: "New Worktree: its keys"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(String(localized: "Filter checkouts…", comment: "Open Worktree: the filter field"), text: $model.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onSubmit { model.open() }
                .onExitCommand { model.onClose() }
                .padding(.horizontal, 16)
                .frame(height: 34)
            Color.line.frame(height: 1)
            let rows = model.shownCheckouts
            if rows.isEmpty && !model.busy {
                Text(String(localized: "No checkouts match.", comment: "Open Worktree: nothing matches"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { checkout in
                            CheckoutRow(checkout: checkout, isOpen: model.isOpen(checkout), highlighted: checkout.path == model.highlighted)
                                .onTapGesture { model.open(checkout.path) }
                                .onHover { if $0 { model.highlighted = checkout.path } }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(height: min(CGFloat(rows.count) * 40 + 12, 40 * 8))
            }
        }
    }
}

/// One checkout: its branch, where it is, and whether it is open already or the main one.
private struct CheckoutRow: View {
    let checkout: Worktree
    let isOpen: Bool
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: checkout.isMain ? "folder" : "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(Color.ink2)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(checkout.branch ?? checkout.head.map { String($0.prefix(7)) } ?? "?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(abbreviatingHome(checkout.path))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if checkout.isMain {
                Text(String(localized: "main checkout", comment: "Open Worktree: the repository's own folder")).font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
            if isOpen {
                Text(String(localized: "open", comment: "Open Worktree: already a workspace")).font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Color.accentColor.opacity(0.16) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }
}

/// The worktree items of a workspace's menus (the blanket's, the workspace button's): New Worktree…,
/// Open Worktree… and, for a worktree, Remove Worktree…; nothing outside a repository.
enum WorktreeMenu {
    static func add(to menu: NSMenu, workbench: Workbench, workspace: Workspace) {
        guard workbench.repositoryRoot(of: workspace) != nil else { return }
        func item(_ title: String, _ action: @escaping (MainWindowController) -> Void) {
            menu.addItem(closureMenuItem(title: title) {
                workbench.select(workspace: workspace)
                if let controller = NSApp.windows.lazy.compactMap({ $0.windowController as? MainWindowController }).first { action(controller) }
            })
        }
        item(String(localized: "New Worktree…")) { $0.newWorktree(nil) }
        item(String(localized: "Open Worktree…")) { $0.openWorktree(nil) }
        if workspace.git?.isWorktree == true {
            item(String(localized: "Remove Worktree…")) { $0.removeWorktree(nil) }
        }
        menu.addItem(.separator())
    }
}
