import Foundation
import QuartzCore
import simd

// Port of src/camera.ts, plus the parts of three's OrbitControls it relies on (damped turning, sliding
// across the ground). A drag turns the view around the spot in the middle of the window; a slide moves it
// across the ground; zooming goes toward whatever is under the cursor, which stays put under it.
//
// Whoever owns it says which patch of ground to frame (`aim`) and how much of the window panels cover
// (`cover`). `fly()` eases there, keeping whatever angle you have turned the view to, and keeps that
// ground in the open part of the window. While you are touching it, nothing else moves it.

/// A patch of ground: its middle and how far it reaches either side (across) and front to back (deep), and
/// the least distance it must be seen from (things near the camera look bigger than `fit` allows for).
struct Ground {
    var x: Float, z: Float, across: Float, deep: Float
    var least: Float = 0
}

struct CameraView: Equatable {
    var x: Float, z: Float, distance: Float, pitch: Float, bearing: Float
}

final class MapCamera {
    static let pitch: Float = 0.8        // the angle above the ground it starts at
    static let bearing: Float = 0.2      // and a slight turn off square, so blankets read as solid things
    static let lowest: Float = 0.25      // the lowest you can tilt down to, in radians above the ground
    static let highest: Float = 1.35     // and the highest: nearly overhead, never flat top-down
    static let height: Float = 1.2       // it looks at this height above the ground, about a cat's middle
    static let flightSeconds: Float = 1.0
    static let nearest: Float = 9        // the closest zoom
    static let reach: Float = 14         // how far past the outermost blanket the view can be slid
    static let fovY: Float = 32 * .pi / 180
    static let rotateSpeed: Float = 0.6
    /// A sidebar's column is looked at from 52° above the ground.
    static let columnPitch: Float = 52 * .pi / 180

    /// The ground to frame when flying, asked afresh every frame so a growing blanket stays in view.
    var aim: () -> Ground = { Ground(x: 0, z: 0, across: 10, deep: 10) }
    /// The ground the view can be slid across; usually everything there is.
    var bounds: () -> Ground = { Ground(x: 0, z: 0, across: 10, deep: 10) }
    /// Reduced motion: flights and zooms jump instead of gliding.
    var calm = false
    /// The angle above the ground a framing comes to (nil: the angle you turned the view to), as editing
    /// looks down on the meadow from about 55°.
    var pitchGoal: Float?
    /// The closest the view may come (`nearest`, or nearer while editing).
    var closest: Float = MapCamera.nearest

    /// The window, in points.
    var viewport = Vec2(1200, 800)
    /// How many points panels cover along its right and bottom edges, eased.
    private(set) var cover = Vec2.zero
    var coverGoal = Vec2.zero

    private(set) var view = CameraView(x: 0, z: 0, distance: 40, pitch: MapCamera.pitch, bearing: MapCamera.bearing)
    /// A flight under way: from where, to a view of its own (else the aimed ground's framing, worked out
    /// afresh each frame), how far through, and whether it then rests on the framing.
    private var flight: (from: CameraView, to: CameraView?, t: Float, framing: Bool)? = nil
    /// True from arriving somewhere until you move the camera yourself: while it holds, the camera keeps
    /// the aimed ground framed as blankets grow and shrink.
    private var settled = true
    /// You are turning or sliding the view right now.
    private(set) var held = false
    private var zoom: (goal: Float, anchor: Vec3)? = nil
    // OrbitControls' damped motion still to apply.
    private(set) var maxDistance: Float = 160
    /// A scroll along the ground being eased in (`glide`): from where, to where, how far through.
    private var glide: (from: Vec2, to: Vec2, t: Float, seconds: Float)? = nil
    /// A glide toward a goal that may change on the way (`chase`), for following what you choose.
    private var pursuit: Pursuit? = nil
    /// How fast the view moved last frame (x, z, and distance in scale), so a chase starting while it
    /// moves carries on at that speed instead of stopping dead first.
    private var velocity = Pose.zero
    /// Where the framing lands (`wanted`) once worked out: the owner may nudge it, as the stage does to keep
    /// what you chose in comfortable view. Asked every frame of a flight, so it must be cheap.
    var adjust: ((CameraView) -> CameraView)?

