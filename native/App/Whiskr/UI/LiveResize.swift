import AppKit

/// Whether the window, or a divider in it, is being dragged to a new size right now (or a region is
/// sliding). While it is, terminals keep the size they had and take the new one once, when the drag ends:
/// a terminal with a long scrollback re-wraps every line it holds on each change of width (3.4 ms for
/// 12,000 lines, measured: `make perf`'s resize run), for every pane the drag resizes, on every step, and
/// each new size would reach its program, which draws itself again. Meanwhile the pane around a held
/// terminal shows the terminal's background.
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

    /// A region sliding open or shut: `changes` made in an animation context on the window's timing for a
    /// region (`Look.Motion`), as a live resize until the slide has ended, when `done` runs. Ended means its
    /// completion handler has run, or at the latest `deadline` after its own duration: a slide is drawn by
    /// the window's display cycle, and while that does not run (a window nobody can see, whose display is
    /// off or asleep: a background run's, measured; an animation started while another was on its way) the
    /// slide neither moves nor ends. Held until then, the terminals would keep their size, and the region
    /// would stay where the slide began, for as long as that lasted. `done` runs once either way.
    func slide(_ changes: (NSAnimationContext) -> Void, done: @escaping @MainActor () -> Void) {
        begin()
        let end = Once { [weak self] in
            done()
            self?.end()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Look.Motion.region
            context.timingFunction = Look.Motion.curve
            changes(context)
        } completionHandler: {
            MainActor.assumeIsolated { end.run() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Look.Motion.region + Self.deadline) {
            MainActor.assumeIsolated { end.run() }
        }
    }

    /// How long past its own duration a slide may take before it counts as ended: far more than a busy
    /// Mac delays a frame, short enough that a stalled slide is not seen as one.
    static let deadline: TimeInterval = 0.5

    /// What runs once, whichever asks first.
    @MainActor private final class Once {
        private var work: (@MainActor () -> Void)?
        init(_ work: @escaping @MainActor () -> Void) { self.work = work }
        func run() {
            let work = work
            self.work = nil
            work?()
        }
    }
}
