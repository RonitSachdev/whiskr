import AppKit
import QuartzCore
import SwiftUI
import WhiskrKit

/// A tab being dragged, as the tab row draws it (`TabCells`): its picture leaves the row while it is held
/// (`TabDragging` draws it under the pointer), the others part where it would land (`slot`, its place among
/// them) or close up when it would leave the row (nil), and it stays out of sight until the held picture
/// has landed in its place.
@MainActor
@Observable
final class TabDragState {
    static let shared = TabDragState()

    /// The tab held.
    var tab: UUID?
    /// Where it would land in the row, among the workspace's other tabs; nil when it would leave the row.
    var slot: Int?
    /// Dropped, and drawn by the held picture until that has landed where the tab now is.
    var landing: UUID?

    var isDragging: Bool { tab != nil }
}

/// Dragging a tab (docs/DESIGN.md, "Tabs"): picked up past a few points of movement, the tab (a split tab
/// as one, all its panes) lifts and hangs from the pointer where it was grabbed, a little larger, with a
/// shadow, trailing the pointer on a spring and swinging a few degrees with its speed. What a drop would do
/// is shown before the button comes up, in place: over the tab row the other tabs part where it would
/// land; over a pane a tinted rounded area is exactly the part of the pane it would take (a half to split
/// beside it, or the whole pane to take that tab's place in the row), labelled in words, gliding from zone
/// to zone; over another workspace's blanket in the meadow, the blanket is marked, "Move to “name”".
/// Anywhere else, or on its own panes, the held tab fades: it cannot be dropped there. Dropped, it springs
/// into where it went; let go where it cannot go (or Esc), it springs back to where it came from.
///
/// The drag is the app's own, not a drag session: AppKit's would draw a still picture the system moves,
/// with none of this. The mouse is followed by a local monitor from the press on (the tab's view may be
/// rebuilt under it), and the pictures are Core Animation layers above the whole window
/// (`TabDragOverlay`), stepped on the display's own beat. With Reduce Motion the tab follows the pointer
/// exactly, nothing swings or springs, and it fades where it lands.
@MainActor
final class TabDragging {
    static let shared = TabDragging()

    /// The window's controller: where the row, the panes and the meadow are.
    weak var controller: MainWindowController?

    /// What a drop would do, where the pointer is now.
    enum Target: Equatable {
        /// Nothing: let go here, the tab goes back.
        case none
        /// On the tab's own panes: nothing would change.
        case own
        /// Into the row, at this place among the other tabs.
        case row(Int)
        /// Beside a pane, on a side: `area` is the part of the pane it would take, in the window.
        case split(leaf: UUID, side: PaneTree.Direction, area: NSRect)
        /// In a pane's middle: the tab takes that pane's tab's place in the row, and shows.
        case move(leaf: UUID, area: NSRect)
        /// Onto another workspace's blanket.
        case workspace(UUID, area: NSRect)
    }

    private final class Session {
        let tab: Tab
        let source: Workspace
        let window: NSWindow
        /// The tab's place among the other tabs when it was picked up.
        let from: Int
        var target: Target = .none
        /// Where the pointer was over a pane, to steady the zone at its boundaries.
        var zone: (leaf: UUID, zone: PaneTree.DropZone)?
        var pointer: NSPoint
        var monitor: Any?
        var observers: [NSObjectProtocol] = []

        init(tab: Tab, source: Workspace, window: NSWindow, from: Int, pointer: NSPoint) {
            self.tab = tab
            self.source = source
            self.window = window
            self.from = from
            self.pointer = pointer
        }
    }

    private var session: Session?
    private(set) var overlay: TabDragOverlay?

    private var workbench: Workbench? { controller?.workbench }

    // MARK: Picking up

