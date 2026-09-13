import AppKit

/// Whether the window, or a divider in it, is being dragged to a new size right now. While it is,
/// terminals keep the size they had and take the new one once, when the drag ends: a terminal with a
/// long scrollback re-wraps every line it holds on each change of width (150 ms for 12,000 lines,
/// measured), which no drag can afford sixty times a second.
///
/// Changes are posted at once (`changed`), not through observation, which would come a turn of the run
/// loop too late for a drag's tracking loop.
@MainActor
final class LiveResize {
    static let shared = LiveResize()
    static let changed = Notification.Name("Whiskr.LiveResizeChanged")

    private(set) var isActive = false
    private var holders = 0

    /// A drag began (several can overlap: a window resize during a divider drag).
    func begin() {
        holders += 1
        set(true)
    }

    func end() {
        holders = max(0, holders - 1)
        if holders == 0 { set(false) }
    }

    private func set(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Runs `drag` (a split view's own tracking loop, which returns when the mouse goes up) as a live resize.
    func during(_ drag: () -> Void) {
        begin()
        drag()
        end()
    }
}