    var moving: Bool { flight != nil || zoom != nil || glide != nil || pursuit != nil || simd_length(turnVelocity) > 0 || simd_length(slideVelocity) > 0 }
    var flying: Bool { flight != nil }
    /// A flight to a view of its own is under way (`glide`).
    var gliding: Bool { flight?.to != nil }
    /// A chase is under way (`chase`).
    var chasing: Bool { pursuit != nil }
    /// Resting on the framing, or on its way there: the camera keeps the aimed ground framed until you
    /// move it yourself.
    var framing: Bool { (settled || pursuit?.framing == true) && !held }

    var target: Vec3 { Vec3(view.x, Self.height, view.z) }
    var eye: Vec3 { Self.eye(of: view) }
    var viewMatrix: Mat4 { Self.viewMatrix(of: view) }
    static func eye(of v: CameraView) -> Vec3 {
        Vec3(v.x, height, v.z) + Vec3(sin(v.bearing) * cos(v.pitch), sin(v.pitch), cos(v.bearing) * cos(v.pitch)) * v.distance
    }
    static func viewMatrix(of v: CameraView) -> Mat4 { .lookAt(eye: eye(of: v), target: Vec3(v.x, height, v.z)) }
    /// Along the ground toward the top of the view, as the view is turned now.
    var ahead: Vec3 {
        let right = Vec3(cos(view.bearing), 0, -sin(view.bearing))
        return simd_cross(Vec3(0, 1, 0), right)
    }
    /// The projection, its middle shifted into the part of the window panels leave open (three.js
    /// `setViewOffset(w, h, right / 2, bottom / 2, w, h)`).
    func projection(aspect: Float) -> Mat4 {
        // In clip space: x += shift.x · w, y += shift.y · w.
        var shift = Mat4.identity
        shift.columns.3 = Vec4(-cover.x / max(viewport.x, 1), cover.y / max(viewport.y, 1), 0, 1)
        // Far enough to see the ground into the fog however far back the view is (the fog ends 210 past what
        // it looks at), so the land never stops short of it.
        return shift * Mat4.perspective(fovY: Self.fovY, aspect: aspect, near: 0.1, far: max(500, view.distance + 300))
    }

    // MARK: - what you do

    /// You pressed on the view to turn or slide it: the camera is yours now, and any coasting stops.
    func grab() {
        held = true
        letGo()
        turnVelocity = .zero
        slideVelocity = .zero
    }
    /// You let go: if you were still moving, the view coasts on and slows, as Maps does.
    func release() {
        held = false
        if calm || CACurrentMediaTime() - lastMove > 0.06 { turnVelocity = .zero; slideVelocity = .zero }
    }

    // Direct manipulation: a drag moves the view with your hand at once (the web's OrbitControls eased each
    // drag in over many frames, which reads as the view trailing behind). Velocity is kept for coasting.
    private var turnVelocity = Vec2.zero     // bearing, polar: radians a second
    private var slideVelocity = Vec3.zero    // world units a second
    private var lastMove: CFTimeInterval = 0
    private func track(_ v: inout Vec2, _ step: Vec2) {
        let now = CACurrentMediaTime(), dt = Float(max(now - lastMove, 1.0 / 240))
        lastMove = now
        v = dt > 0.1 ? .zero : v + (step / dt - v) * 0.5
    }
    private func track(_ v: inout Vec3, _ step: Vec3) {
        let now = CACurrentMediaTime(), dt = Float(max(now - lastMove, 1.0 / 240))
        lastMove = now
        v = dt > 0.1 ? .zero : v + (step / dt - v) * 0.5
    }

    /// A drag of `dx`, `dy` points: turns the view round the spot it looks at (OrbitControls' rates).
    func turn(dx: Float, dy: Float) {
        letGo()
        let h = max(viewport.y, 1)
        let step = Vec2(-2 * .pi * dx / h * Self.rotateSpeed, -2 * .pi * dy / h * Self.rotateSpeed)
        applyTurn(step)
        track(&turnVelocity, step)
    }
    private func applyTurn(_ step: Vec2) {
        view.bearing += step.x
        let phi = clamp(.pi / 2 - view.pitch + step.y, .pi / 2 - Self.highest, .pi / 2 - Self.lowest)
        view.pitch = .pi / 2 - phi
    }

    /// A slide of `dx`, `dy` points across the ground (OrbitControls pan, not screen-space).
    func slide(dx: Float, dy: Float) {
        letGo()
        let along = view.distance * tan(Self.fovY / 2)
        let h = max(viewport.y, 1)
        let right = Vec3(cos(view.bearing), 0, -sin(view.bearing))
        let forward = simd_cross(Vec3(0, 1, 0), right)   // up × right: toward the camera's back, on the ground
        let step = right * (-2 * dx * along / h) + forward * (2 * dy * along / h)
        view.x += step.x
        view.z += step.z
        track(&slideVelocity, step)
    }

