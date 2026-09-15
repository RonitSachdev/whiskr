import AppKit
import MeadowScene
import SwiftUI
import SwiftTerm
import WhiskrKit

/// The one window (docs/DESIGN.md), framed as Cursor's: a top bar and a status bar the window's full
/// width (`FrameController`), and between them herdr's arrangement: the sidebar on the left (the meadow,
/// one blanket per workspace, where herdr has its list) and the work area on the right, the current
/// workspace's tabs over its panes, or Home while no workspace is selected. The title bar itself is clear:
/// the top bar is drawn under it. The window's title is the workspace's name, or "Whiskr" on Home (for
/// the Window menu, Mission Control and VoiceOver), not drawn.
///
/// Every command lives here, reached through the responder chain from the menus.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let workbench: Workbench
    private let split = RegionsController()
    let navigator: NavigatorController
    let terminals: TerminalRegionController
    private let navigatorItem: NSSplitViewItem
    private let terminalItem: NSSplitViewItem
    private var firstResponderWatch: NSKeyValueObservation?
    private var observers: [Observing] = []
    private let chrome = WindowChrome()
    /// The command palette and Go to (one overlay).
    private(set) var palette: PaletteController?
    /// ⌃Tab's most-recent switching.
    private(set) var tabSwitcher: TabSwitcher?

    private(set) var layout: WindowLayout {
        didSet {
            guard layout != oldValue else { return }
            AppPlaces.defaults.set(layout.data, forKey: Self.layoutKey)
            applyLayout(animated: true)
        }
    }

    private static let layoutKey = "windowLayout"
    /// The regions are sliding open or shut (`applyLayout`).
    private var sliding = false

    init(workbench: Workbench) {
        self.workbench = workbench
        layout = WindowLayout(data: AppPlaces.defaults.data(forKey: Self.layoutKey))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 440)
        window.toolbarStyle = .unifiedCompact
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = String(localized: "Whiskr", comment: "The window's title while no workspace is open")

        navigator = NavigatorController(workbench: workbench)
        terminals = TerminalRegionController(workbench: workbench)
        // A plain region, not a system sidebar: the meadow runs flush to the window's edges and up under
        // the title bar, rather than sitting in the sidebar's inset panel.
        navigatorItem = NSSplitViewItem(viewController: navigator)
        navigatorItem.canCollapse = true
        navigatorItem.minimumThickness = CGFloat(WindowLayout.navigatorMinimum)
        terminalItem = NSSplitViewItem(viewController: terminals)
        terminalItem.minimumThickness = CGFloat(WindowLayout.terminalMinimum)
        terminalItem.canCollapse = true
        // A region opening or closing gives its room to the other one, inside the window as it is. Left to
        // the default, the split view keeps the other region's width and resizes the window instead: wider
        // to open the meadow beside terminals that already fill it, narrower (to nothing, with both regions
        // closing) as one closes. The window then no longer has the size it was given, nor its regions the
        // layout's widths.
        for item in [navigatorItem, terminalItem] { item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView }
        split.splitViewItems = [navigatorItem, terminalItem]

        super.init(window: window)
        window.delegate = self
        workbench.undoManager = window.undoManager
        workbench.files.window = window
        // An empty toolbar: it only gives the title bar the height of the top bar, so the traffic lights
        // sit centred in it.
        let toolbar = NSToolbar(identifier: "main")
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        if let zoom = window.standardWindowButton(.zoomButton) { chrome.trafficLightsEnd = zoom.frame.maxX }
        chrome.toggleMeadow = { [weak self] in self?.toggleNavigator(nil) }
        window.contentViewController = FrameController(content: split, workbench: workbench, chrome: chrome)
        window.setContentSize(NSSize(width: 1440, height: 900))
        if AppPlaces.isIsolated {
            window.center()
        } else {
            window.setFrameAutosaveName("MainWindow")
            if !window.setFrameUsingName("MainWindow") { window.center() }
        }
        split.onToggleSidebar = { [weak self] in self?.toggleNavigator(nil) }
        split.onDividerDragged = { [weak self] width in
            guard let self, let window = self.window else { return }
            self.layout.dragDivider(to: Double(width), window: Double(window.frame.width))
        }
        split.onDividerReset = { [weak self] in self?.layout.resetSplit() }
        keyboardOrder(window)
        palette = PaletteController(workbench: workbench, window: window)
        tabSwitcher = TabSwitcher(workbench: workbench, window: window)
        applyLayout(animated: false)

        workbench.onFocusPane = { [weak self] pane in
            guard let window = self?.window else { return }
            // Only a terminal that is on screen takes the keys.
            let showing: @MainActor () -> Bool = { pane.surface.window === window && !pane.surface.isHiddenOrHasHiddenAncestor }
            // Its tab is shown now, not when observation next runs: the keyboard moves in this same turn,
            // so a key typed straight after ⌘T, ⌘W or a tab switch reaches this terminal and no other.
            if !showing() {
                self?.terminals.paneArea.update()
                // The tab row too (SwiftUI, which would otherwise catch up a frame or two later).
                window.contentView?.layoutSubtreeIfNeeded()
            }
            if showing() {
                if window.firstResponder !== pane.surface { window.makeFirstResponder(pane.surface) }
            } else {
                DispatchQueue.main.async { if showing() { window.makeFirstResponder(pane.surface) } }
            }
        }
        workbench.onFocusHome = { [weak self] in self?.terminals.focusHome() }
        firstResponderWatch = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                // A file or diff took the keyboard by a click: its tab and place in it follow.
                if let self, let view = window.firstResponder as? NSView, let page = self.page(containing: view) {
                    self.navigator.keyboardLeft()
                    self.workbench.pageTookFocus(page)
                    return
                }
                guard let self, let surface = window.firstResponder as? TerminalSurface,
                      let pane = self.workbench.panes.values.first(where: { $0.surface === surface }) else { return }
                self.navigator.keyboardLeft()
                self.workbench.terminalTookFocus(pane.id)
            }
        }
        observers.append(Observing { [weak self] in self?.updateTitle() })
        watchKeys()
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(lookingChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code")
    }

    private var keyMonitor: Any?

    /// With Full Keyboard Access, Tab goes round the window in reading order: the top bar, the tab row,
    /// the pane or page, the side panel, the status bar, and back to the top. (In a terminal Tab is the
    /// shell's; ⌃F7 or a click moves on from there, as in Terminal.)
    private func keyboardOrder(_ window: NSWindow) {
        guard let frame = window.contentViewController as? FrameController, let top = frame.topBar, let status = frame.statusBar else { return }
        window.autorecalculatesKeyViewLoop = false
        let order: [NSView] = [top, terminals.tabRow, terminals.paneArea, terminals.sidePanel, status]
        for (view, next) in zip(order, order.dropFirst() + [top]) { view.nextKeyView = next }
        window.initialFirstResponder = terminals.paneArea
    }

    /// Keys on their way to a terminal: when one was last typed (alert sounds wait for a pause, the meadow
    /// draws less often meanwhile), and
    /// which Option key is Meta (Settings › Terminal): SwiftTerm takes Option as Meta or not as a whole,
    /// so it is told per key press whether the Option held is the side that should be.
    private func watchKeys() {
        AlertCenter.shared.lastKeystroke = { [weak self] in self?.workbench.lastKeystroke }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let surface = event.window?.firstResponder as? TerminalSurface else { return event }
            self.workbench.lastKeystroke = Date()
            // The meadow draws less often while you type, leaving the frames to the terminal.
            self.navigator.meadow.yieldFrames()
            if event.modifierFlags.contains(.option) {
                let raw = event.modifierFlags.rawValue
                let left = raw & 0x20 != 0, right = raw & 0x40 != 0     // NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK
                let meta: Bool = switch Preferences.shared.optionKey {
                case .left: left
                case .right: right
                case .both: true
                case .neither: false
                }
                if surface.optionAsMetaKey != meta { surface.optionAsMetaKey = meta }
            }
            return event
        }
    }

    /// The workspace's name, with its folder as the window's document (for the Window menu, Mission
    /// Control and VoiceOver; the top bar shows it instead); "Whiskr" on Home.
    private func updateTitle() {
        guard let window else { return }
        if let workspace = workbench.selectedWorkspace {
            window.title = workspace.name
            window.representedURL = URL(fileURLWithPath: workspace.folder, isDirectory: true)
        } else {
            window.title = String(localized: "Whiskr", comment: "The window's title while no workspace is open")
            window.representedURL = nil
        }
    }

    // MARK: Layout

    private func applyLayout(animated: Bool) {
        guard let window else { return }
        let animate = animated && Look.Motion.moves && window.isVisible && !sliding
        navigator.kind = layout.navigator
        let frame = layout.frame(window: Double(window.frame.width))
        let showNavigator = frame.navigator > 0
        if chrome.showsStatusBar != layout.showsStatusBar { chrome.showsStatusBar = layout.showsStatusBar }
        if chrome.meadowShown != showNavigator { chrome.meadowShown = showNavigator }
        let handKeyboard = keyboardHandover(meadowShown: showNavigator, terminalsShown: frame.showsTerminals)
        defer { handKeyboard?() }
        let width: @MainActor () -> Void = { [weak self] in
            guard let self, showNavigator, frame.showsTerminals else { return }
            self.split.setNavigatorWidth(CGFloat(frame.navigator))
        }
        // A region coming back opens at the width it is to have. Left at the one it had when it went (the
        // meadow 600 pt wide in a window since narrowed to 720), it would slide open to that width, taking
        // the other region under its least.
        if showNavigator, frame.showsTerminals {
            let height = navigator.view.frame.height
            if navigatorItem.isCollapsed { navigator.view.setFrameSize(NSSize(width: frame.navigator, height: height)) }
            if terminalItem.isCollapsed { terminals.view.setFrameSize(NSSize(width: window.frame.width - frame.navigator, height: height)) }
        }
        let changes = navigatorItem.isCollapsed == showNavigator || terminalItem.isCollapsed == frame.showsTerminals
        if animate && changes {
            // The split view's own slide. The divider goes where it belongs once the regions have finished
            // opening or closing. Meanwhile terminals keep their size, as in a live resize, and one waiting
            // to start waits for the end: a shell would draw its first prompt for a width the region only
            // passed through.
            sliding = true
            LiveResize.shared.slide { _ in
                if terminalItem.isCollapsed == frame.showsTerminals { terminalItem.animator().isCollapsed = !frame.showsTerminals }
                if navigatorItem.isCollapsed == showNavigator { navigatorItem.animator().isCollapsed = !showNavigator }
            } done: { [weak self] in
                // The regions where the layout says now, at the window's width now: it may have changed
                // while they slid (⌃⌘S twice in quick succession, the window resized).
                self?.sliding = false
                self?.applyLayout(animated: false)
            }
        } else {
            // At once: with Reduce Motion, in a window out of sight, and over a slide still on its way (the
            // split view, asked to slide again before its last slide has ended, left both stalled and then
            // resized the window to fit what it was left with: to 1 pt wide, measured). That slide's end
            // settles the rest.
            if terminalItem.isCollapsed == frame.showsTerminals { terminalItem.isCollapsed = !frame.showsTerminals }
            if navigatorItem.isCollapsed == showNavigator { navigatorItem.isCollapsed = !showNavigator }
            width()
        }
    }

    /// A region going away with the keyboard in it hands the keyboard to the one that stays: the meadow's
    /// to the focused terminal (or Home), the terminals' to the meadow. Where the keyboard is is read now,
    /// and it is handed over once the regions have been told what to show: a region that is closed at once
    /// takes the keyboard out of the window, and one still closed cannot take it.
    private func keyboardHandover(meadowShown: Bool, terminalsShown: Bool) -> (() -> Void)? {
        guard let window, let responder = window.firstResponder as? NSView else { return nil }
        if !meadowShown, responder.isDescendant(of: navigator.view) {
            return { [weak self] in
                guard let self else { return }
                navigator.keyboardLeft()
                if let pane = workbench.focusedPane { workbench.onFocusPane?(pane) } else { terminals.focusHome() }
            }
        } else if !terminalsShown, responder.isDescendant(of: terminals.view) {
            return { [weak self] in self?.navigator.takeKeyboard() }
        }
        return nil
    }

    /// View › Hide Status Bar / Show Status Bar (⌥⌘/).
    @objc func toggleStatusBar(_ sender: Any?) { layout.showsStatusBar.toggle() }

    /// View › Reset Layout: the meadow, the terminals and the status bar back as they first were, and the
    /// selected workspace's side panel at its usual width (shown only if it was). Other workspaces' panels,
    /// the panes' shares and how the workspaces are drawn are yours, and stay.
    @objc func resetLayout(_ sender: Any?) {
        layout.reset()
        if let workspace = workbench.selectedWorkspace {
            workbench.files.setPanel(workspace.id) { $0.width = FilesCenter.panelDefault }
            workbench.scheduleSave()
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) { LiveResize.shared.begin() }
    func windowDidEndLiveResize(_ notification: Notification) { LiveResize.shared.end() }

    func windowDidResize(_ notification: Notification) {
        // The default split follows the window's width (and the meadow steps aside when there is no room).
        applyLayout(animated: false)
    }

    /// After the workbench has brought back its workspaces: the window shows Home, with the keyboard
    /// (or the workspace a folder opened with the app chose).
    func workbenchDidLaunch() {
        applyLayout(animated: false)
        navigator.restore()
        updateTitle()
        if let pane = workbench.focusedPane { workbench.onFocusPane?(pane) } else { terminals.focusHome() }
    }

    /// Kept for the next launch (the layout saves itself as it changes; the camera here).
    func saveState() {
        navigator.saveState()
    }

    /// The window's width, which decides whether the default split has room for the meadow.
    private var windowWidth: Double { Double(window?.frame.width ?? 0) }

    /// View › Hide Meadow / Show Meadow (⌃⌘S, the meadow button): by what is on screen, so in a window
    /// too narrow for the default split it shows the meadow, at its narrowest.
    @objc func toggleNavigator(_ sender: Any?) { layout.toggleNavigator(window: windowWidth) }

    /// Go › Move Focus to Meadow (⌥⌘0): the keyboard goes to the meadow (or the list), on the selected
    /// workspace; Esc or Tab gives it back to the terminal.
    @objc func moveFocusToMeadow(_ sender: Any?) {
        layout.showNavigator(window: windowWidth)
        navigator.takeKeyboard()
    }
    @objc func showMeadowAndTerminals(_ sender: Any?) {
        layout.mode = .split
        layout.showNavigator(window: windowWidth)
    }
    @objc func showTerminalsOnly(_ sender: Any?) { layout.mode = .terminalsOnly }
    @objc func showMeadowOnly(_ sender: Any?) { layout.mode = .meadowOnly }
    /// View › Animate Meadow (`WorldStore.animatesMeadow`).
    @objc func toggleAnimateMeadow(_ sender: Any?) { WorldStore.shared.animatesMeadow.toggle() }
    @objc func toggleWorkspacesAsList(_ sender: Any?) {
        layout.navigator = layout.navigator == .list ? .meadow : .list
        layout.showNavigator(window: windowWidth)
    }

    #if DEBUG
    /// Debug builds: a layout set from the command line.
    func debugSetLayout(_ change: (inout WindowLayout) -> Void) {
        change(&layout)
    }

    /// Debug builds: which regions the split view has closed (a closed one keeps its view, and its last
    /// width, out of sight).
    var debugCollapsed: (meadow: Bool, terminals: Bool) { (navigatorItem.isCollapsed, terminalItem.isCollapsed) }
    #endif

    @objc private func lookingChanged() {
        guard let window else { return }
        let wasLooking = workbench.isLookingAtWindow
        defer {
            // Back in the app: open files look at the disk once (a change while the Mac slept).
            if workbench.isLookingAtWindow && !wasLooking { workbench.files.checkAllDocuments() }
        }
        workbench.isLookingAtWindow = NSApp.isActive && window.isKeyWindow && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func windowDidBecomeKey(_ notification: Notification) { lookingChanged() }
    func windowDidResignKey(_ notification: Notification) { lookingChanged() }
    func windowDidMiniaturize(_ notification: Notification) { lookingChanged() }
    func windowDidChangeOcclusionState(_ notification: Notification) { lookingChanged() }
    func windowDidEnterFullScreen(_ notification: Notification) { chrome.fullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { chrome.fullScreen = false }

    // MARK: Opening

    /// File › New Workspace (⌘N): Home, with the keyboard on New Terminal (Open Folder… is one row up).
    /// The workspaces stay as they are, one click away on their blankets and under Open.
    @objc func newWorkspace(_ sender: Any?) {
        workbench.goHome()
    }

    /// Go › Home (⇧⌘H): no workspace selected; everything keeps running.
    @objc func goHome(_ sender: Any?) {
        workbench.goHome()
    }

    @objc func newTab(_ sender: Any?) {
        workbench.newTab()
    }

    /// File › Open Folder… (⌘O): the standard folder picker, then a workspace there (or the one already
    /// open on it).
    @objc func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open", comment: "Folder picker's button")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.workbench.open(folder: url.path)
        }
    }

    @objc func splitRight(_ sender: Any?) {
        if workbench.focusedPageID != nil { workbench.splitBesidePage(.horizontal) } else { workbench.split(.horizontal) }
    }
    @objc func splitDown(_ sender: Any?) {
        if workbench.focusedPageID != nil { workbench.splitBesidePage(.vertical) } else { workbench.split(.vertical) }
    }

    // MARK: Closing

    /// File › Close (⌘W): the focused pane, undoable for ten seconds; nothing is asked.
    @objc func closePane(_ sender: Any?) {
        if workbench.peekedPane != nil {
            // A helper looked at over the panes is put away; it keeps running.
            workbench.closePeek()
        } else if let pane = workbench.focusedPane {
            workbench.close(pane: pane.id)
        } else if let page = workbench.focusedPageID {
            // A file or diff goes from its place (asking first about unsaved changes).
            workbench.close(page: page)
        }
    }

    /// File › Close Tab (⌥⌘W), undoable likewise.
    @objc func closeTab(_ sender: Any?) {
        guard let tab = workbench.selectedTab else { return }
        workbench.requestClose(tab: tab)
    }

    @objc func reopenClosedTab(_ sender: Any?) { workbench.reopenClosedTab() }

    /// File › Close Workspace: asks only when Claude is working or a program other than a shell runs.
    @objc func closeWorkspace(_ sender: Any?) {
        guard let workspace = workbench.selectedWorkspace else { return }
        requestClose(workspace: workspace)
    }

    /// Closes a workspace (the one shown gives way to Home; another, from its blanket's menu, leaves you
    /// where you are). Unsaved files are asked about first, as any document window asks.
    func requestClose(workspace: Workspace) {
        workbench.confirmClosing(workbench.editedDocuments(in: workspace)) { [weak self] in self?.closeRunning(workspace) }
    }

    /// Closes a workspace, asking first when Claude or another program runs in it.
    private func closeRunning(_ workspace: Workspace) {
        guard let window, workbench.isBusy(workspace) else { return workbench.close(workspace: workspace) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Close “\(workspace.name)”?")
        let working = workspace.tabs.filter { tab in tab.tree.panes.contains { workbench.panes[$0]?.agentRunning ?? false } }.count
        alert.informativeText = working > 0
            ? String(localized: "Claude is working in \(working) tabs. Closing stops them; you can resume the conversations later.")
            : String(localized: "A program is still running. Closing stops it.")
        alert.addButton(withTitle: String(localized: "Close Workspace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.workbench.close(workspace: workspace) }
        }
    }

    @objc func renameTab(_ sender: Any?) {
        workbench.renamingTabID = workbench.selectedTab?.id
    }

    /// File › Rename Workspace…: its name is edited in place, in the tab row's workspace button.
    @objc func renameWorkspace(_ sender: Any?) {
        if layout.mode == .meadowOnly { layout.mode = .split }
        workbench.renamingWorkspaceID = workbench.selectedWorkspace?.id
    }

    // MARK: Finding

    /// Go › Command Palette… (⇧⌘P): every command and every place, by name.
    @objc func showCommandPalette(_ sender: Any?) { palette?.toggle(.commands) }

    /// Go › Go to… (⌘P): any workspace, tab, Claude or helper, by name, folder, branch or state.
    @objc func goTo(_ sender: Any?) { palette?.toggle(.goTo) }

    // MARK: Claude

    /// Pin Claude: the focused pane's Claude is marked and listed first.
    @objc func togglePin(_ sender: Any?) {
        guard let pane = workbench.focusedPane, pane.agentRunning else { return }
        workbench.togglePin(pane: pane.id)
    }

    @objc func markUnread(_ sender: Any?) {
        guard let pane = workbench.focusedPane else { return }
        workbench.markUnread(pane: pane.id)
    }

    // MARK: Moving around

    @objc func focusLeft(_ sender: Any?) { workbench.moveFocus(.left) }
    @objc func focusRight(_ sender: Any?) { workbench.moveFocus(.right) }
    @objc func focusUp(_ sender: Any?) { workbench.moveFocus(.up) }
    @objc func focusDown(_ sender: Any?) { workbench.moveFocus(.down) }
    @objc func swapLeft(_ sender: Any?) { workbench.swapFocused(.left) }
    @objc func swapRight(_ sender: Any?) { workbench.swapFocused(.right) }
    @objc func swapUp(_ sender: Any?) { workbench.swapFocused(.up) }
    @objc func swapDown(_ sender: Any?) { workbench.swapFocused(.down) }
    @objc func nextPane(_ sender: Any?) { workbench.focusPane(offset: 1) }
    @objc func previousPane(_ sender: Any?) { workbench.focusPane(offset: -1) }
    @objc func toggleZoom(_ sender: Any?) { workbench.toggleZoom() }
    /// ⌘1…⌘8 a tab by number, ⌘9 the last (as Safari and Terminal).
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let count = workbench.selectedWorkspace?.tabs.count ?? 0
        workbench.selectTab(at: sender.tag == 9 ? count - 1 : sender.tag - 1)
    }
    @objc func selectWorkspaceByNumber(_ sender: NSMenuItem) { workbench.selectWorkspace(at: sender.tag - 1) }
    /// ⌃Tab and ⌃⇧Tab: the tab shown before, or a held ⌃'s list of recent tabs (`TabSwitcher`).
    @objc func switchToRecentTab(_ sender: Any?) { tabSwitcher?.begin(backward: false) }
    @objc func switchToRecentTabBackward(_ sender: Any?) { tabSwitcher?.begin(backward: true) }
    @objc func nextTab(_ sender: Any?) { workbench.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { workbench.selectTab(offset: -1) }
    @objc func nextWorkspace(_ sender: Any?) { workbench.selectWorkspace(offset: 1) }
    @objc func previousWorkspace(_ sender: Any?) { workbench.selectWorkspace(offset: -1) }
    @objc func goToNextThing(_ sender: Any?) { workbench.goToNextThing() }

    // MARK: Terminal

    @objc func biggerText(_ sender: Any?) { ThemeStore.shared.setFontSize(ThemeStore.shared.fontSize + 1) }
    @objc func smallerText(_ sender: Any?) { ThemeStore.shared.setFontSize(ThemeStore.shared.fontSize - 1) }
    @objc func actualSizeText(_ sender: Any?) { ThemeStore.shared.setFontSize(ThemeStore.defaultFontSize) }
    @objc func clearScrollback(_ sender: Any?) { workbench.focusedPane?.clearScrollback() }
    /// Go › Interrupt (⌘.): Esc to Claude (how its turn is stopped), ⌃C to anything else.
    @objc func interrupt(_ sender: Any?) {
        guard let pane = workbench.focusedPane else { return }
        if pane.agentRunning { pane.interrupt() } else { pane.type("\u{03}") }
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let files = validateFilesItem(item) { return files }
        let tab = workbench.selectedTab
        let paneCount = tab?.tree.panes.count ?? 0
        switch item.action {
        case #selector(toggleNavigator(_:)):
            item.title = layout.showsNavigator(window: windowWidth) ? String(localized: "Hide Meadow") : String(localized: "Show Meadow")
            return true
        case #selector(toggleStatusBar(_:)):
            item.title = layout.showsStatusBar ? String(localized: "Hide Status Bar") : String(localized: "Show Status Bar")
            return true
        case #selector(resetLayout(_:)):
            return true
        // The form on screen: a split whose meadow stepped aside for lack of room shows the terminals only.
        case #selector(showMeadowAndTerminals(_:)):
            let frame = layout.frame(window: windowWidth)
            item.state = frame.navigator > 0 && frame.showsTerminals ? .on : .off
            return true
        case #selector(showTerminalsOnly(_:)):
            item.state = layout.showsNavigator(window: windowWidth) ? .off : .on
            return true
        case #selector(showMeadowOnly(_:)):
            item.state = layout.frame(window: windowWidth).showsTerminals ? .off : .on
            return true
        case #selector(goHome(_:)):
            item.state = workbench.isHome ? .on : .off
            return !workbench.isHome
        case #selector(toggleAnimateMeadow(_:)):
            item.state = WorldStore.shared.animatesMeadow ? .on : .off
            return layout.navigator == .meadow
        case #selector(toggleWorkspacesAsList(_:)):
            item.state = layout.navigator == .list ? .on : .off
            return true
        case #selector(moveFocusToMeadow(_:)):
            return !workbench.workspaces.isEmpty
        case #selector(togglePin(_:)):
            let pane = workbench.focusedPane
            item.title = pane.map { workbench.pinnedPanes.contains($0.id) } == true ? String(localized: "Unpin Claude") : String(localized: "Pin Claude")
            return pane?.agentRunning ?? false
        case #selector(markUnread(_:)):
            return workbench.focusedPane.map { workbench.canMarkUnread(pane: $0.id) } ?? false
        case #selector(selectWorkspaceByNumber(_:)):
            let index = item.tag - 1
            if workbench.workspaces.indices.contains(index) {
                item.title = workbench.workspaces[index].name
                item.state = workbench.workspaces[index] === workbench.selectedWorkspace ? .on : .off
            } else {
                item.title = String(localized: "Workspace \(item.tag)")
                item.state = .off
            }
            return workbench.workspaces.count >= item.tag
        case #selector(closeTab(_:)), #selector(closeWorkspace(_:)), #selector(renameTab(_:)), #selector(renameWorkspace(_:)):
            return workbench.selectedWorkspace != nil
        case #selector(closePane(_:)):
            return workbench.peekedPane != nil || workbench.focusedPane != nil || workbench.focusedPageID != nil
        case #selector(splitRight(_:)), #selector(splitDown(_:)):
            return workbench.focusedPane != nil || workbench.focusedPageID != nil
        case #selector(clearScrollback(_:)):
            return workbench.focusedPane != nil
        case #selector(interrupt(_:)):
            // ⌘. is also the Mac's Cancel: while a text field, the palette or a card has the keyboard, the
            // key is theirs (a rename, Go to or the commit message gives up) and no terminal is interrupted.
            guard let window, NSApp.keyWindow === window || NSApp.keyWindow == nil, !(window.firstResponder is NSText) else { return false }
            return workbench.focusedPane != nil
        case #selector(reopenClosedTab(_:)):
            return workbench.canReopenClosedTab
        case #selector(toggleZoom(_:)):
            item.title = tab?.zoomedPane == nil ? String(localized: "Zoom Pane") : String(localized: "Restore Panes")
            return paneCount > 1
        case #selector(focusLeft(_:)), #selector(swapLeft(_:)): return hasPane(toward: .left)
        case #selector(focusRight(_:)), #selector(swapRight(_:)): return hasPane(toward: .right)
        case #selector(focusUp(_:)), #selector(swapUp(_:)): return hasPane(toward: .up)
        case #selector(focusDown(_:)), #selector(swapDown(_:)): return hasPane(toward: .down)
        case #selector(nextPane(_:)), #selector(previousPane(_:)):
            return paneCount > 1 && tab?.zoomedPane == nil
        case #selector(selectTabByNumber(_:)):
            let count = workbench.selectedWorkspace?.tabs.count ?? 0
            return item.tag == 9 ? count > 0 : count >= item.tag
        case #selector(nextTab(_:)), #selector(previousTab(_:)), #selector(switchToRecentTab(_:)), #selector(switchToRecentTabBackward(_:)):
            return (workbench.selectedWorkspace?.tabs.count ?? 0) > 1
        case #selector(nextWorkspace(_:)), #selector(previousWorkspace(_:)):
            // From Home, the first or the last.
            return workbench.workspaces.count > (workbench.isHome ? 0 : 1)
        case #selector(goToNextThing(_:)):
            switch workbench.nextThing {
            case .request: item.title = String(localized: "Next Request"); return true
            case .finished: item.title = String(localized: "Next Finished"); return true
            case .back(let id):
                let name = workbench.panes[id].flatMap { pane in workbench.workspace(of: pane.id).map { workbench.title(of: $0.1) } } ?? ""
                item.title = String(localized: "Back to “\(name)”", comment: "Go menu: ⌘J returns to where you were")
                return true
            case .nothing: item.title = String(localized: "Next Request"); return false
            }
        case #selector(biggerText(_:)):
            return ThemeStore.shared.fontSize < ThemeStore.fontSizes.upperBound
        case #selector(smallerText(_:)):
            return ThemeStore.shared.fontSize > ThemeStore.fontSizes.lowerBound
        case #selector(newWorktree(_:)), #selector(openWorktree(_:)), #selector(removeWorktree(_:)):
            return validateWorktree(item)
        default:
            return true
        }
    }

    /// Whether the focused pane has a neighbour that way (a direction with nothing in it is dimmed).
    private func hasPane(toward direction: PaneTree.Direction) -> Bool {
        guard let tab = workbench.selectedTab, tab.zoomedPane == nil else { return false }
        return tab.tree.neighbor(of: tab.focusedPane, toward: direction, recency: tab.recency) != nil
    }

    // MARK: Window

    /// Closing the window (⇧⌘W, the red button) hides it; everything keeps running, and the Dock icon or
    /// Window › Whiskr brings it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        saveState()
        sender.orderOut(nil)
        lookingChanged()
        return false
    }
}

/// The two regions. Routes the system sidebar button to the layout, and reports a dragged divider (and
/// a double-click on it, which restores the usual width).
final class RegionsController: NSSplitViewController {
    var onToggleSidebar: (() -> Void)?
    var onDividerDragged: ((CGFloat) -> Void)?
    var onDividerReset: (() -> Void)?
    private var settingWidth = false

    override func loadView() {
        let view = RegionsSplitView()
        view.isVertical = true
        view.dividerStyle = .thin
        view.onDoubleClickDivider = { [weak self] in self?.onDividerReset?() }
        splitView = view
        super.loadView()
    }

    override func toggleSidebar(_ sender: Any?) {
        onToggleSidebar?()
    }

    func setNavigatorWidth(_ width: CGFloat) {
        guard splitViewItems.count == 2, !splitViewItems[0].isCollapsed, !splitViewItems[1].isCollapsed else { return }
        let current = splitViewItems[0].viewController.view.frame.width
        guard abs(current - width) > 0.5 else { return }
        settingWidth = true
        splitView.setPosition(width, ofDividerAt: 0)
        settingWidth = false
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        (splitView as? RegionsSplitView)?.dividerMoved()
        // Only a drag of the divider itself, by the mouse, says where you want it (collapsing or opening a
        // region resizes too, with the same notification).
        // (Not told by the event being handled: a click's release stays the app's current event until the
        // next one, all through a slide the click began.)
        let byHand = (splitView as? RegionsSplitView)?.isDraggingDivider == true
        guard !settingWidth, byHand, notification.userInfo?["NSSplitViewDividerIndex"] != nil, splitViewItems.count == 2 else { return }
        // Where the divider is now: 0 when the meadow was dragged shut, the whole width when the terminals were.
        let width = splitViewItems[0].isCollapsed ? 0 : splitViewItems[1].isCollapsed ? splitView.bounds.width : splitViewItems[0].viewController.view.frame.width
        onDividerDragged?(width)
    }
}

/// The meadow and the work area, with one line between them: the meadow's edge, as every edge in the
/// window is drawn.
final class RegionsSplitView: NSSplitView {
    var onDoubleClickDivider: (() -> Void)?

    override var dividerColor: NSColor { Colors.line }

    override func mouseDown(with event: NSEvent) {
        // The regions are its arranged subviews (the divider is a view of its own beside them).
        if event.clickCount == 2, arrangedSubviews.count == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if dividerReach.contains(point) {
                onDoubleClickDivider?()
                return
            }
        }
        // Anything else that reaches the split view itself is a drag of its divider.
        isDraggingDivider = true
        glow.drag({ super.mouseDown(with: event) }, pointerOnDivider: { [unowned self] in isPointerOnDivider })
        isDraggingDivider = false
    }

    /// The divider is being dragged by the mouse (its tracking loop is running): what the regions' resizing
    /// meanwhile says is where you want it.
    private(set) var isDraggingDivider = false

    // MARK: Showing it can be dragged (`DividerGlow`)

    private lazy var glow = DividerGlow(in: self) { [unowned self] in dividerLine }
    private var dividerArea: NSTrackingArea?

    /// The divider moved (a drag, the window resized, a region opened or closed): what follows the pointer
    /// and what shows it, along with it.
    func dividerMoved() {
        updateTrackingAreas()
        glow.follow()
    }

    /// The meadow's edge, while both regions show.
    private var dividerLine: NSRect {
        let regions = arrangedSubviews
        guard regions.count == 2, !regions[0].isHidden, !regions[1].isHidden, regions[0].frame.width > 0 else { return .zero }
        return NSRect(x: regions[0].frame.maxX, y: 0, width: dividerThickness, height: bounds.height)
    }

    private var dividerReach: NSRect { dividerLine.insetBy(dx: -4, dy: 0) }

    private var isPointerOnDivider: Bool {
        guard let window, dividerLine != .zero else { return false }
        return dividerReach.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let dividerArea { removeTrackingArea(dividerArea) }
        dividerArea = nil
        guard dividerLine != .zero else { return glow.hide() }
        let area = NSTrackingArea(rect: dividerReach, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        dividerArea = area
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        dividerMoved()
    }

    override func layout() {
        super.layout()
        dividerMoved()
    }

    override func mouseEntered(with event: NSEvent) { glow.pointer(isOn: isPointerOnDivider) }
    override func mouseExited(with event: NSEvent) { glow.pointer(isOn: isPointerOnDivider) }
}