    /// The tab's view saw the pointer move past the drag distance with the button down. `grabbedAt` is
    /// where the press was (in the window); `showBefore` brings back the tab shown before the press, so
    /// the tab can be dropped beside that tab's panes.
    func begin(tab id: UUID, from view: TabMouseView, event: NSEvent, grabbedAt press: NSPoint, showBefore: @escaping () -> Void) {
        guard let window = view.window, let content = window.contentView, let workbench,
              let source = workbench.workspaces.first(where: { $0.tabs.contains { $0.id == id } }),
              let tab = source.tabs.first(where: { $0.id == id }), let from = source.tabs.firstIndex(where: { $0 === tab }) else { return }
        // A drag begun while the last one is still landing: that one is where it went, at once. (One still held
        // cannot be: its release would have come first; if it was lost, that one goes back.)
        if self.session != nil { cancel() }
        finishLanding()
        let frame = view.convert(view.bounds, to: nil)
        let picture = Self.picture(of: view)
        let overlay = TabDragOverlay(frame: content.bounds)
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
        overlay.hold(picture, frame: frame, grab: NSPoint(x: press.x - frame.minX, y: press.y - frame.minY), pointer: event.locationInWindow)
        let session = Session(tab: tab, source: source, window: window, from: from, pointer: event.locationInWindow)
        self.session = session
        let state = TabDragState.shared
        state.landing = nil
        state.tab = id
        state.slot = from
        showBefore()
        session.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.session != nil else { return event }
            switch event.type {
            case .leftMouseDown:
                // A press while one is held: the release was lost (the app left with the button down). The tab
                // goes back, and the press does what it does.
                self.cancel()
                return event
            case .leftMouseDragged:
                self.moved(to: event.locationInWindow)
            case .leftMouseUp:
                self.drop()
            case .keyDown where event.keyCode == 53:
                self.cancel()
            default:
                return event
            }
            return nil
        }
        overlay.onFrame = { [weak self] in self?.frame() }
        // The app put away, or the window gone, mid-drag: the tab goes back rather than wait for a release
        // that may never come here.
        let center = NotificationCenter.default
        session.observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            },
            center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            },
        ]
        moved(to: event.locationInWindow)
    }

    /// The tab as the row draws it, for the held picture: from the row's hosting view, which draws it (the
    /// view right above the tab's own is only its frame).
    private static func picture(of view: TabMouseView) -> NSImage? {
        var host = view.superview
        while let each = host, !(each is NSHostingView<TabStrip>) { host = each.superview }
        guard let host = host ?? view.superview else { return nil }
        let rect = view.convert(view.bounds, to: host)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        host.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Following the pointer

    private func moved(to point: NSPoint) {
        guard let session else { return }
        session.pointer = point
        overlay?.follow(point)
        retarget()
    }

    /// Each frame: the target again (a pane may have closed, the window changed size, the tab gone).
    private func frame() {
        guard let session, let workbench else { return }
        guard workbench.workspaces.contains(where: { $0.tabs.contains { $0 === session.tab } }) else { return end(landing: nil) }
        retarget()
    }

    private func retarget() {
        guard let session, let controller, let overlay else { return }
        let target = target(at: session.pointer, session: session, controller: controller)
        guard target != session.target else { return }
        session.target = target
        let state = TabDragState.shared
        switch target {
        case .row(let slot): state.slot = slot
        case .move(let leaf, _): state.slot = rowSlot(ofLeaf: leaf, session: session) ?? session.from
        case .split, .workspace: state.slot = nil
        case .none, .own: state.slot = session.from
        }
        let panes = controller.terminals.paneArea.map { $0.convert($0.bounds, to: nil) }
        switch target {
        case .split(_, let side, let area):
            overlay.show(zone: area, label: Self.label(side), symbol: Self.symbol(side), dim: panes)
        case .move(_, let area):
            overlay.show(zone: area, label: String(localized: "Move Here", comment: "Dragging a tab over a pane's middle: it takes that tab's place"),
                         symbol: "arrow.down.to.line", dim: panes)
        case .workspace(let id, let area):
            let name = workbench?.workspaces.first { $0.id == id }?.name ?? ""
            overlay.show(zone: area, label: String(localized: "Move to “\(name)”", comment: "Dragging a tab over another workspace's blanket"),
                         symbol: "arrow.right.square", dim: nil)
        case .row, .none, .own:
            overlay.show(zone: nil, label: nil, symbol: nil, dim: nil)
        }
        overlay.refused = target == .none || target == .own
    }

    private static func label(_ side: PaneTree.Direction) -> String {
        switch side {
        case .left: String(localized: "Split Left", comment: "Dragging a tab over a pane's left edge")
        case .right: String(localized: "Split Right", comment: "Dragging a tab over a pane's right edge")
        case .up: String(localized: "Split Up", comment: "Dragging a tab over a pane's top edge")
        case .down: String(localized: "Split Down", comment: "Dragging a tab over a pane's bottom edge")
        }
    }

    private static func symbol(_ side: PaneTree.Direction) -> String {
        switch side {
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .up: "rectangle.tophalf.inset.filled"
        case .down: "rectangle.bottomhalf.inset.filled"
        }
    }

    /// What a drop at `point` (in the window) would do.
    private func target(at point: NSPoint, session: Session, controller: MainWindowController) -> Target {
        guard let workbench, workbench.selectedWorkspace === session.source else { return .none }
        // Over the row (and the bars above it): a place in the row.
        if let row = controller.terminals.tabRow {
            let rect = row.convert(row.bounds, to: nil)
            if point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY - 6, point.y <= rect.maxY + Look.Height.topBar {
                return .row(rowSlot(at: point.x, row: row, session: session))
            }
        }
        if let area = controller.terminals.paneArea, !area.isHiddenOrHasHiddenAncestor,
           let found = area.dropTarget(at: point, after: session.zone) {
            session.zone = (found.leaf, found.side.map { .side($0) } ?? .middle)
            if session.tab.tree.contains(found.leaf) { return .own }
            if let side = found.side { return .split(leaf: found.leaf, side: side, area: found.area) }
            return .move(leaf: found.leaf, area: found.area)
        }
        session.zone = nil
        if let (workspace, rect) = controller.navigator.blanket(at: point), workspace !== session.source {
            return .workspace(workspace.id, area: rect)
        }
        return .none
    }

    /// The place among the other tabs that the pointer at `x` is over: before the first tab in sight whose
    /// middle is past it, else after the last.
    private func rowSlot(at x: CGFloat, row: NSView, session: Session) -> Int {
        let others = session.source.tabs.filter { $0 !== session.tab }
        var views: [(index: Int, frame: NSRect)] = []
        func walk(_ view: NSView) {
            if let tab = view as? TabMouseView, !tab.isHiddenOrHasHiddenAncestor, let index = others.firstIndex(where: { $0.id == tab.tab }) {
                views.append((index, tab.convert(tab.bounds, to: nil)))
            }
            view.subviews.forEach(walk)
        }
        walk(row)
        views.sort { $0.frame.minX < $1.frame.minX }
        if let past = views.first(where: { $0.frame.midX > x }) { return past.index }
        return (views.last?.index).map { $0 + 1 } ?? 0
    }

    /// Where the tab would go in the row when dropped in this pane's middle: that pane's tab's place.
    private func rowSlot(ofLeaf leaf: UUID, session: Session) -> Int? {
        session.source.tabs.filter { $0 !== session.tab }.firstIndex { $0.tree.contains(leaf) }
    }

    // MARK: Letting go

    private func drop() {
        guard let session, let workbench else { return end(landing: nil) }
        let tab = session.tab
        switch session.target {
        case .row(let slot):
            workbench.move(tab: tab, toIndex: slot >= session.from ? slot + 1 : slot)
            workbench.select(tab: tab)
            end(landing: .row)
        case .move(let leaf, _):
            workbench.dropTab(tab, onto: leaf, side: nil)
            end(landing: .row)
        case .split(let leaf, let side, let area):
            workbench.dropTab(tab, onto: leaf, side: side)
            end(landing: .into(area))
        case .workspace(let id, let area):
            if let target = workbench.workspaces.first(where: { $0.id == id }) { workbench.move(tab: tab, to: target) }
            end(landing: .into(area))
        case .none, .own:
            cancel()
        }
    }

    /// Esc, or let go where it cannot go: back to its place.
    private func cancel() {
        guard session != nil else { return }
        TabDragState.shared.slot = session?.from
        end(landing: .row)
    }

    private enum Landing {
        /// Into its place in the row (where it went, or back where it came from).
        case row
        /// Into the part of a pane it became, or a blanket: it shrinks there and fades.
        case into(NSRect)
    }

    private func end(landing: Landing?) {
        guard let session else { return }
        if let monitor = session.monitor { NSEvent.removeMonitor(monitor) }
        session.observers.forEach(NotificationCenter.default.removeObserver)
        self.session = nil
        let state = TabDragState.shared
        let id = session.tab.id
        state.slot = nil
        state.tab = nil
        guard let overlay, let landing else { return finishLanding() }
        overlay.onFrame = nil
        overlay.show(zone: nil, label: nil, symbol: nil, dim: nil)
        switch landing {
        case .row:
            state.landing = id
            // Laid out now: the tab's place in the row is where it lands.
            session.window.contentView?.layoutSubtreeIfNeeded()
            let place = tabFrame(id, in: session.window)
            overlay.land(at: place) { [weak self] in self?.finishLanding() }
        case .into(let area):
            overlay.land(into: area) { [weak self] in self?.finishLanding() }
        }
        // A landing whose frames stop (the window put away mid-flight) ends anyway: the tab is never left out
        // of sight.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak overlay] in
            guard let self, let overlay, self.overlay === overlay else { return }
            self.finishLanding()
        }
    }

    /// The tab's place in the row, in the window, once laid out; nil when it is out of sight.
    private func tabFrame(_ id: UUID, in window: NSWindow) -> NSRect? {
        guard let row = controller?.terminals.tabRow else { return nil }
        var found: NSRect?
        func walk(_ view: NSView) {
            if found == nil, let tab = view as? TabMouseView, tab.tab == id, !tab.isHiddenOrHasHiddenAncestor { found = tab.convert(tab.bounds, to: nil) }
            view.subviews.forEach(walk)
        }
        walk(row)
        return found
    }

    /// The landing is over (or cut short): nothing of the drag is left on screen.
    private func finishLanding() {
        overlay?.stop()
        overlay?.removeFromSuperview()
        overlay = nil
        if TabDragState.shared.landing != nil { TabDragState.shared.landing = nil }
    }

    #if DEBUG
    /// Debug builds: what a drop would do now, and whether a drag (or its landing) is under way.
    var debugTarget: Target? { session?.target }
    var debugActive: Bool { session != nil || overlay != nil }
    #endif
}