    /// Scrolls along the ground by `dy` points of the view, as a scroll view moves its content: no
    /// coasting of its own, since the system's scroll events carry their momentum already.
    func scroll(dy: Float) {
        letGo()
        turnVelocity = .zero
        slideVelocity = .zero
        let along = view.distance * tan(Self.fovY / 2)
        let h = max(viewport.y, 1)
        let step = ahead * (2 * dy * along / h) / max(sin(view.pitch), 0.3)
        view.x += step.x
        view.z += step.z
    }

    /// Scrolls along the ground by `distance` world units toward the top of the view (negative: toward
    /// the bottom), as the scroll gesture does, easing out over `seconds` (at once when calm or 0).
    /// Anything you do meanwhile takes over from it.
    func scroll(by distance: Float, seconds: Float) {
        letGo()
        turnVelocity = .zero
        slideVelocity = .zero
        zoom = nil
        let from = Vec2(view.x, view.z), to = from + Vec2(ahead.x, ahead.z) * distance
        if calm || seconds <= 0 {
            view.x = to.x
            view.z = to.y
        } else {
            glide = (from, to, 0, seconds)
        }
    }

    /// Turns the bearing directly (trackpad rotation), in radians.
    func twist(_ radians: Float) {
        letGo()
        applyTurn(Vec2(radians, 0))
        track(&turnVelocity, Vec2(radians, 0))
    }

    /// Zooms by `factor` (>1 out, <1 in) toward the ground under `point` (points, origin top-left). A
    /// trackpad's pinch and scroll arrive as many small smooth steps, momentum included, and are applied at
    /// once (`immediate`); a mouse wheel's coarse notches glide.
    func zoom(by factor: Float, at point: Vec2, immediate: Bool = false) {
        letGo()
        turnVelocity = .zero
        slideVelocity = .zero
        let goal = clamp((zoom?.goal ?? view.distance) * factor, closest, maxDistance)
        var anchor = zoom?.anchor ?? target
        if zoom == nil || immediate, let hit = groundUnder(point) { anchor = hit }
        if immediate {
            zoom = nil
            scaleAbout(anchor, to: goal)
        } else {
            zoom = (goal, anchor)
        }
    }

    /// Scaling the whole view about a point on the ground, at an unchanged angle, keeps that point under
    /// the cursor.
    private func scaleAbout(_ anchor: Vec3, to distance: Float) {
        let scale = distance / view.distance
        view.x = anchor.x + (view.x - anchor.x) * scale
        view.z = anchor.z + (view.z - anchor.z) * scale
        view.distance = distance
    }

    /// The point on the plane the camera looks at (y = height) under a screen point, if any.
    func groundUnder(_ point: Vec2) -> Vec3? {
        let (o, d) = ray(point)
        guard d.y < -1e-4 else { return nil }
        let t = (Self.height - o.y) / d.y
        return t > 0 ? o + d * t : nil
    }

    /// A ray from the eye through a screen point (points, origin top-left).
    func ray(_ point: Vec2) -> (origin: Vec3, direction: Vec3) {
        let aspect = viewport.x / max(viewport.y, 1)
        let inv = (projection(aspect: aspect) * viewMatrix).inverse
        let ndc = Vec2(point.x / viewport.x * 2 - 1, 1 - point.y / viewport.y * 2)
        let near = inv.point(Vec3(ndc.x, ndc.y, 0)), far = inv.point(Vec3(ndc.x, ndc.y, 1))
        return (near, simd_normalize(far - near))
    }

    /// Glide to the aimed ground and stay with it. Ignored while you are holding the view.
    func fly() {
        if held { return }
        flight = (view, nil, 0, true)
        zoom = nil
        glide = nil
        pursuit = nil
        settled = true
    }

    /// Jump straight there (first frame, tests).
    func settle() {
        flight = nil
        zoom = nil
        glide = nil
        pursuit = nil
        settled = true
        view = wanted(from: view)
    }

    /// Glide to `goal` exactly, in the time a flight takes (at once when calm), then rest there, or on the
    /// framing as a flight's end does (`thenFraming`). Ignored while you are holding the view.
    func glide(to goal: CameraView, thenFraming: Bool) {
        if held { return }
        flight = (view, goal, 0, thenFraming)
        zoom = nil
        glide = nil
        pursuit = nil
        turnVelocity = .zero
        slideVelocity = .zero
        settled = false
    }

