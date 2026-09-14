import AppKit
import SwiftUI
import WhiskrKit

/// The work area (docs/DESIGN.md): the tab row, the selected tab's panes below it with the side panel
/// (Files and Changes) on their trailing edge when it is open, one surface in the terminal's colours. On
/// Home, the Home page in the panes' place. While a closed tab can still be brought back, a note says so.
final class TerminalRegionController: NSViewController {
    private let workbench: Workbench

    private(set) var paneArea: PaneArea!
    /// The tab row (for the window's keyboard order).
    private(set) var tabRow: NSView!
    /// The Home page, shown while no workspace is selected.
    private(set) var home: NSHostingView<HomeHost>!
    private var homeObserver: Observing?
    private(set) var sidePanel: SidePanelView!
    private var panelWidth: NSLayoutConstraint!
    private var panelObserver: Observing?
    private var shownPanel: (workspace: UUID?, shown: Bool)?
    /// The panel's leading edge, the work area's own (above the panes and the panel). Hidden while the
    /// panel is closed: at the window's edge it would fight the window's own resizing.
    private let panelEdge = PanelEdge()
    /// The panel's width when its edge began to be dragged: what it opens at again after a drag closed it.
    private var dragStartWidth: Double = FilesCenter.panelDefault

    init(workbench: Workbench) {
        self.workbench = workbench
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalRegionController is created in code")
    }

    override func loadView() {
        let view = DropView()
        view.onFolders = { [weak self] urls in urls.forEach { self?.workbench.open(folder: $0.path) } }
        view.registerForDraggedTypes([.fileURL])
        let panes = PaneArea(workbench: workbench)
        paneArea = panes
        let panel = SidePanelView(workbench: workbench)
        sidePanel = panel
        let undo = NSHostingView(rootView: UndoNote(workbench: workbench))
        undo.sizingOptions = [.intrinsicContentSize]
        let tabs = NSHostingView(rootView: TabStrip(workbench: workbench))
        tabs.sizingOptions = []
        tabs.safeAreaRegions = []
        tabRow = tabs
        let home = NSHostingView(rootView: HomeHost(workbench: workbench))
        home.sizingOptions = []
        home.safeAreaRegions = []
        self.home = home
        for part in [panes, panel, tabs, home, undo] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: TabStrip.height),
            panes.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            panes.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
            panes.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            home.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            home.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            home.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            home.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panes.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(WindowLayout.terminalMinimum)),
            undo.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            undo.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        panelWidth = panel.widthAnchor.constraint(equalToConstant: 0)
        panelWidth.isActive = true
        panel.isHidden = true
        workbench.files.onReveal = { [weak panel] url in panel?.reveal(url) }
        // A helper terminal with no tab of its own, looked at over the panes.
        let peek = PeekOverlay(workbench: workbench)
        peek.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(peek)
        NSLayoutConstraint.activate([
            peek.topAnchor.constraint(equalTo: panes.topAnchor), peek.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
            peek.leadingAnchor.constraint(equalTo: panes.leadingAnchor), peek.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
        ])
        // A zoomed pane says so, and how to bring the others back.
        let zoom = NSHostingView(rootView: ZoomNote(workbench: workbench))
        zoom.sizingOptions = [.intrinsicContentSize]
        panelEdge.onDrag = { [weak self] width in self?.resizePanel(to: width) }
        panelEdge.onReset = { [weak self] in self?.resetPanelWidth() }
        panelEdge.currentWidth = { [weak self] in
            guard let self else { return 0 }
            self.dragStartWidth = Double(self.panelWidth.constant)
            return self.panelWidth.constant
        }
        for part in [zoom, panelEdge] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        NSLayoutConstraint.activate([
            zoom.topAnchor.constraint(equalTo: panes.topAnchor, constant: Look.Space.m),
            zoom.trailingAnchor.constraint(equalTo: panes.trailingAnchor, constant: -Look.Space.l),
            panelEdge.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            panelEdge.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panelEdge.centerXAnchor.constraint(equalTo: panel.leadingAnchor, constant: 0.5),
            panelEdge.widthAnchor.constraint(equalToConstant: 7),
        ])
        self.view = view
        panelObserver = Observing { [weak self] in self?.updatePanel() }
        homeObserver = Observing { [weak self] in self?.showHome() }
    }

    /// Home's page shown while no workspace is selected.
    private func showHome() {
        let isHome = workbench.isHome
        if home.isHidden == isHome { home.isHidden = !isHome }
    }

    /// Home takes the keyboard (at launch, ⌘N, Go › Home, a workspace closing): ↑ ↓ and Return. Shown,
    /// and its page put in, in this same turn if observation has not got to it yet, so the keys typed next
    /// reach it.
    func focusHome() {
        showHome()
        guard let window = view.window, !home.isHidden else { return }
        home.layoutSubtreeIfNeeded()
        if window.firstResponder !== home { window.makeFirstResponder(home) }
    }

    /// The selected workspace's panel: shown or not (sliding in and out), at its width.
    private func updatePanel() {
        let workspace = workbench.selectedWorkspace
        let state = workspace.map { workbench.files.panel($0.id) } ?? FilesCenter.Panel()
        let width = state.shown ? CGFloat(clamped(state.width)) : 0
        let animate = shownPanel?.workspace == workspace?.id && shownPanel?.shown != state.shown
            && view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        shownPanel = (workspace?.id, state.shown)
        panelEdge.isHidden = workspace == nil || !state.shown
        if state.shown { sidePanel.isHidden = false } else { giveBackKeyboard() }
        guard animate else {
            panelWidth.constant = width
            sidePanel.isHidden = !state.shown
            return
        }
        // Terminals take their new size once, at the end, rather than re-wrapping on every frame.
        LiveResize.shared.begin()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panelWidth.animator().constant = width
            view.layoutSubtreeIfNeeded()
        } completionHandler: {
            MainActor.assumeIsolated {
                if !state.shown { self.sidePanel.isHidden = true }
                LiveResize.shared.end()
            }
        }
    }

    /// The panel's edge was dragged: as wide as asked, between 200 pt and leaving the terminals their
    /// least. Dragged under half its least width it closes (keeping the width it had for next time); the
    /// same drag coming back opens it again, as the meadow does at its divider.
    private func resizePanel(to width: CGFloat) {
        guard let workspace = workbench.selectedWorkspace else { return }
        let open = Double(width) >= FilesCenter.panelMinimum / 2
        let state = workbench.files.panel(workspace.id)
        // Shown or not follows the drag at once, without the slide a button's toggle has.
        shownPanel = (workspace.id, open)
        if open {
            let width = clamped(Double(width))
            sidePanel.isHidden = false
            panelWidth.constant = CGFloat(width)
            workbench.files.setPanel(workspace.id) { $0.width = width; $0.shown = true }
        } else if state.shown {
            panelWidth.constant = 0
            sidePanel.isHidden = true
            let width = max(dragStartWidth, FilesCenter.panelMinimum)
            workbench.files.setPanel(workspace.id) { $0.shown = false; $0.width = width }
        }
        workbench.scheduleSave()
    }

    /// A double-click on the panel's edge: its usual width (and open, if it was closed).
    private func resetPanelWidth() {
        guard let workspace = workbench.selectedWorkspace else { return }
        workbench.files.setPanel(workspace.id) { $0.width = FilesCenter.panelDefault; $0.shown = true }
        if panelWidth.constant > 0 { panelWidth.constant = CGFloat(clamped(FilesCenter.panelDefault)) }
        workbench.scheduleSave()
    }

    /// The panel closing with the keyboard in it gives the keyboard to what has the focus in the tab, or
    /// (with nothing focused there) to the window itself: never left in the panel out of sight.
    private func giveBackKeyboard() {
        guard let window = view.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: sidePanel) else { return }
        if let pane = workbench.focusedPane {
            workbench.onFocusPane?(pane)
        } else if let page = workbench.focusedPageID {
            workbench.files.onFocusPage?(page)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    private func clamped(_ width: Double) -> Double {
        let most = max(FilesCenter.panelMinimum, Double(view.bounds.width) - WindowLayout.terminalMinimum)
        return min(max(width, FilesCenter.panelMinimum), most).rounded()
    }
}

