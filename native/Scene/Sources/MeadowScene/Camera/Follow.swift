import Foundation
import simd

// The meadow follows what you choose (docs/DESIGN.md): a workspace, a tab or a pane chosen on the right
// brings its blanket (with its flag), and the cat of that terminal, comfortably into view. Comfortably means
// wholly inside the open part of the view with `Comfort.edge` points to spare on every side (in a sidebar's
// column, above and below: across is its framing's, which lays the blankets from side to side); something
// already so placed does not move the camera at all. Otherwise the camera slides across the ground just far
// enough to bring it `Comfort.room` points in from the nearest edges (or into the middle, if it is too tall or
// too wide for that), keeping the angle and the zoom you chose, and backs off only when it cannot fit at all,
// at most `Comfort.farthest` times as far. Only your choices move it; what agents do never does.

/// A move of the camera across the ground and back from it.
struct CameraShift: Equatable {
    var x: Float, z: Float, scale: Float
    static let none = CameraShift(x: 0, z: 0, scale: 1)
    init(x: Float, z: Float, scale: Float) { self.x = x; self.z = z; self.scale = scale }
    init(from a: CameraView, to b: CameraView) { self.init(x: b.x - a.x, z: b.z - a.z, scale: b.distance / max(a.distance, 1e-3)) }
    func applied(to v: CameraView) -> CameraView {
        CameraView(x: v.x + x, z: v.z + z, distance: v.distance * scale, pitch: v.pitch, bearing: v.bearing)
    }
}

/// What a shift to keep the followed thing comfortable was worked out for: the same choice, laid out the same
/// way in a view of the same size, looked at from the same angle. Anything else (a cat arriving, a bubble, a
/// longer branch on a flag) leaves it as it was, so nothing an agent does moves the camera.
struct FollowKey: Equatable {
    var item: MeadowItem
    var lineup: Int, perRow: Int, open: Vec2, flagSize: Float, bearing: Float, pitch: Float
}

extension Stage {
    enum Comfort {
        /// Closer than this to an edge of the open view, in points, is not comfortable.
        static let edge: Float = 12
        /// How far in from an edge a followed thing is brought, in points.
        static let room: Float = 28
        /// The farthest a follow backs the camera off to fit what was chosen, as a multiple of where it was.
        static let farthest: Float = 2.5
    }

    /// The part of the view panels leave open, in points (origin top left).
    private var openView: Vec2 {
        Vec2(Swift.max(camera.viewport.x - camera.coverGoal.x, 1), Swift.max(camera.viewport.y - camera.coverGoal.y, 1))
    }

    /// What must be seen of `item` from `view`, on screen: its blanket with its flag and, for a cat, the cat
    /// with its bubble (`catOnly`: the cat alone). Nil when it is not laid out or partly behind the camera.
    func followBox(_ item: MeadowItem, from view: CameraView, catOnly: Bool = false) -> ScreenBox? {
        guard let village, let plot = village.plot(item.blanketID) else { return nil }
        let project = { (p: Vec3) in self.screen(p, from: view) }
        var box: ScreenBox?
        if !catOnly || item.isBlanketLike {
            // The flag keeps one size on screen however far the camera is: as tall as it is drawn now.
            let flag = village.flagBox(plot, self) ?? ScreenBox(left: 0, top: 0, right: 0, bottom: FLAG_PIXELS * settings.flagSize)
            let foot = project(plot.flagAt)
            guard foot.z <= 1, let cloth = village.blanketBox(plot, project) else { return nil }
            let half = (flag.right - flag.left) / 2
            box = cloth.union(ScreenBox(left: foot.x - half, top: foot.y - (flag.bottom - flag.top), right: foot.x + half, bottom: foot.y))
        }
        if case .cat(_, let agent) = item, let actor = plot.actors[agent], !actor.leaving {
            let up = simd_normalize(MapCamera.viewMatrix(of: view).inverse.direction(Vec3(0, 1, 0)))
            func ball(_ center: Vec3, _ radius: Float) -> ScreenBox? {
                let c = project(center)
                if c.z > 1 { return nil }
                let e = project(center + up * radius)
                let r = hypot(e.x - c.x, e.y - c.y)
                return ScreenBox(left: c.x - r, top: c.y - r, right: c.x + r, bottom: c.y + r)
            }
            let cat = actor.cat
            guard var body = ball(cat.bodyMatrix.point(Vec3(0, 1.1, 0)), 1.3 * cat.size) else { return nil }
            if cat.bubbleShown, let bubble = ball(Vec3(cat.bubbleDrawn.x, cat.bubbleDrawn.y, cat.bubbleDrawn.z), cat.bubbleDrawn.w / 2) {
                body = body.union(bubble)
            }
            box = box.map { $0.union(body) } ?? body
        }
        return box
    }

