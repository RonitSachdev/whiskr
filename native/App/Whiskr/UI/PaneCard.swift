import AppKit
import SwiftUI
import WhiskrKit

/// One pane: its terminal with a little room around the text, no header. When its tab has
/// several panes, the ones you are not typing in are dimmed by 15 %. A helper's story takes the boss's
/// pane's place while you are looking at it.
final class PaneCard: NSView {
    let pane: Pane
    private let workbench: Workbench
    private let terminalHost = NSView()
    private let dim = DimView()
    private var story: NSHostingView<StoryView>?
    private var observers: [Observing] = []
    /// The terminal follows the card's edges, except during a live resize (`LiveResize`), when it keeps
    /// its size and takes the new one once at the end.
    private var followEdges: [NSLayoutConstraint] = []
    private var keepSize: [NSLayoutConstraint] = []

    init(pane: Pane, workbench: Workbench) {
        self.pane = pane
        self.workbench = workbench
        super.init(frame: .zero)
        wantsLayer = true
        // A terminal held at its size during a live resize never draws past its pane.
        clipsToBounds = true
        terminalHost.clipsToBounds = true
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalHost)
        dim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dim)
        NSLayoutConstraint.activate([
            terminalHost.topAnchor.constraint(equalTo: topAnchor),
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
        // ⌘-click on a path the terminal printed opens it in the editor, at its line.
        pane.surface.onOpenLink = { [weak self] link in
            guard let self else { return }
            self.workbench.openLink(link, folder: self.pane.currentFolder)
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

    private func showSurface() {
        let surface = pane.surface
        guard surface.superview !== terminalHost else { return }
        surface.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: terminalHost.topAnchor, constant: 10),
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
        let unfocused = place.map { $0.1.tree.panes.count > 1 && $0.1.zoomedPane == nil && $0.1.focusedPane != pane.id } ?? false
        dim.isHidden = !unfocused
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Colors.terminalBackground.cgColor
        }
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
}

/// The 15 % veil over a pane you are not typing in; clicks pass through to the terminal below.
final class DimView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("DimView is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = (Palette.isDark(effectiveAppearance) ? NSColor.black : NSColor.white).withAlphaComponent(0.15).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}