/// The pictures of a drag, above the whole window: the held tab, the tinted area a drop would take with
/// its label, and a slight veil over the panes while a drop on them is shown. Core Animation layers, set
/// each frame by springs (`step`), never laid out; the view takes no click.
final class TabDragOverlay: NSView {
    /// Called each frame while the tab is held.
    var onFrame: (() -> Void)?
    /// The held tab cannot be dropped where it is: it fades a little.
    var refused = false

    private let veil = CALayer()
    private let zone = CALayer()
    private let label = CALayer()
    private let held = CALayer()
    private let picture = CALayer()
    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    // The springs: the held tab's place (its grab point), its swing, its size and its fade; the zone's frame.
    private var position = Spring2()
    private var tilt = Spring1()
    private var scale = Spring1(value: 1)
    private var opacity = Spring1(value: 1)
    private var area = SpringRect()
    private var zoneShown = Spring1()
    private var veilShown = Spring1()
    private var pointer = NSPoint.zero
    private var landing: (() -> Void)?
    /// Landing into a pane or a blanket rather than a place in the row: it shrinks and fades.
    private var fadesAway = false
    private var labelText: String?

    private var moves: Bool { Look.Motion.moves }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for part in [veil, zone, label, held] { layer?.addSublayer(part) }
        veil.opacity = 0
        zone.opacity = 0
        label.opacity = 0
        zone.cornerRadius = Look.Radius.card
        zone.borderWidth = 1.5
        label.contentsGravity = .center
        held.addSublayer(picture)
        held.shadowOpacity = 0.28
        held.shadowRadius = 14
        held.shadowOffset = CGSize(width: 0, height: -6)
        picture.cornerRadius = Look.Radius.control
        picture.masksToBounds = true
        picture.contentsGravity = .resize
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("TabDragOverlay is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: What the drag asks for

    func hold(_ image: NSImage?, frame: NSRect, grab: NSPoint, pointer: NSPoint) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            zone.backgroundColor = Colors.accent.withAlphaComponent(0.1).cgColor
            zone.borderColor = Colors.accent.withAlphaComponent(0.85).cgColor
            veil.backgroundColor = NSColor.black.withAlphaComponent(Palette.isDark(effectiveAppearance) ? 0.12 : 0.04).cgColor
            picture.backgroundColor = Colors.chrome.cgColor
        }
        let scaleFactor = window?.backingScaleFactor ?? 2
        picture.contents = image?.layerContents(forContentsScale: scaleFactor)
        picture.contentsScale = scaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        held.bounds = CGRect(origin: .zero, size: frame.size)
        held.anchorPoint = CGPoint(x: grab.x / max(frame.width, 1), y: grab.y / max(frame.height, 1))
        picture.frame = held.bounds
        held.position = CGPoint(x: frame.minX + grab.x, y: frame.minY + grab.y)
        CATransaction.commit()
        position = Spring2(value: held.position)
        self.pointer = pointer
        scale = Spring1(value: 1)
        opacity = Spring1(value: 1)
        start()
    }

    func follow(_ point: NSPoint) { pointer = point }

    /// The tinted area a drop would take, with its label, and the veil over the panes; nil for none.
    func show(zone rect: NSRect?, label text: String?, symbol: String?, dim: NSRect?) {
        if let rect {
            let inset = rect.insetBy(dx: 2, dy: 2)
            // Appearing, it is where it is at once and fades in; moving between zones, it glides.
            if zoneShown.target == 0 || zoneShown.value < 0.05 || !moves { area = SpringRect(value: inset) } else { area.target = inset }
            zoneShown.target = 1
        } else {
            zoneShown.target = 0
        }
        if text != labelText {
            labelText = text
            if let text, let image = pill(text, symbol: symbol) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                label.contents = image.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
                label.contentsScale = window?.backingScaleFactor ?? 2
                label.bounds = CGRect(origin: .zero, size: image.size)
                CATransaction.commit()
            }
        }
        if let dim {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            veil.frame = dim
            CATransaction.commit()
        }
        veilShown.target = dim == nil ? 0 : 1
    }

    /// Lands in the row at `frame` (where the tab now is; nil when it is out of sight: it fades there).
    func land(at frame: NSRect?, done: @escaping () -> Void) {
        landing = done
        refused = false
        guard let frame else {
            fadesAway = true
            return
        }
        // The grab point, at the place it lands.
        let anchor = held.anchorPoint
        pointer = NSPoint(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height)
        fadesAway = false
    }

    /// Lands into `rect` (the pane it became, the blanket it went to): it shrinks toward its middle and fades.
    func land(into rect: NSRect, done: @escaping () -> Void) {
        landing = done
        refused = false
        fadesAway = true
        pointer = NSPoint(x: rect.midX, y: rect.midY)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    // MARK: Each frame

    private func start() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        last = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(max(now - (last ?? now - 1.0 / 120), 1.0 / 240), 1.0 / 30)
        last = now
        onFrame?()
        step(CGFloat(dt))
    }

    /// The springs, one step: the held tab trails its grab point toward the pointer (critically damped
    /// enough to settle without a wobble), swings with its speed across, lifts a little; the zone glides.
    private func step(_ dt: CGFloat) {
        let landed = landing != nil
        let lifted: CGFloat = landed ? (fadesAway ? 0.55 : 1) : 1.03
        let shown: CGFloat = landed ? (fadesAway ? 0 : 1) : (refused ? 0.5 : 0.94)
        if moves {
            // Two half steps: steady at 30 frames a second as at 120.
            for _ in 0..<2 {
                position.step(toward: pointer, omega: landed ? 26 : 34, zeta: 0.92, dt: dt / 2)
                tilt.step(toward: landed ? 0 : max(-0.07, min(0.07, -position.velocity.x * 0.00005)), omega: 18, zeta: 1, dt: dt / 2)
                scale.step(toward: lifted, omega: 30, zeta: 1, dt: dt / 2)
                opacity.step(toward: shown, omega: fadesAway ? 22 : 30, zeta: 1, dt: dt / 2)
                area.step(omega: 36, zeta: 1, dt: dt / 2)
                zoneShown.step(toward: zoneShown.target, omega: 34, zeta: 1, dt: dt / 2)
                veilShown.step(toward: veilShown.target, omega: 30, zeta: 1, dt: dt / 2)
            }
        } else {
            // Reduce Motion: where it is asked to be, at once; only fades.
            position = Spring2(value: landed && !fadesAway ? pointer : (landed ? position.value : pointer))
            tilt = Spring1()
            scale = Spring1(value: 1)
            opacity.value += (shown - opacity.value) * min(1, dt * 14)
            area = SpringRect(value: area.target)
            zoneShown.value += (zoneShown.target - zoneShown.value) * min(1, dt * 14)
            veilShown.value += (veilShown.target - veilShown.value) * min(1, dt * 14)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        held.position = position.value
        held.transform = CATransform3DRotate(CATransform3DMakeScale(scale.value, scale.value, 1), tilt.value, 0, 0, 1)
        held.opacity = Float(max(0, min(1, opacity.value)))
        zone.frame = area.value
        zone.opacity = Float(max(0, min(1, zoneShown.value)))
        label.position = labelPlace()
        label.opacity = zone.opacity
        veil.opacity = Float(max(0, min(1, veilShown.value)))
        CATransaction.commit()
        #if DEBUG
        TabDragOverlay.samples.append(Sample(at: CACurrentMediaTime(), pointer: pointer, position: position.value, tilt: tilt.value,
                                             opacity: opacity.value, zone: zoneShown.value > 0.5 ? area.value : nil))
        if TabDragOverlay.samples.count > 4000 { TabDragOverlay.samples.removeFirst(1000) }
        #endif
        guard let landing else { return }
        let still = hypot(position.value.x - pointer.x, position.value.y - pointer.y) < 0.5 && hypot(position.velocity.x, position.velocity.y) < 20
        let settled = fadesAway ? opacity.value < 0.02 : (still && abs(scale.value - 1) < 0.002 && abs(tilt.value) < 0.002)
        if settled && zoneShown.value < 0.02 {
            self.landing = nil
            landing()
        }
    }

    /// Where the label goes: the middle of the area, unless the held tab is there (a drop in a pane's middle,
    /// on a blanket), then just under the tab, inside the area while it has the room.
    private func labelPlace() -> CGPoint {
        let zone = area.value, held = position.value
        var place = CGPoint(x: zone.midX, y: zone.midY)
        guard abs(held.x - place.x) < 140, abs(held.y - place.y) < 60 else { return place }
        place.y = held.y - 52
        // Too low for the area (a blanket): under the area.
        if place.y - label.bounds.height / 2 < zone.minY { place.y = zone.minY - label.bounds.height / 2 - 4 }
        return place
    }

    /// The label: an icon and the words, on the surface's colour with a line round it, as the window's
    /// other floating notes are.
    private func pill(_ text: String, symbol: String?) -> NSImage? {
        var image: NSImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Color.ink)]
            let words = NSAttributedString(string: text, attributes: attributes)
            let icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [Colors.accent]))) }
            let iconWidth = icon.map { $0.size.width + 6 } ?? 0
            let size = NSSize(width: (words.size().width + iconWidth + 24).rounded(.up), height: 28)
            let pillImage = NSImage(size: NSSize(width: size.width + 16, height: size.height + 16), flipped: false) { _ in
                let body = NSRect(x: 8, y: 9, width: size.width, height: size.height)
                let shape = NSBezierPath(roundedRect: body, xRadius: size.height / 2, yRadius: size.height / 2)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 6
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.set()
                Colors.surface.setFill()
                shape.fill()
                NSGraphicsContext.restoreGraphicsState()
                Colors.line.setStroke()
                shape.lineWidth = 1
                shape.stroke()
                var x = body.minX + 12
                if let icon {
                    icon.draw(in: NSRect(x: x, y: body.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
                    x += iconWidth
                }
                words.draw(at: NSPoint(x: x, y: body.midY - words.size().height / 2))
                return true
            }
            image = pillImage
        }
        return image
    }

    #if DEBUG
    /// Debug builds (`DebugFlowSplit`): each frame's springs, for the drag checks.
    struct Sample {
        let at: CFTimeInterval
        let pointer: NSPoint
        let position: NSPoint
        let tilt: CGFloat
        let opacity: CGFloat
        let zone: NSRect?
    }

    static var samples: [Sample] = []
    #endif
}

