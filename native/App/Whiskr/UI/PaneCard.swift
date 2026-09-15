import AppKit
import SwiftUI
import WhiskrKit

/// One pane: its terminal with a little room around the text. When its tab shows several panes it has a
/// header (`TerminalHeader`), the one you are typing in with the accent along its top, and the others fade a
/// little toward the background (`PaneFocusView`); a pane alone has no header. A helper's story takes the
/// boss's pane's place while you are looking at it.
final class PaneCard: NSView {
    let pane: Pane
    private let workbench: Workbench
    private let terminalHost = NSView()
    private let dim = PaneFocusView()
    /// The header, shown while the tab shows several panes; the terminal starts under it.
    private let header: PaneHeaderHost<TerminalHeader>
    private var underHeader: NSLayoutConstraint!
    private var atTop: NSLayoutConstraint!
    /// The terminal's room above its text: less under a header, which already sets it apart.
    private var textInset: NSLayoutConstraint?
    private var story: NSHostingView<StoryView>?
    private var observers: [Observing] = []
    /// The terminal follows the card's edges, except during a live resize (`LiveResize`), when it keeps
    /// its size and takes the new one once at the end.
    private var followEdges: [NSLayoutConstraint] = []
    private var keepSize: [NSLayoutConstraint] = []

    init(pane: Pane, workbench: Workbench) {
        self.pane = pane
        self.workbench = workbench
        header = PaneHeaderHost(rootView: TerminalHeader(workbench: workbench, pane: pane))
        super.init(frame: .zero)
        wantsLayer = true
        header.sizingOptions = []
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isHidden = true
        // A terminal held at its size during a live resize never draws past its pane.
        clipsToBounds = true
        terminalHost.clipsToBounds = true
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalHost)
        addSubview(header)
        dim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dim)
        atTop = terminalHost.topAnchor.constraint(equalTo: topAnchor)
        underHeader = terminalHost.topAnchor.constraint(equalTo: header.bottomAnchor)
        NSLayoutConstraint.activate([
            atTop,
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: FilePageView.headerHeight),
            terminalHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
        showSurface()
        observers.append(Observing { [weak self] in self?.updateLook() })
        observers.append(Observing { [weak self] in self?.updateStory() })
        NotificationCenter.default.addObserver(self, selector: #selector(liveResizeChanged), name: LiveResize.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(liveResizeChanged), name: TerminalSurface.replayingChanged, object: pane.surface)
        liveResizeChanged()
        // ⌘-click on a path the terminal printed opens it in the editor, at its line; its menu shows it in
        // Files or copies it.
        pane.surface.onOpenLink = { [weak self] link in
            guard let self else { return }
            self.workbench.openLink(link, folder: self.pane.currentFolder)
        }
        pane.surface.onLink = { [weak self] link, action in
            guard let self else { return }
            self.workbench.act(on: link, action, folder: self.pane.currentFolder)
        }
        pane.surface.linkResolves = { [weak self] link in
            guard let self else { return false }
            if case .file(let path, _, _) = link.target { return self.workbench.existingPath(of: path, folder: self.pane.currentFolder) != nil }
            return true
        }
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Dropping files

    /// Files dragged onto the terminal (from the Files panel or Finder) are typed as their paths, quoted
    /// for the shell, as Terminal does. Folders alone are left to the region (they open a workspace).
    private func droppedFiles(_ info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let allFolders = urls.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return allFolders ? [] : urls
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard !urls.isEmpty else { return false }
        pane.type(urls.map { ShellQuote.quote($0.path) }.joined(separator: " ") + " ")
        workbench.focus(pane: pane.id)
        return true
    }

    required init?(coder: NSCoder) {
        fatalError("PaneCard is created in code")
    }

    #if DEBUG
    /// Debug builds (`DebugFlowResize`): the header's place in the window while it is shown.
    var debugHeaderFrame: NSRect? { header.isHidden ? nil : header.convert(header.bounds, to: nil) }
    #endif

    private func showSurface() {
        let surface = pane.surface
        guard surface.superview !== terminalHost else { return }
        surface.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(surface)
        let inset = surface.topAnchor.constraint(equalTo: terminalHost.topAnchor, constant: header.isHidden ? 10 : 6)
        textInset = inset
        NSLayoutConstraint.activate([
            inset,
            surface.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor, constant: 12),
        ])
        followEdges = [
            surface.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor, constant: -4),
            surface.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(followEdges)
    }

    /// Held at its size while the window is being resized, and while kept output is drawn again.
    @objc private func liveResizeChanged() { followResize(LiveResize.shared.isActive || pane.surface.replaying) }

    private func followResize(_ live: Bool) {
        let surface = pane.surface
        guard surface.superview === terminalHost else { return }
        if live, keepSize.isEmpty {
            // The grid's own size: what the terminal has (a view not laid out yet has only a placeholder frame).
            let size = surface.gridFrameSize
            keepSize = [surface.widthAnchor.constraint(equalToConstant: size.width),
                        surface.heightAnchor.constraint(equalToConstant: size.height)]
            NSLayoutConstraint.deactivate(followEdges)
            NSLayoutConstraint.activate(keepSize)
        } else if !live, !keepSize.isEmpty {
            NSLayoutConstraint.deactivate(keepSize)
            keepSize = []
            NSLayoutConstraint.activate(followEdges)
        }
    }

    private func updateLook() {
        let place = workbench.workspace(of: pane.id)
        dim.state = place.map { PaneFocusView.State(tab: $0.1, pane: pane.id) } ?? .alone
        // A header only while the tab shows several panes; the terminal's grid is told its new size as the
        // room changes, as for any resize.
        let headed = dim.state != .alone
        if header.isHidden == headed {
            header.isHidden = !headed
            atTop.isActive = !headed
            underHeader.isActive = headed
            textInset?.constant = headed ? 6 : 10
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Colors.terminalBackground.cgColor
        }
        // Run again by a theme change too: the border and the veil take the new theme's colours.
        dim.needsDisplay = true
    }

    /// A helper of this pane's Claude was chosen in the meadow: its story is shown here, over the
    /// terminal, until you choose the pane again (Esc, a click on the boss, or the tab).
    private func updateStory() {
        let helper = workbench.focusedPane?.id == pane.id ? workbench.focusedAgent : nil
        if let helper, let session = workbench.session(of: pane) {
            if story == nil {
                let host = NSHostingView(rootView: StoryView(workbench: workbench, pane: pane, sessionID: session.id, agentID: helper))
                host.translatesAutoresizingMaskIntoConstraints = false
                addSubview(host)
                NSLayoutConstraint.activate([
                    host.topAnchor.constraint(equalTo: topAnchor),
                    host.leadingAnchor.constraint(equalTo: leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: trailingAnchor),
                    host.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                story = host
            } else {
                story?.rootView = StoryView(workbench: workbench, pane: pane, sessionID: session.id, agentID: helper)
            }
            terminalHost.isHidden = true
        } else {
            story?.removeFromSuperview()
            story = nil
            terminalHost.isHidden = false
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    /// A click anywhere on the pane focuses its terminal.
    override func mouseDown(with event: NSEvent) {
        workbench.focus(pane: pane.id)
    }

    // MARK: The pointer, for links under ⌘

    /// SwiftTerm keeps its own pointer handling closed to subclasses, so the card follows the pointer over
    /// its terminal and tells it, and watches ⌘ only while the pointer is there.
    private var pointerArea: NSTrackingArea?
    private var flagsMonitor: Any?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        // Its own bounds, not `.inVisibleRect`: views do not clip since macOS 14, so a visible rectangle can reach
        // over the neighbouring panes.
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        watchCommand()
        pointerChanged(command: event.modifierFlags.contains(.command))
    }

    /// Starts watching ⌘ while the pointer is over the pane.
    private func watchCommand() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.pointerChanged(command: event.modifierFlags.contains(.command))
            return event
        }
    }

    /// A pane shown again under a pointer that has not moved (its tab chosen with a key, or back from a file
    /// opened by ⌘-click) gets no `mouseEntered` until the pointer moves: it watches ⌘ at once, so ⌘ over a
    /// link underlines it as it did before the pane left.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        watchCommand()
    }

    override func mouseExited(with event: NSEvent) {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        pane.surface.pointerMoved(to: .zero, command: false)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Nothing to do unless ⌘ is held: plain pointer moves cost nothing.
        guard event.modifierFlags.contains(.command) || pane.surface.linkUnderline?.isHidden == false else { return }
        pointerChanged(command: event.modifierFlags.contains(.command))
    }

    private func pointerChanged(command: Bool) {
        guard let window else { return }
        let point = pane.surface.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        pane.surface.pointerMoved(to: point, command: command && pane.surface.bounds.contains(point))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }
}

/// Which pane takes the keys, over a pane or a page in a split: the others fade a tenth of the way to the
/// background, header and all, enough to recede, not enough to hinder reading (Ghostty's 30 % proved
/// heavy). The focused one is marked by the accent along its header's top (`paneHeaderFocus`), as the
/// selected tab is; a border round it read as a stray box. A pane alone shows neither. Clicks pass through.
final class PaneFocusView: NSView {
    enum State {
        case alone, focused, unfocused

        /// How a pane of a tab stands.
        @MainActor init(tab: Tab, pane: UUID) {
            guard tab.tree.panes.count > 1, tab.zoomedPane == nil else { self = .alone; return }
            self = tab.focusedPane == pane ? .focused : .unfocused
        }
    }

    var state: State = .alone {
        didSet {
            guard state != oldValue else { return }
            isHidden = state == .alone
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("PaneFocusView is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = state == .unfocused ? Colors.terminalBackground.withAlphaComponent(0.1).cgColor : nil
        }
    }
}
