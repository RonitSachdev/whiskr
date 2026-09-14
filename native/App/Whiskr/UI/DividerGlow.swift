import AppKit

/// A divider shows that it can be dragged as VS Code's do: once the pointer has rested on it for 300 ms
/// (passing over it shows nothing), it turns the accent colour, 3 pt wide, and stays so while it is
/// dragged. The resize cursor comes at once, from the divider's own cursor rectangle. Every divider in
/// the window uses this: the meadow's edge, the lines between panes, the side panel's edge.
@MainActor
final class DividerGlow {
    private let glow = CALayer()
    private var pending: DispatchWorkItem?
    private weak var host: NSView?
    /// The pointer's rest before the divider lights.
    static let delay: TimeInterval = 0.3
    static let width: CGFloat = 3

    /// Draws over `view`'s own content (its layer is made if it has none).
    init(in view: NSView) {
        view.wantsLayer = true
        host = view
        glow.zPosition = 1000
        glow.isHidden = true
        view.layer?.addSublayer(glow)
    }

    /// The pointer came onto the divider drawn in `line` (in the host's coordinates).
    func pointerEntered(_ line: NSRect) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(line) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// Lit at once (a drag began), along `line`.
    func show(_ line: NSRect) {
        pending?.cancel()
        pending = nil
        guard let host else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = line.width < line.height
            ? NSRect(x: line.midX - Self.width / 2, y: line.minY, width: Self.width, height: line.height)
            : NSRect(x: line.minX, y: line.midY - Self.width / 2, width: line.width, height: Self.width)
        host.effectiveAppearance.performAsCurrentDrawingAppearance { glow.backgroundColor = Colors.accent.cgColor }
        glow.isHidden = false
        CATransaction.commit()
    }

    func hide() {
        pending?.cancel()
        pending = nil
        guard !glow.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.isHidden = true
        CATransaction.commit()
    }
}