    func setView(_ v: CameraView) {
        view = v
        flight = nil
        glide = nil
        pursuit = nil
        settled = false
    }

    /// Where the camera is headed: the end of a flight, a scroll or a chase under way, else where it is.
    var destination: CameraView {
        if let goal = pursuit?.goal { return goal }
        if let f = flight { return f.to ?? wanted(from: view) }
        if let g = glide { var v = view; v.x = g.to.x; v.z = g.to.y; return v }
        return view
    }

    /// Glides to `goal`, at the angle the view has now, then stays there; with `framing`, it then rests on
    /// the framing (`wanted`) as a flight's end does, the goal being where that framing lands. Three easing
    /// stages in a row: it sets off gently, at the speed the view already had, and comes in softly; a new
    /// goal on the way bends the path without a jolt. Lands in about `chaseSeconds`. At once when calm
    /// (`cut`). Anything you do to the view takes over from it.
    func chase(to goal: CameraView, framing: Bool, cut: Bool = false) {
        if held { return }
        flight = nil
        zoom = nil
        glide = nil
        turnVelocity = .zero
        slideVelocity = .zero
        // Resting on the framing waits for the landing, so the two never pull the view at once.
        settled = false
        if cut || calm {
            pursuit = nil
            view = goal
            settled = framing
            return
        }
        if pursuit != nil {
            pursuit?.goal = goal
            pursuit?.framing = framing
            return
        }
        // Set off at the speed the view had: the last stage's lead is that speed over the rate.
        let now = Pose(view), lead = now + velocity * (1 / Self.chaseRate)
        pursuit = Pursuit(goal: goal, framing: framing, first: lead, second: lead)
    }
    /// Each stage's rate (per second): three in a row land within a hundredth of the way in about 0.85 s.
    static let chaseRate: Float = 10
    static var chaseSeconds: Float { 8.4 / chaseRate }

    // MARK: - each frame

    func update(_ dt: Float) {
        // Panels cover part of the window; the picture's middle eases into the open part.
        let ease = calm ? 1 : min(1, dt * 8)
        cover += (coverGoal - cover) * ease
        maxDistance = max(fit(bounds(), view) * 1.6, closest * 2)
        let before = Pose(view)

        if var p = pursuit {
            let goal = p.goal, to = Pose(goal)
            let k = 1 - exp(-dt * Self.chaseRate)
            p.first = p.first + (to - p.first) * k
            p.second = p.second + (p.first - p.second) * k
            let at = Pose(view) + (p.second - Pose(view)) * k
            view.x = at.x
            view.z = at.z
            view.distance = exp(at.scale)
            // Landed: within a hair of the goal, all three stages.
            if at.near(to) && p.first.near(to) && p.second.near(to) {
                view.x = goal.x
                view.z = goal.z
                view.distance = goal.distance
                pursuit = nil
                settled = p.framing
            } else {
                pursuit = p
            }
        } else if var f = flight {
            // Ease away, glide, ease in: slow at both ends so nothing lurches.
            f.t = calm ? 1 : min(1, f.t + dt / Self.flightSeconds)
            let t = f.t, eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let end = f.to ?? wanted(from: f.from)
            view = t >= 1 ? end : between(f.from, end, eased)
            flight = t >= 1 ? nil : f
            if t >= 1 { settled = f.framing }
        } else if settled && !held {
            view = between(view, wanted(from: view), min(1, dt * 3))
        }
        if var g = glide {
            g.t = min(1, g.t + dt / g.seconds)
            let eased = 1 - pow(1 - g.t, 3)
            view.x = g.from.x + (g.to.x - g.from.x) * eased
            view.z = g.from.y + (g.to.y - g.from.y) * eased
            glide = g.t >= 1 ? nil : g
        }
        if zoom != nil { glideZoom(dt) }
        applyDamped(dt)
        keepInBounds(dt)
        if dt > 0 { velocity = (Pose(view) - before) * (1 / dt) }
    }

    /// After you let go, the view coasts on at the speed it had and slows to a stop.
    private func applyDamped(_ dt: Float) {
        if held { return }
        let keep = exp(-dt / 0.28)
        if simd_length(turnVelocity) > 0.02 {
            applyTurn(turnVelocity * dt)
            turnVelocity *= keep
        } else {
            turnVelocity = .zero
        }
        if simd_length(slideVelocity) > 0.05 {
            view.x += slideVelocity.x * dt
            view.z += slideVelocity.z * dt
            slideVelocity *= keep
        } else {
            slideVelocity = .zero
        }
    }

