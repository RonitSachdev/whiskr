import AppKit

/// A divider shows that it can be dragged as VS Code's do: once the pointer has rested on it for 300 ms
/// (passing over it shows nothing), it turns the accent colour, 3 pt wide, and stays so while it is
/// dragged. The resize cursor comes at once, from the divider's own cursor rectangle. Every divider in
/// the window uses this: the meadow's edge, the lines between panes, the side panel's edge.
///
/// The glow is a layer of the divider's view, placed from where the divider's line is now (`line`), and
/// placed again whenever the view says the divider moved (`follow`): in every frame of a drag, as the
/// window resizes, as a region opens. Placed once when a drag began, it stayed lit at the place the drag
/// started, a stripe of accent left behind.
@MainActor
final class DividerGlow {
    private let glow = CALayer()
    private var pending: DispatchWorkItem?
    private weak var host: NSView?
    /// Where the divider's line is now, in the host's coordinates (`.zero`: there is none).
    private let line: () -> NSRect
    /// A drag is under way: the glow stays lit whatever the pointer's enter and exit say (they come late,
    /// from tracking areas the drag has just moved), and decides once the drag is over.
    private var dragging = false
    /// The pointer's rest before the divider lights.
    static let delay: TimeInterval = 0.3
    static let width: CGFloat = 3
    /// The layer's name, which the harness finds it by (`DebugFlowResize`).
    static let layerName = "DividerGlow"

    /// Draws over `view`'s own content (its layer is made if it has none), along `line`.
    init(in view: NSView, line: @escaping () -> NSRect) {
        self.line = line
        view.wantsLayer = true
        host = view
        glow.name = Self.layerName
        // Over everything in the view, the split view's own divider line among it (AppKit draws that in a
        // layer of its own, at 5,000): the glow is the line, 3 pt wide, not two stripes beside it.
        glow.zPosition = 10_000
        glow.isHidden = true
        view.layer?.addSublayer(glow)
    }

    /// The pointer moved onto the divider or off it (any of the view's tracking areas said so; what counts
    /// is where the pointer is now, so an area the divider has just moved away from cannot light it, nor
    /// keep it lit): on it, lit after it has rested there, fading in; off it, put out.
    func pointer(isOn: Bool) {
        guard !dragging else { return }
        guard isOn else { return hide() }
        guard glow.isHidden, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.show(fading: true) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// A drag of the divider (`drag` is the view's own tracking loop, which returns when the mouse goes up),
    /// as a live resize: lit at once and following the divider throughout; afterwards lit only while
    /// `pointerOnDivider` still says so.
    func drag(_ drag: () -> Void, pointerOnDivider: () -> Bool) {
        show(fading: false)
        dragging = true
        LiveResize.shared.during(drag)
        dragging = false
        if pointerOnDivider() { follow() } else { hide() }
    }

    /// The divider moved (dragged, the window resized, a region opened or closed): the glow, if lit, goes
    /// with it, in the same frame.
    func follow() {
        guard !glow.isHidden else { return }
        place()
    }

    func hide() {
        pending?.cancel()
        pending = nil
        guard !glow.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.removeAllAnimations()
        glow.isHidden = true
        CATransaction.commit()
    }

    private func show(fading: Bool) {
        pending?.cancel()
        pending = nil
        let wasHidden = glow.isHidden
        guard place() else { return }
        guard wasHidden, fading else { return }
        // A quick fade in, as a control's own hover does; a drag lights it at once.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Look.Motion.quick
        fade.timingFunction = Look.Motion.curve
        glow.add(fade, forKey: "fade")
    }

    /// On the divider's line as it is now, lit. False when there is no divider to light.
    @discardableResult
    private func place() -> Bool {
        let line = line()
        guard let host, line != .zero else {
            hide()
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = line.width < line.height
            ? NSRect(x: line.midX - Self.width / 2, y: line.minY, width: Self.width, height: line.height)
            : NSRect(x: line.minX, y: line.midY - Self.width / 2, width: line.width, height: Self.width)
        host.effectiveAppearance.performAsCurrentDrawingAppearance { glow.backgroundColor = Colors.accent.cgColor }
        glow.isHidden = false
        CATransaction.commit()
        return true
    }
}