/// One value on a spring.
private struct Spring1 {
    var value: CGFloat = 0
    var velocity: CGFloat = 0
    var target: CGFloat = 0

    init(value: CGFloat = 0) {
        self.value = value
        target = value
    }

    mutating func step(toward goal: CGFloat, omega: CGFloat, zeta: CGFloat, dt: CGFloat) {
        let acceleration = omega * omega * (goal - value) - 2 * zeta * omega * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }
}

/// A point on a spring.
private struct Spring2 {
    var value: CGPoint = .zero
    var velocity: CGPoint = .zero

    init(value: CGPoint = .zero) { self.value = value }

    mutating func step(toward goal: CGPoint, omega: CGFloat, zeta: CGFloat, dt: CGFloat) {
        var x = Spring1(value: value.x), y = Spring1(value: value.y)
        x.velocity = velocity.x
        y.velocity = velocity.y
        x.step(toward: goal.x, omega: omega, zeta: zeta, dt: dt)
        y.step(toward: goal.y, omega: omega, zeta: zeta, dt: dt)
        value = CGPoint(x: x.value, y: y.value)
        velocity = CGPoint(x: x.velocity, y: y.velocity)
    }
}

/// A rectangle on a spring, gliding to `target`.
private struct SpringRect {
    private var origin = Spring2()
    private var size = Spring2()
    var target: CGRect

    init(value: CGRect = .zero) {
        origin = Spring2(value: value.origin)
        size = Spring2(value: CGPoint(x: value.width, y: value.height))
        target = value
    }

    var value: CGRect { CGRect(x: origin.value.x, y: origin.value.y, width: max(size.value.x, 0), height: max(size.value.y, 0)) }

    mutating func step(omega: CGFloat, zeta: CGFloat, dt: CGFloat) {
        origin.step(toward: target.origin, omega: omega, zeta: zeta, dt: dt)
        size.step(toward: CGPoint(x: target.width, y: target.height), omega: omega, zeta: zeta, dt: dt)
    }
}