    /// Whether `item` sits comfortably in view from `view` (`Comfort.edge`). Something not laid out counts
    /// as comfortable: there is nothing to bring into view.
    func isComfortable(_ item: MeadowItem, from view: CameraView) -> Bool {
        guard village?.plot(item.blanketID) != nil else { return true }
        guard let box = followBox(item, from: view) else { return false }
        return box.inside(openView, by: Comfort.edge)
    }

    /// Where the camera should be to show `item` comfortably, moving as little as it can from `start`: the
    /// same view when it is comfortable already. `along`: only along the ground toward the top of the view,
    /// as a column scrolls (its framing keeps the sides and the zoom itself).
    func comfortable(_ item: MeadowItem, from start: CameraView, along: Bool = false) -> CameraView {
        guard let village, let plot = village.plot(item.blanketID) else { return start }
        if along {
            guard let box = followBox(item, from: start), box.top >= Comfort.edge, box.bottom <= openView.y - Comfort.edge else {
                return scrolled(item, from: start)
            }
            return start
        }
        guard !isComfortable(item, from: start) else { return start }
        let open = openView, room = Comfort.room
        var view = start
        // Behind the camera from here (far along a column): start from right over it.
        if followBox(item, from: view) == nil {
            view.x = plot.middle.x
            view.z = plot.middle.z
        }
        // Too big to sit comfortably: back off, never further than `farthest` times, nor past the farthest zoom.
        let farthest = Swift.min(start.distance * Comfort.farthest, Swift.max(camera.maxDistance, start.distance))
        var fits = true
        for _ in 0..<4 {
            guard let box = followBox(item, from: view) else { break }
            let need = Swift.max((box.right - box.left) / (open.x - 2 * room), (box.bottom - box.top) / (open.y - 2 * room))
            fits = need <= 1.001
            if fits || view.distance >= farthest { break }
            view.distance = Swift.min(view.distance * need * 1.02, farthest)
        }
        // Still too big (a blanket larger than the view even backed off): the cat at least, else its middle.
        let catOnly = !fits && !item.isBlanketLike
        // Slide across the ground until it sits `room` in from the nearest edges, by Newton's steps on how the
        // box's middle moves for a step across and a step along the ground (near enough to straight lines).
        let right = Vec2(cos(view.bearing), -sin(view.bearing)), ahead = Vec2(-sin(view.bearing), -cos(view.bearing))
        for _ in 0..<12 {
            guard let box = followBox(item, from: view, catOnly: catOnly) else { break }
            let want = Vec2(Self.shift(box.left, box.right, within: open.x, room: room), Self.shift(box.top, box.bottom, within: open.y, room: room))
            if abs(want.x) < 0.25 && abs(want.y) < 0.25 { break }
            let step = Swift.max(view.distance * 0.01, 0.01)
            func moved(_ along: Vec2) -> Vec2? {
                var v = view
                v.x += along.x * step
                v.z += along.y * step
                return followBox(item, from: v, catOnly: catOnly).map { ($0.middle - box.middle) / step }
            }
            guard let across = moved(right), let along = moved(ahead) else { break }
            let det = across.x * along.y - along.x * across.y
            guard abs(det) > 1e-6 else { break }
            let a = (want.x * along.y - along.x * want.y) / det, b = (across.x * want.y - want.x * across.y) / det
            view.x += right.x * a + ahead.x * b
            view.z += right.y * a + ahead.y * b
        }
        return view
    }

    /// A column scrolled just far enough along its length for `item` to sit `room` in from the top or the
    /// bottom (its top, if it is taller than that).
    private func scrolled(_ item: MeadowItem, from start: CameraView) -> CameraView {
        let open = openView, room = Comfort.room
        let ahead = Vec2(-sin(start.bearing), -cos(start.bearing))
        var view = start
        for _ in 0..<12 {
            guard let box = followBox(item, from: view) else {
                // Not drawable from here: a step toward it, then measure again.
                guard let plot = village?.plot(item.blanketID) else { break }
                let d = simd_dot(Vec2(plot.middle.x - view.x, plot.middle.z - view.z), ahead)
                view.x += ahead.x * d
                view.z += ahead.y * d
                continue
            }
            var want = Self.shift(box.top, box.bottom, within: open.y, room: room)
            if box.bottom - box.top > open.y - 2 * room { want = room - box.top }
            if abs(want) < 0.25 { break }
            let step = Swift.max(view.distance * 0.01, 0.01)
            var v = view
            v.x += ahead.x * step
            v.z += ahead.y * step
            guard let moved = followBox(item, from: v) else { break }
            let rate = (moved.middle.y - box.middle.y) / step
            guard abs(rate) > 1e-6 else { break }
            view.x += ahead.x * want / rate
            view.z += ahead.y * want / rate
        }
        return view
    }