/// "Zoomed · Show All Panes", over a pane zoomed to fill its tab (View › Zoom Pane, ⇧⌘↩): the other
/// panes are only out of sight, and this brings them back.
private struct ZoomNote: View {
    let workbench: Workbench

    var body: some View {
        if let tab = workbench.selectedTab, tab.zoomedPane != nil {
            Button {
                workbench.toggleZoom()
            } label: {
                HStack(spacing: Look.Space.s) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(Look.smallIcon)
                    Text(String(localized: "Zoomed · Show All Panes ⇧⌘↩", comment: "Note over a zoomed pane; a click brings back the others"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.ink2)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.surface))
                .overlay(Capsule().strokeBorder(Color.line))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Restore Panes (⇧⌘↩)"))
        }
    }
}

/// The Home page, there only while Home is shown. Hidden, SwiftUI would still work it out again whenever
/// a workspace, a tab or a Claude changed (measured: 4–10 ms of every ⌘T and close); it comes afresh on
/// each visit, as it starts again on New Terminal anyway.
struct HomeHost: View {
    let workbench: Workbench

    var body: some View {
        if workbench.isHome { HomePage(workbench: workbench) } else { Color.clear }
    }
}

/// "Closed · Undo ⌘Z", while a closed tab or pane can still come back as it was.
private struct UndoNote: View {
    let workbench: Workbench

    var body: some View {
        if workbench.canUndoClose {
            Button {
                workbench.undoClose()
            } label: {
                Text(String(localized: "Closed · Undo ⌘Z", comment: "Note while a closed tab can be brought back"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.surface))
                    .overlay(Capsule().strokeBorder(Color.line))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            // Never taken away while being read: the moment for ⌘Z waits while the pointer is on it.
            .onHover { workbench.holdsUndoNote = $0 }
            .onDisappear { workbench.holdsUndoNote = false }
        }
    }
}
