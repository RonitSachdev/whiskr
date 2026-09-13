import AppKit
import SwiftUI
import WhiskrKit

/// The side panel on the terminal region's trailing edge (herdr's Files and Changes panels): a header
/// to switch between the two, then the workspace's file tree or its git changes. Its leading edge drags
/// to resize it; the width is kept per workspace.
final class SidePanelView: NSView {
    private let workbench: Workbench
    private let header: NSHostingView<PanelHeader>
    private let body = NSView()
    private let edge = PanelEdge()
    private var trees: [ObjectIdentifier: FileTreeView] = [:]
    private var changes: NSHostingView<ChangesView>?
    private var shownKey = ""
    private var observer: Observing?
    private var pendingReveal: URL?
    /// Called while the edge is dragged, with the width asked for.
    var onResize: ((CGFloat) -> Void)? {
        get { edge.onDrag }
        set { edge.onDrag = newValue }
    }

    static let headerHeight: CGFloat = 34

    init(workbench: Workbench) {
        self.workbench = workbench
        header = NSHostingView(rootView: PanelHeader(workbench: workbench))
        super.init(frame: .zero)
        header.sizingOptions = []
        wantsLayer = true
        for view in [header, body, edge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -3),
            edge.widthAnchor.constraint(equalToConstant: 7),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Files and Changes", comment: "Accessibility: the side panel"))
        observer = Observing { [weak self] in self?.update() }
    }

    required init?(coder: NSCoder) {
        fatalError("SidePanelView is created in code")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = PanelLook.background.cgColor
        }
        edge.needsDisplay = true
    }

    /// Shows the selected workspace's tree or changes.
    private func update() {
        _ = ThemeStore.shared.palette
        updateLook()
        guard let workspace = workbench.selectedWorkspace else { return }
        let panel = workbench.files.panel(workspace.id)
        let repository = workbench.files.repository(for: workspace)
        let key = "\(panel.mode.rawValue):\(ObjectIdentifier(repository).hashValue)"
        guard key != shownKey else { return }
        shownKey = key
        body.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch panel.mode {
        case .files:
            let tree = trees[ObjectIdentifier(repository)] ?? FileTreeView(repository: repository, workbench: workbench)
            trees[ObjectIdentifier(repository)] = tree
            view = tree
        case .changes:
            let host = changes ?? NSHostingView(rootView: ChangesView(workbench: workbench))
            host.sizingOptions = []
            changes = host
            view = host
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        applyReveal()
        // Trees of folders no workspace shows any more are let go.
        let open = Set(workbench.workspaces.map { ObjectIdentifier(workbench.files.repository(for: $0)) })
        for key in trees.keys where !open.contains(key) { trees[key] = nil }
    }

    /// Selects a file in the tree once it shows (it may be built a moment after the panel opens).
    func reveal(_ url: URL) {
        pendingReveal = url
        applyReveal()
        DispatchQueue.main.async { [weak self] in self?.applyReveal() }
    }

    private func applyReveal() {
        guard let url = pendingReveal, let tree = fileTree, tree.superview != nil else { return }
        pendingReveal = nil
        tree.reveal(url)
    }

    /// The tree of the selected workspace, when it shows.
    var fileTree: FileTreeView? {
        guard let workspace = workbench.selectedWorkspace else { return nil }
        return trees[ObjectIdentifier(workbench.files.repository(for: workspace))]
    }

    override func draw(_ dirtyRect: NSRect) {
        PanelLook.line.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override var wantsUpdateLayer: Bool { false }
}

/// The panel's colours: a shade off the terminal, as the tab bar is, so it reads as part of the region.
enum PanelLook {
    static var background: NSColor {
        NSColor(name: nil) { appearance in
            let terminal = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(appearance)).terminal
            return Palette.nsColor(terminal.background.mixed(with: terminal.foreground, terminal.isDark ? 0.035 : 0.03))
        }
    }

    static var line: NSColor { Colors.line }
}

/// The 7 pt strip along the panel's leading edge that resizes it.
final class PanelEdge: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = superview else { return }
        startX = event.locationInWindow.x
        startWidth = panel.frame.width
        LiveResize.shared.during {
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                onDrag?(startWidth + (startX - next.locationInWindow.x))
            }
        }
    }
}

/// Files | Changes, with the count of changed files, and the tree's own tools on the right.
private struct PanelHeader: View {
    let workbench: Workbench

    var body: some View {
        let workspace = workbench.selectedWorkspace
        let mode = workspace.map { workbench.files.panel($0.id).mode } ?? .files
        let repository = workbench.selectedRepository
        let count = repository?.status?.changeCount ?? 0
        HStack(spacing: 2) {
            PanelTab(title: String(localized: "Files", comment: "Side panel tab"), count: nil, selected: mode == .files, key: "⇧⌘E") { select(.files) }
            PanelTab(title: String(localized: "Changes", comment: "Side panel tab"), count: count > 0 ? count : nil, selected: mode == .changes, key: "⇧⌘C") { select(.changes) }
            Spacer(minLength: 4)
            if mode == .files {
                HeaderButton(symbol: "doc.badge.plus", help: String(localized: "New File (⌥⌘N)")) {
                    NSApp.sendAction(#selector(MainWindowController.newFile(_:)), to: nil, from: nil)
                }
                HeaderButton(symbol: "folder.badge.plus", help: String(localized: "New Folder")) {
                    NSApp.sendAction(#selector(MainWindowController.newFolder(_:)), to: nil, from: nil)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: PanelLook.background))
        .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
    }

    private func select(_ mode: FilesCenter.Panel.Mode) {
        guard let workspace = workbench.selectedWorkspace else { return }
        workbench.files.setPanel(workspace.id) { $0.mode = mode }
        workbench.scheduleSave()
    }
}

private struct PanelTab: View {
    let title: String
    let count: Int?
    let selected: Bool
    let key: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.ink : Color.ink2)
                    .fixedSize()
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.ink2)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 15)
                        .background(Capsule().fill(Color.primary.opacity(0.09)))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected ? 0.08 : hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(title) (\(key))")
        .accessibilityLabel(count.map { String(localized: "\(title), \($0) changed files") } ?? title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Git's states in the theme's ANSI colours (readable on the panel in light and dark): modified yellow,
/// new green, deleted red, renamed blue.
enum GitColors {
    static func color(_ state: GitFileState) -> NSColor {
        NSColor(name: nil) { appearance in
            let terminal = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(appearance)).terminal
            let index = switch state {
            case .added, .untracked: 2
            case .deleted, .conflicted: 1
            case .renamed, .copied: 4
            default: 3
            }
            return Palette.nsColor(terminal.ansi[index].ensuring(contrast: 3, with: terminal.background, movingTo: terminal.foreground))
        }
    }

    /// The state in words, for VoiceOver and tooltips.
    static func name(_ state: GitFileState) -> String {
        switch state {
        case .modified: String(localized: "modified", comment: "Git state")
        case .added: String(localized: "added", comment: "Git state")
        case .deleted: String(localized: "deleted", comment: "Git state")
        case .renamed: String(localized: "renamed", comment: "Git state")
        case .copied: String(localized: "copied", comment: "Git state")
        case .typeChanged: String(localized: "type changed", comment: "Git state")
        case .untracked: String(localized: "untracked", comment: "Git state")
        case .ignored: String(localized: "ignored", comment: "Git state")
        case .conflicted: String(localized: "in conflict", comment: "Git state")
        case .unmodified: ""
        }
    }
}