    private func letGo() {
        flight = nil
        glide = nil
        pursuit = nil
        settled = false
    }

    private func glideZoom(_ dt: Float) {
        guard let (goal, anchor) = zoom else { return }
        // Equal steps in scale, not in distance, so zooming feels the same near and far.
        let next = view.distance * pow(goal / view.distance, calm ? 1 : min(1, dt * 12))
        scaleAbout(anchor, to: next)
        if abs(next - goal) < 0.01 { zoom = nil }
    }

    // The view can be slid a little way past the blankets and then eases back, like a rubber band.
    private func keepInBounds(_ dt: Float) {
        let b = bounds()
        let dx = clamp(view.x, b.x - b.across - Self.reach, b.x + b.across + Self.reach) - view.x
        let dz = clamp(view.z, b.z - b.deep - Self.reach, b.z + b.deep + Self.reach) - view.z
        if dx == 0 && dz == 0 { return }
        let pull = min(1, dt * 8)
        view.x += dx * pull
        view.z += dz * pull
    }

    /// How far back the camera must be, at a given angle, for a patch of ground to fill the open part of
    /// the window.
    func fit(_ g: Ground, _ v: CameraView) -> Float {
        let wide = abs(g.across * cos(v.bearing)) + abs(g.deep * sin(v.bearing))
        let long = abs(g.across * sin(v.bearing)) + abs(g.deep * cos(v.bearing))
        let tall = tan(Self.fovY / 2)
        let openWide = tall * max(160, viewport.x - coverGoal.x) / max(viewport.y, 1)
        let openTall = tall * max(160, viewport.y - coverGoal.y) / max(viewport.y, 1)
        return max(wide / openWide, (long * sin(v.pitch)) / openTall) + long * cos(v.pitch)
    }

    // Where a flight should end: framing the aimed ground from the angle the flight began at, as the owner
    // adjusts it.
    func wanted(from: CameraView) -> CameraView {
        let framed = framed(from: from)
        return adjust?(framed) ?? framed
    }

    /// The aimed ground framed from that angle, before the owner's adjustment.
    func framed(from: CameraView) -> CameraView { framing(aim(), from: from) }

    /// A patch of ground framed from that angle.
    func framing(_ g: Ground, from: CameraView) -> CameraView {
        var at = from
        at.pitch = pitchGoal ?? from.pitch
        return CameraView(x: g.x, z: g.z, distance: clamp(max(fit(g, at), g.least), closest, maxDistance), pitch: at.pitch, bearing: from.bearing)
    }

    // Part-way from one view to another, turning the short way round. Distance eases in scale.
    private func between(_ a: CameraView, _ b: CameraView, _ t: Float) -> CameraView {
        CameraView(x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t, distance: a.distance * pow(b.distance / a.distance, t),
                   pitch: a.pitch + (b.pitch - a.pitch) * t, bearing: a.bearing + turnFrom(a.bearing, b.bearing) * t)
    }
}

/// Where the camera stands across the ground, and how far back as a logarithm (so distance eases in
/// scale): what a chase eases.
private struct Pose {
    var x: Float, z: Float, scale: Float
    static let zero = Pose(x: 0, z: 0, scale: 0)
    init(x: Float, z: Float, scale: Float) { self.x = x; self.z = z; self.scale = scale }
    init(_ v: CameraView) { self.init(x: v.x, z: v.z, scale: log(max(v.distance, 1e-3))) }
    static func + (a: Pose, b: Pose) -> Pose { Pose(x: a.x + b.x, z: a.z + b.z, scale: a.scale + b.scale) }
    static func - (a: Pose, b: Pose) -> Pose { Pose(x: a.x - b.x, z: a.z - b.z, scale: a.scale - b.scale) }
    static func * (a: Pose, k: Float) -> Pose { Pose(x: a.x * k, z: a.z * k, scale: a.scale * k) }
    /// Close enough to stop: a thousandth of a unit across, a ten-thousandth in scale.
    func near(_ o: Pose) -> Bool { abs(x - o.x) < 1e-3 && abs(z - o.z) < 1e-3 && abs(scale - o.scale) < 1e-4 }
}

/// A chase's goal, whether it then rests on the framing, and its two leading stages.
private struct Pursuit {
    var goal: CameraView
    var framing: Bool
    var first: Pose, second: Pose
}
