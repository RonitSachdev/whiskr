import AppKit
import SwiftUI
import WhiskrKit

/// The selected tab's panes, laid out by its split tree: real terminals with 1 pt dividers you drag
/// (an 8 pt reach), no headers, the panes you are not typing in dimmed a little (docs/DESIGN.md).
final class PaneArea: NSView {
    private let workbench: Workbench
    private var cards: [UUID: PaneCard] = [:]
    /// Pages shown in a tab instead of a terminal (`TabPage`), by their place in the tree.
    private var pageViews: [UUID: NSView] = [:]
    private var root: NSView?
    private var shownTab: Tab?
    private var shownShape = ""
    private var observer: Observing?

    init(workbench: Workbench) {
        self.workbench = workbench
        super.init(frame: .zero)
        observer = Observing { [weak self] in self?.update() }
        workbench.files.onFocusPage = { [weak self] id in
            guard let self, let page = self.pageViews[id], page.window != nil else { return }
            self.window?.makeFirstResponder(Self.focusTarget(of: page))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Panes", comment: "Accessibility label of the terminal area"))
    }

    required init?(coder: NSCoder) {
        fatalError("PaneArea is created in code")
    }

    override func layout() {
        super.layout()
        root?.frame = bounds
    }

    /// Rebuilds the views when what is shown changes shape; a divider drag only changes a ratio,
    /// which the split views already show.
    private func update() {
        let tab = workbench.selectedTab
        let alive = Set(workbench.panes.keys)
        let shown = tab.map { tab -> PaneTree in
            if let zoomed = tab.zoomedPane { return .pane(zoomed) }
            return tab.tree
        }
        let shape = shown.map { "\(tab!.id):\(Self.shape(of: $0))" } ?? ""
        for (id, card) in cards where !alive.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        for (id, view) in pageViews where workbench.pages[id] == nil {
            view.removeFromSuperview()
            pageViews[id] = nil
        }
        guard shape != shownShape || shownTab !== tab else { return }
        shownTab = tab
        shownShape = shape
        root?.removeFromSuperview()
        root = nil
        guard let tab, let shown else { return }
        let view = build(shown, path: [], tab: tab)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        root = view
        needsLayout = true
        if let page = pageViews[tab.focusedPane] {
            // A page takes the keys as a terminal does (the editor, a diff's table).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.workbench.selectedTab === tab, page.window != nil else { return }
                self.window?.makeFirstResponder(Self.focusTarget(of: page))
            }
        } else if let focused = workbench.panes[tab.focusedPane], window?.firstResponder !== focused.surface {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.workbench.selectedTab === tab, !focused.surface.isHiddenOrHasHiddenAncestor else { return }
                self.window?.makeFirstResponder(focused.surface)
            }
        }
    }

    private func build(_ tree: PaneTree, path: [Int], tab: Tab) -> NSView {
        switch tree {
        case .pane(let id):
            if let page = workbench.pages[id] {
                let view = pageViews[id] ?? pageView(page, id: id)
                pageViews[id] = view
                view.removeFromSuperview()
                return view
            }
            guard let pane = workbench.panes[id] else { return NSView() }
            let card = cards[id] ?? PaneCard(pane: pane, workbench: workbench)
            cards[id] = card
            card.removeFromSuperview()
            return card
        case .split(let split):
            let view = RatioSplitView(axis: split.axis, ratio: split.ratio) { [weak tab] ratio in
                guard let tab else { return }
                tab.tree = tab.tree.settingRatio(ratio, at: path)
            }
            view.addSubview(build(split.first, path: path + [0], tab: tab))
            view.addSubview(build(split.second, path: path + [1], tab: tab))
            return view
        }
    }

    private func pageView(_ page: TabPage, id: UUID) -> NSView {
        switch page {
        case .file(let path):
            return FilePageView(pageID: id, document: workbench.files.document(for: path), workbench: workbench)
        case .changes(let path, let staged):
            return DiffPageView(pageID: id, path: path, staged: staged, workbench: workbench)
        }
    }

    /// The view on screen for a page, if it has been built.
    func pageView(_ id: UUID) -> NSView? { pageViews[id] }

    /// What in a page takes the keyboard: the editor in a file, the table in a diff, the page itself else.
    static func focusTarget(of page: NSView) -> NSView {
        (page as? FilePageView)?.focusTarget ?? (page as? DiffPageView)?.focusTarget ?? page
    }

    /// The tree without its ratios: what decides whether views must be rebuilt.
    private static func shape(of tree: PaneTree) -> String {
        switch tree {
        case .pane(let id): id.uuidString
        case .split(let split): "\(split.axis.rawValue)(\(shape(of: split.first)),\(shape(of: split.second)))"
        }
    }
}

/// A split of two parts kept at a ratio as the window resizes; dragging the divider changes it. The
/// divider is drawn 1 pt wide and takes the pointer 8 pt wide.
final class RatioSplitView: NSSplitView, NSSplitViewDelegate {
    private var ratio: Double
    private let onRatio: (Double) -> Void

    init(axis: PaneTree.Axis, ratio: Double, onRatio: @escaping (Double) -> Void) {
        self.ratio = ratio
        self.onRatio = onRatio
        super.init(frame: .zero)
        isVertical = axis == .horizontal
        dividerStyle = .thin
        delegate = self
        setAccessibilityLabel(axis == .horizontal ? String(localized: "Side-by-side panes") : String(localized: "Stacked panes"))
    }

    required init?(coder: NSCoder) {
        fatalError("RatioSplitView is created in code")
    }

    override var dividerThickness: CGFloat { 1 }

    /// A click here is on the divider (the panes take their own): the drag is a live resize.
    override func mouseDown(with event: NSEvent) {
        LiveResize.shared.during { super.mouseDown(with: event) }
    }
    override var dividerColor: NSColor { Colors.line }

    private var length: CGFloat { (isVertical ? bounds.width : bounds.height) - dividerThickness }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        place()
    }

    private func place() {
        guard subviews.count == 2 else { return }
        let first = (length * ratio).rounded()
        if isVertical {
            subviews[0].frame = NSRect(x: 0, y: 0, width: first, height: bounds.height)
            subviews[1].frame = NSRect(x: first + dividerThickness, y: 0, width: bounds.width - first - dividerThickness, height: bounds.height)
        } else {
            subviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: first)
            subviews[1].frame = NSRect(x: 0, y: first + dividerThickness, width: bounds.width, height: bounds.height - first - dividerThickness)
        }
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        isVertical ? drawnRect.insetBy(dx: -3.5, dy: 0) : drawnRect.insetBy(dx: 0, dy: -3.5)
    }

    /// Called only while you drag a divider.
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let minimum: CGFloat = isVertical ? 160 : 80
        guard length > minimum * 2 else { return proposedPosition }
        let position = min(max(proposedPosition, minimum), length - minimum)
        ratio = Double(position / length)
        onRatio(ratio)
        return position
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