    /// How far to move a span `low…high` along an axis of `size` points so it sits `room` in from the
    /// nearer edge: nothing if it does; into the middle if it is too long for that.
    static func shift(_ low: Float, _ high: Float, within size: Float, room: Float) -> Float {
        if high - low > size - 2 * room { return size / 2 - (low + high) / 2 }
        if low < room { return room - low }
        if high > size - room { return size - room - high }
        return 0
    }

    /// The framing (`MapCamera.wanted`) moved so the followed thing sits comfortably, worked out once for
    /// each choice and layout (`FollowKey`) and kept: what agents do never shifts it. A column's framing
    /// does this itself (`followedColumnTop`).
    func keepingFollowed(_ framed: CameraView) -> CameraView {
        guard village?.arrangement != .column, let item = followed, let key = followKey(item, framed) else { return framed }
        if let kept = followedShift, kept.key == key { return kept.shift.applied(to: framed) }
        let shift = CameraShift(from: framed, to: comfortable(item, from: framed))
        followedShift = (key, shift)
        return shift.applied(to: framed)
    }

    /// Follows what you chose (nil: Home, everything): the camera glides there, or cuts (`cut`). A camera
    /// resting on the framing keeps resting on it, moved to keep this in comfortable view; one you moved
    /// yourself moves only as far as it must from where you left it. Nothing moves when it is comfortable.
    func follow(_ item: MeadowItem?, cut: Bool) {
        followed = item
        guard let item else {
            // Home: back to the framing of everything.
            camera.chase(to: settledFraming(), framing: true, cut: cut)
            return
        }
        let from = camera.destination
        let column = camera.framing ? columnFrame : nil
        let goal = comfortable(item, from: from, along: column != nil)
        if camera.framing {
            // Resting on the framing: it stays so, moved to where this sits comfortably, as little as
            // possible from where it is now. A column keeps its flags' top where they are seen from there.
            if let frame = column, let key = followKey(item, from) {
                followedTop = (key, flagTop(frame, from: goal))
            } else if let key = followKey(item, from) {
                let bare = camera.framed(from: from)
                followedShift = (key, CameraShift(from: bare, to: goal))
            }
            if goal != from || camera.chasing { camera.chase(to: goal, framing: true, cut: cut) }
            return
        }
        if goal != from { camera.chase(to: goal, framing: false, cut: cut) }
    }

    /// Where the framing settles now (`MapCamera.wanted`), worked out at once: a column's aim is measured from
    /// where the camera would be, so it is followed until it holds still.
    func settledFraming() -> CameraView {
        guard let frame = columnFrame else { return camera.wanted(from: camera.view) }
        return columnOverview(frame, flagTop: followedColumnTop(frame))
    }

    /// In a column, where its flags' top goes on screen to keep the followed thing comfortable, worked out
    /// once for each choice and layout from the column's own framing: nil when that shows it comfortably.
    func followedColumnTop(_ frame: Village.ColumnFrame) -> Float? {
        guard let item = followed, let key = followKey(item, camera.view) else { return nil }
        if let kept = followedTop, kept.key == key { return kept.y }
        let framed = columnOverview(frame, flagTop: nil)
        let goal = comfortable(item, from: framed, along: true)
        let y = goal == framed ? nil : flagTop(frame, from: goal)
        followedTop = (key, y)
        return y
    }

    /// Where a column's flags' top is on screen from `view`, as its framing measures it.
    private func flagTop(_ frame: Village.ColumnFrame, from view: CameraView) -> Float {
        screen(frame.top, from: view).y - FLAG_PIXELS * settings.flagSize
    }

    /// Where a column's framing settles, worked out at once: its aim, measured from where it would be,
    /// until it holds still.
    private func columnOverview(_ frame: Village.ColumnFrame, flagTop: Float?) -> CameraView {
        var view = camera.view
        for _ in 0..<16 {
            let next = camera.framing(columnGround(frame, from: view, flagTop: flagTop), from: view)
            let done = abs(next.z - view.z) < 1e-4 && abs(next.x - view.x) < 1e-4 && abs(next.distance - view.distance) < 1e-4
            view = next
            if done { break }
        }
        return view
    }

    private func followKey(_ item: MeadowItem, _ framed: CameraView) -> FollowKey? {
        guard let village, village.plot(item.blanketID) != nil else { return nil }
        return FollowKey(item: item, lineup: village.lineup, perRow: village.perRow, open: openView, flagSize: settings.flagSize,
                         bearing: framed.bearing, pitch: framed.pitch)
    }
}

extension ScreenBox {
    var middle: Vec2 { Vec2((left + right) / 2, (top + bottom) / 2) }
    /// Wholly inside a view of `size` points with `margin` to spare on every side.
    func inside(_ size: Vec2, by margin: Float) -> Bool {
        left >= margin && top >= margin && right <= size.x - margin && bottom <= size.y - margin
    }
}

extension MeadowItem {
    /// A blanket or a lantern: shown by its blanket (a lantern is drawn only after dark).
    var isBlanketLike: Bool { if case .cat = self { false } else { true } }
}
