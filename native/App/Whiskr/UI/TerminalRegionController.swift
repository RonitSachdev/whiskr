import AppKit
import SwiftUI
import WhiskrKit

/// The work area (docs/DESIGN.md): the tab row, the selected tab's panes below it with the side panel
/// (Files and Changes) on their trailing edge when it is open, one surface in the terminal's colours. On
/// Home, the Home page in the panes' place. While a closed tab can still be brought back, a note says so.
final class TerminalRegionController: NSViewController {
    private let workbench: Workbench

    private(set) var paneArea: PaneArea!
    /// The Home page, shown while no workspace is selected.
    private(set) var home: NSHostingView<HomePage>!
    private var homeObserver: Observing?
    private(set) var sidePanel: SidePanelView!
    private var panelWidth: NSLayoutConstraint!
    private var panelObserver: Observing?
    private var shownPanel: (workspace: UUID?, shown: Bool)?

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
        let home = NSHostingView(rootView: HomePage(workbench: workbench))
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
        panel.onResize = { [weak self] width in self?.resizePanel(to: width) }
        workbench.files.onReveal = { [weak panel] url in panel?.reveal(url) }
        // A helper terminal with no tab of its own, looked at over the panes.
        let peek = PeekOverlay(workbench: workbench)
        peek.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(peek)
        NSLayoutConstraint.activate([
            peek.topAnchor.constraint(equalTo: panes.topAnchor), peek.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
            peek.leadingAnchor.constraint(equalTo: panes.leadingAnchor), peek.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
        ])
        self.view = view
        panelObserver = Observing { [weak self] in self?.updatePanel() }
        homeObserver = Observing { [weak self] in
            guard let self else { return }
            let isHome = self.workbench.isHome
            if self.home.isHidden == isHome { self.home.isHidden = !isHome }
        }
    }

    /// Home takes the keyboard (at launch, ⌘N, Go › Home, a workspace closing): ↑ ↓ and Return.
    func focusHome() {
        guard let window = view.window, !home.isHidden else { return }
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
        if state.shown { sidePanel.isHidden = false }
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

    /// The panel's edge was dragged: as wide as asked, between 200 pt and leaving the terminals their least.
    private func resizePanel(to width: CGFloat) {
        guard let workspace = workbench.selectedWorkspace else { return }
        let width = clamped(Double(width))
        panelWidth.constant = CGFloat(width)
        workbench.files.setPanel(workspace.id) { $0.width = width }
        workbench.scheduleSave()
    }

    private func clamped(_ width: Double) -> Double {
        let most = max(FilesCenter.panelMinimum, Double(view.bounds.width) - WindowLayout.terminalMinimum)
        return min(max(width, FilesCenter.panelMinimum), most).rounded()
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
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            }
            .buttonStyle(.plain)
        }
    }
}
