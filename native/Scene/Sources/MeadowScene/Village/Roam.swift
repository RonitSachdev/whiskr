import Foundation
import simd

// Cats out in the grass (docs/DESIGN.md, "Idle cats wander"). A cat whose Claude has nothing for it gets up
// after a while and wanders near its blanket: a few hops through the grass or a short waddle, a sit to watch
// whatever flies past, a sniff at a flower, a loaf in the sun; then on, or back to its blanket. Long-idle, it
// naps where it is, in a tree's shade or back on its blanket, circling once before it curls up. The moment
// its Claude has work (or needs you, or anything else changes it), it turns and runs home, ears back, skids
// to a stop on its blanket and takes up the work; the blanket and its bubble say so from the first moment.
//
// Modelled on how real cats get about, in this cat's own way (its paws are short fixed nubs, so it has no leg
// cycle): a walk is a waddle that lifts it a little with each step, a bound through long grass is a series of
// hops with a look round between, running home is low fast bounds, and every move ends where it lands: the
// cat moves on only while it is up off its paws, so it never slides.
//
// It keeps to its own patch of grass: within `ROAM_RANGE` of its blanket's edge, nearer its blanket than any
// other, clear of every other blanket and every flag, and in view, so whose cat it is always reads. It goes
// round the scenery's footprints (trees, stones, logs, flowers, whatever the meadow holds), the picnic things
// and other cats, by a route over a grid (`RoamField`), which may prefer some ground (`Village.liking`).
// Out in short bursts with long still stops between, so between them the meadow rests as it always did.

/// How far past its blanket's edge a cat wanders, in units, at full size.
let ROAM_RANGE: Float = 3.6
/// Before its first outing a cat rests on its blanket this long at least, and this much longer at most; and as
/// long again (and more) between outings.
let ROAM_FIRST_REST: (least: Float, more: Float) = (14, 12)
let ROAM_REST: (least: Float, more: Float) = (20, 30)
/// A walk's pace, units a second, and a step's length, at full size.
private let WALK_SPEED: Float = 1.5
private let WALK_STEP: Float = 0.42
/// Running home: pace and the length of one bound.
private let RUN_SPEED: Float = 6.5
private let RUN_BOUND: Float = 0.95
/// A hop through the grass: how far, and how fast it leaves the ground (about half a second in the air).
private let HOP_LENGTH: Float = 1.25
private let HOP_SPEED: Float = 5.4
/// Room a cat keeps from things it passes, at full size.
private let CLEARANCE: Float = 0.75
/// Points a cat out in the grass keeps inside the view's edges (its head and ears included).
private let IN_VIEW: Float = 16
/// The route's corners a cat keeps.
let ROAM_MOST_CORNERS = 48

/// A cat's life off its blanket.
struct Roam {
    enum Phase {
        /// On its blanket, in its seat (`until`: when it may next set off).
        case home
        /// On its way to a stop, or home (`homeward`).
        case travelling
        /// At a stop, doing `outing` until `until`.
        case stopped
        /// Turning round once where it means to sleep, before it curls up (until `until`).
        case circling
        /// Asleep out in the grass.
        case asleep
        /// Called back: running home (from `until`, once awake).
        case recalled
        /// Just home from a run: skidding to a stop and settling (until `until`).
        case settling
    }
    var phase = Phase.home
    var until: Float = 0
    var homeward = false
    var gait = Cat.Gait.walk
    var outing = Cat.Outing.watch
    /// Stops left on this outing.
    var stopsLeft = 0
    /// Where it is heading: the route's corners (blanket-local x, z) and the next one; where it means to end
    /// up, in the world (other cats keep clear of it).
    var route: [Vec2] = []
    var next = 0
    var goal: Vec2?
    /// The step's phase, and how far into moving it is (eased as the cat's own is, so steps and lifts agree).
    var stride: Float = 0
    var ramp: Float = 0
    /// A hop under way (from, to, when it left, how long it is in the air), or when the next may leave.
    var hopFrom = Vec3.zero, hopTo = Vec3.zero
    var hopAt: Float = -1, hopFor: Float = 0, hopNext: Float = 0, hopRise: Float = 0
    /// Where it means to sleep, and whether it has looked for such a place yet this nap.
    var bed: Vec2?
    var bedChosen = false
    /// Its route home is still to be found (it was called back between frames).
    var replan = false
    var random: Seeded

    init(seed: String) {
        random = chance("roam/" + seed)
        route.reserveCapacity(ROAM_MOST_CORNERS)
    }

    /// Off its blanket, or on its way back.
    var out: Bool { phase != .home }
    /// A number in `range`, from its own stream.
    mutating func pick(_ least: Float, _ more: Float) -> Float { least + random.float() * more }
}

extension Village {
    /// Cats wander only with the switch on (Settings › Meadow), the meadow's motion playing and Reduce Motion off.
    var wanders: Bool { catsWander && ambient && !reduceMotion }

    /// Whether a cat's Claude leaves it free to be out: nothing to do (awake, idle or napping), nothing to say
    /// (no request, no finished turn unseen, no error), no errand on its blanket, and its blanket its own.
    func atLeisure(_ actor: Actor, _ plot: Plot) -> Bool {
        let view = actor.view
        guard wanders, plot.view.state == .live, !actor.leaving, actor.errand == nil, !view.needsYou, !view.doneUnseen, !view.failed else { return false }
        switch view.activity {
        case .awake, .idle, .napping: return true
        default: return false
        }
    }

    // MARK: being told

    /// A cat's state changed (`upsert`): one out in the grass that is no longer at leisure runs home.
    func reconsider(_ actor: Actor, in plot: Plot) {
        guard actor.roam.out, !atLeisure(actor, plot), actor.roam.phase != .recalled, actor.roam.phase != .settling else { return }
        recall(actor, in: plot)
    }

    /// Every cat out comes home at once, as it is (the switch turned off, Reduce Motion, the animation held):
    /// cats then stay on their blankets as they always did.
    func bringEveryoneHome() {
        for plot in plots {
            for actor in plot.actors.values where actor.roam.out {
                actor.rootLocal = actor.spot
                settleHome(actor)
            }
        }
    }

    private func settleHome(_ actor: Actor) {
        actor.roam.phase = .home
        actor.roam.goal = nil
        actor.roam.bed = nil
        actor.roam.bedChosen = false
        actor.roam.hopAt = -1
        actor.roam.until = time + actor.roam.pick(ROAM_REST.least, ROAM_REST.more)
        let cat = actor.cat
        cat.leap = nil
        cat.gait = .none
        cat.outing = nil
        cat.going = nil
    }

    /// Called back: it wakes if asleep, turns and runs home the shortest clear way. With motion reduced it is
    /// simply home.
    private func recall(_ actor: Actor, in plot: Plot) {
        guard !hushed else {
            actor.rootLocal = actor.spot
            return settleHome(actor)
        }
        let cat = actor.cat
        // Only just up from its seat: it simply sits back down to work.
        if simd_distance(actor.rootLocal, actor.spot) < 0.3 { return settleHome(actor) }
        let asleep = actor.roam.phase == .asleep || cat.isNapping
        actor.roam.phase = .recalled
        actor.roam.gait = .run
        actor.roam.hopAt = -1
        // Awake at once, on its feet a moment later.
        actor.roam.until = time + (asleep ? 0.35 : 0)
        cat.outing = nil
        // Its way home is found on the next frame, with the view as it is then.
        actor.roam.route.removeAll(keepingCapacity: true)
        actor.roam.next = 0
        actor.roam.replan = true
        actor.roam.goal = Vec2(plot.group.x + actor.spot.x, plot.group.z + actor.spot.z)
    }

    // MARK: each frame

    /// Where a cat is this frame, off an errand: in its seat, or out in the grass doing what it does there.
    func roam(_ actor: Actor, in plot: Plot, _ dt: Float, _ stage: Stage) {
        let cat = actor.cat
        // A bound that landed last frame is over.
        if actor.roam.hopAt < 0 && cat.leap != nil { cat.leap = nil }
        if actor.leaving {
            // Its Claude has gone: it says goodbye where it stands.
            cat.gait = .none
            cat.going = nil
            if !actor.roam.out { actor.rootLocal += (actor.spot - actor.rootLocal) * min(1, dt * 3.5) }
            return
        }
        if actor.roam.out && !wanders {
            actor.rootLocal = actor.spot
            settleHome(actor)
        }
        switch actor.roam.phase {
        case .home:
            actor.rootLocal += (actor.spot - actor.rootLocal) * min(1, dt * 3.5)
            guard atLeisure(actor, plot) else {
                // Busy: its next outing waits a full rest after it is free again.
                actor.roam.until = max(actor.roam.until, time + ROAM_FIRST_REST.least)
                return
            }
            let ready = (cat.activity == .awake || cat.activity == .idle) && actor.queue.isEmpty && !cat.isNapping
            if ready && time >= actor.roam.until && !cat.watched && !cat.petting && simd_distance(actor.rootLocal, actor.spot) < 0.05 {
                setOut(actor, in: plot, stage)
            }
        case .stopped:
            if cat.isNapping { return lieDown(actor, in: plot, stage) }
            guard time >= actor.roam.until else { return }
            if case .sniff = actor.roam.outing {
                // A sniff, then a sit to look about, there.
                actor.roam.outing = .watch
                cat.outing = .watch
                actor.roam.until = time + actor.roam.pick(3, 3)
            } else {
                onward(actor, in: plot, stage)
            }
        case .travelling:
            if travel(actor, in: plot, dt) {
                if actor.roam.homeward {
                    settleHome(actor)
                } else if cat.isNapping && actor.roam.bed != nil {
                    circle(actor)
                } else {
                    stop(actor, in: plot)
                }
            }
        case .circling:
            // Round once on the spot, as a cat does before it curls up.
            let u = 1 - (actor.roam.until - time) / 1.2
            let a = cat.isNapping ? u * 2 * .pi : 0
            cat.going = plot.group + actor.rootLocal + Vec3(sin(a) * 0.6, 0, cos(a) * 0.6)
            if time >= actor.roam.until || !cat.isNapping {
                cat.going = nil
                actor.roam.phase = cat.isNapping ? .asleep : .stopped
                actor.roam.until = time + 2
            }
        case .asleep:
            // Woken with nothing to do: up, a look round, then on.
            if !cat.isNapping {
                actor.roam.phase = .stopped
                actor.roam.outing = .watch
                cat.outing = .watch
                actor.roam.until = time + actor.roam.pick(3, 3)
                actor.roam.bed = nil
                actor.roam.bedChosen = false
            }
        case .recalled:
            if time < actor.roam.until { return }
            if actor.roam.replan {
                actor.roam.replan = false
                if !plan(actor, in: plot, to: Vec2(actor.spot.x, actor.spot.z), stage) { straight(actor, to: actor.spot) }
            }
            if travel(actor, in: plot, dt) {
                cat.skid()
                cat.gait = .none
                cat.going = nil
                actor.roam.phase = .settling
                actor.roam.until = time + 0.45
            }
        case .settling:
            // The last of the skid carries it onto its seat.
            actor.rootLocal += (actor.spot - actor.rootLocal) * min(1, dt * 7)
            if time >= actor.roam.until { settleHome(actor) }
        }
    }

    /// Up off the blanket: it sits up and looks about a moment, then sets off on an outing of a stop or three.
    private func setOut(_ actor: Actor, in plot: Plot, _ stage: Stage) {
        actor.roam.stopsLeft = 1 + Int(actor.roam.random.float() * 2.99)
        actor.roam.phase = .stopped
        actor.roam.outing = .watch
        actor.cat.outing = .watch
        actor.roam.until = time + actor.roam.pick(0.8, 0.6)
        actor.roam.homeward = false
    }

    /// The stop is over: on to the next, or home.
    private func onward(_ actor: Actor, in plot: Plot, _ stage: Stage) {
        if actor.roam.stopsLeft > 0, let target = chooseStop(actor, in: plot, stage), plan(actor, in: plot, to: target.at, stage) {
            actor.roam.stopsLeft -= 1
            actor.roam.outing = target.outing
            actor.roam.homeward = false
            // Through the grass a cat bounds more often than it walks; across its blanket it walks.
            actor.roam.gait = target.onCloth || actor.roam.random.float() < 0.35 ? .walk : .bound
            return depart(actor)
        }
        // Home again, at an easy pace.
        actor.roam.gait = actor.roam.random.float() < 0.6 ? .walk : .bound
        if !plan(actor, in: plot, to: Vec2(actor.spot.x, actor.spot.z), stage) { straight(actor, to: actor.spot) }
        depart(actor, home: true)
    }

    private func depart(_ actor: Actor, home: Bool = false) {
        actor.roam.phase = .travelling
        actor.roam.homeward = home
        actor.roam.hopAt = -1
        actor.roam.hopNext = time
        actor.cat.outing = nil
    }

    /// Arrived at a stop: it does what it came for.
    private func stop(_ actor: Actor, in plot: Plot) {
        let cat = actor.cat
        cat.gait = .none
        cat.going = nil
        actor.roam.phase = .stopped
        let outing = actor.roam.outing
        cat.outing = outing
        let stay: Float = switch outing {
        case .sniff: actor.roam.pick(2.4, 1)
        case .watch: actor.roam.pick(4.5, 4)
        case .loaf: actor.roam.pick(10, 9)
        }
        actor.roam.until = time + stay
    }

    /// Fallen asleep out in the grass: it naps where it is, or first goes somewhere nicer nearby (a tree's
    /// shade, or its own blanket), as this cat likes, and circles once before it curls up.
    private func lieDown(_ actor: Actor, in plot: Plot, _ stage: Stage) {
        let cat = actor.cat
        cat.outing = nil
        if !actor.roam.bedChosen {
            actor.roam.bedChosen = true
            let here = Vec2(plot.group.x + actor.rootLocal.x, plot.group.z + actor.rootLocal.z)
            let taste = actor.roam.random.float()
            let seat = Vec2(plot.group.x + actor.spot.x, plot.group.z + actor.spot.z)
            var bed: Vec2? = nil
            if taste < 0.45, let shade = shadeNear(here, plot, stage) { bed = shade } else if taste > 0.8 { bed = seat }
            if let bed, simd_distance(bed, here) > 0.8, plan(actor, in: plot, to: bed - Vec2(plot.group.x, plot.group.z), stage) {
                actor.roam.bed = bed
                actor.roam.gait = .walk
                // Home to sleep in its seat, as cats on their blankets always have; else to the shade.
                return depart(actor, home: bed == seat)
            }
        }
        circle(actor)
    }

    private func circle(_ actor: Actor) {
        actor.cat.gait = .none
        actor.cat.outing = nil
        actor.roam.phase = .circling
        actor.roam.until = time + 1.2
    }

    // MARK: moving

    /// Moves a cat along its route by its gait; whether it has arrived.
    private func travel(_ actor: Actor, in plot: Plot, _ dt: Float) -> Bool {
        let cat = actor.cat
        let size = max(actor.size, 0.4)
        cat.outing = nil
        if actor.roam.gait == .bound { return bound(actor, in: plot, size) }
        guard actor.roam.next < actor.roam.route.count else {
            cat.gait = .none
            return true
        }
        // Walking or running: turned to the way it goes first, then step by step, moving on only while lifted.
        let corner = actor.roam.route[actor.roam.next]
        let ahead = plot.group + Vec3(corner.x, 0, corner.y)
        cat.going = ahead
        cat.gait = actor.roam.gait
        let running = actor.roam.gait == .run
        if actor.roam.ramp < 0.01 && cat.turned(from: ahead) > (running ? 0.9 : 0.5) {
            cat.stride = 0
            return false
        }
        actor.roam.ramp += (1 - actor.roam.ramp) * min(1, dt * 8)
        let speed = (running ? RUN_SPEED * (0.55 + 0.45 * size) : WALK_SPEED * size)
        let step = (running ? RUN_BOUND : WALK_STEP) * size
        actor.roam.stride += dt * .pi * speed / step
        cat.stride = actor.roam.stride
        // Half a stride cycle is one step; |sin| averages 2/π, so this keeps the pace and lands each step.
        var left = speed * dt * .pi / 2 * abs(sin(actor.roam.stride)) * actor.roam.ramp
        // Running in to its seat it slows over the last stretch, into the skid.
        if running && actor.roam.next == actor.roam.route.count - 1 {
            let remaining = hypot(corner.x - actor.rootLocal.x, corner.y - actor.rootLocal.z)
            left *= clamp(remaining / (0.9 * size), 0.35, 1)
        }
        while left > 0 && actor.roam.next < actor.roam.route.count {
            let c = actor.roam.route[actor.roam.next]
            let to = Vec2(c.x - actor.rootLocal.x, c.y - actor.rootLocal.z), far = simd_length(to)
            if far <= left {
                actor.rootLocal = Vec3(c.x, 0, c.y)
                left -= far
                actor.roam.next += 1
            } else {
                let d = to / far * left
                actor.rootLocal += Vec3(d.x, 0, d.y)
                left = 0
            }
        }
        if actor.roam.next >= actor.roam.route.count {
            actor.roam.ramp = 0
            actor.roam.stride = 0
            cat.stride = 0
            return true
        }
        return false
    }

    /// Bounding through the grass: hop by hop along the route, turned to each before it leaves, a look round
    /// between. Carried forward only while in the air, landing exactly where it was going.
    private func bound(_ actor: Actor, in plot: Plot, _ size: Float) -> Bool {
        let cat = actor.cat
        cat.gait = .bound
        // Landed last frame: on its paws again.
        if actor.roam.hopAt < 0 { cat.leap = nil }
        if actor.roam.hopAt >= 0 {
            // Down when its body is: the landing is where it was going, never a slide after it.
            // Along and up together, on one clock: it lands exactly where, and when, it was going.
            let u = min(1, (time - actor.roam.hopAt) / actor.roam.hopFor), rise = actor.roam.hopRise
            actor.rootLocal = lerp(actor.roam.hopFrom, actor.roam.hopTo, u)
            cat.leap = (rise * rise / (2 * -GRAVITY) * 4 * u * (1 - u), rise * (1 - 2 * u))
            guard u >= 1 else { return false }
            actor.roam.hopAt = -1
            // A pause where it lands: a short one mid-bound, a look round now and then.
            actor.roam.hopNext = time + actor.roam.pick(0.18, 0.25) + (actor.roam.random.float() < 0.3 ? actor.roam.pick(0.4, 0.5) : 0)
        }
        if actor.roam.next >= actor.roam.route.count {
            cat.gait = .none
            cat.going = nil
            return true
        }
        guard time >= actor.roam.hopNext, cat.height == 0 else { return false }
        // The next landing: a hop's length along the route, or its end.
        var at = Vec2(actor.rootLocal.x, actor.rootLocal.z), left = HOP_LENGTH * size, index = actor.roam.next
        while index < actor.roam.route.count {
            let c = actor.roam.route[index], far = simd_distance(c, at)
            if far <= left { at = c; left -= far; index += 1 } else { at += (c - at) / far * left; break }
        }
        // A last scrap of a hop is folded into the one before it.
        if index == actor.roam.route.count - 1, simd_distance(actor.roam.route[index], at) < 0.35 * size {
            at = actor.roam.route[index]
            index += 1
        }
        let landing = Vec3(at.x, 0, at.y)
        cat.going = plot.group + landing
        guard cat.turned(from: plot.group + landing) < 0.3 else { return false }
        let speed = HOP_SPEED * (0.75 + 0.25 * size)
        actor.roam.hopRise = speed
        actor.roam.hopFrom = actor.rootLocal
        actor.roam.hopTo = landing
        actor.roam.hopAt = time
        actor.roam.hopFor = 2 * speed / -GRAVITY
        actor.roam.next = index
        return false
    }

    /// A route of one straight leg, when no better one is found (a cat hemmed in by others, say).
    private func straight(_ actor: Actor, to spot: Vec3) {
        actor.roam.route.removeAll(keepingCapacity: true)
        actor.roam.route.append(Vec2(spot.x, spot.z))
        actor.roam.next = 0
    }

    // MARK: choosing where

    /// A stop worth going to: open ground in its patch (or now and then a corner of its own blanket), a short
    /// way off, across or toward you rather than away, by a flower to sniff, on ground it likes.
    private func chooseStop(_ actor: Actor, in plot: Plot, _ stage: Stage) -> (at: Vec2, outing: Cat.Outing, onCloth: Bool)? {
        let size = max(actor.size, 0.4)
        layField(for: actor, in: plot, stage)
        let here = Vec2(plot.group.x + actor.rootLocal.x, plot.group.z + actor.rootLocal.z)
        let middle = Vec2(plot.middle.x, plot.middle.z)
        var toYou = Vec2(stage.camera.eye.x - here.x, stage.camera.eye.z - here.y)
        toYou = simd_length(toYou) > 1e-3 ? simd_normalize(toYou) : Vec2(0, 1)
        var best: (at: Vec2, outing: Cat.Outing, onCloth: Bool, score: Float)?
        for _ in 0..<28 {
            let a = actor.roam.random.float() * 2 * .pi, dir = Vec2(sin(a), cos(a))
            let edge = clothReach(plot, toward: dir)
            let onCloth = actor.roam.random.float() < 0.12
            let out = onCloth ? edge * actor.roam.pick(0.35, 0.45) : edge + actor.roam.pick(0.7, ROAM_RANGE * size - 0.7)
            let p = middle + dir * out
            guard roamField.open(p) else { continue }
            let leg = p - here, length = simd_length(leg)
            guard length > 1.2 else { continue }
            var score = -abs(length - 3) * 0.35 + actor.roam.random.float() * 0.9
            score += simd_dot(leg / length, toYou) * 0.7
            var outing = actor.roam.random.float() < 0.55 ? Cat.Outing.watch : .loaf
            if let flower = bloom(near: p, within: 1.3) {
                score += 0.8
                outing = .sniff(flower)
            }
            if let liking { score += clamp(liking(p), 0, 1) * 2 }
            if score > best?.score ?? -.infinity { best = (p, outing, onCloth, score) }
        }
        return best.map { ($0.at - Vec2(plot.group.x, plot.group.z), $0.outing, $0.onCloth) }
    }

    /// A flower's bloom within reach of a spot, to sniff (world).
    private func bloom(near p: Vec2, within reach: Float) -> Vec3? {
        var best: Vec3?, nearest = reach
        for b in blooms {
            let d = hypot(b.x - p.x, b.z - p.y)
            if d < nearest { nearest = d; best = b }
        }
        return best
    }

    /// The deepest tree shade in a cat's own patch near it, if any (world).
    private func shadeNear(_ here: Vec2, _ plot: Plot, _ stage: Stage) -> Vec2? {
        var best: Vec2?, deepest: Float = 0.35
        for tree in treeShade {
            let at = Vec2(tree.x, tree.y)
            // Halfway in from the shade's edge toward the trunk, on the side nearer the cat.
            let toward = here - at, far = simd_length(toward)
            guard far > 1e-3, far - tree.z * 0.5 < 4 else { continue }
            let spot = at + toward / far * max(tree.z * 0.45, 2.5)
            let depth = 1 - simd_distance(spot, at) / tree.z
            if depth > deepest, inPatch(spot, of: plot, stage) { deepest = depth; best = spot }
        }
        return best
    }

    /// Plans a route from where the cat is to `to` (blanket-local) over the field of its patch; whether one
    /// was found. Home, its own seat is the end, whatever stands round it.
    func plan(_ actor: Actor, in plot: Plot, to: Vec2, _ stage: Stage) -> Bool {
        layField(for: actor, in: plot, stage)
        let offset = Vec2(plot.group.x, plot.group.z)
        let from = Vec2(actor.rootLocal.x, actor.rootLocal.z) + offset, goal = to + offset
        guard roamField.route(from: from, to: goal, into: &actor.roam.route) else { return false }
        for i in actor.roam.route.indices { actor.roam.route[i] -= offset }
        actor.roam.next = 0
        actor.roam.goal = goal
        return true
    }

    // MARK: the ground a cat may cross

    /// Whether a spot (world) is in a cat's own patch: near its blanket, nearer its blanket than any other,
    /// clear of other blankets and every flag, inside the meadow and in view.
    func inPatch(_ p: Vec2, of plot: Plot, _ stage: Stage) -> Bool {
        let middle = Vec2(plot.middle.x, plot.middle.z), away = p - middle, far = simd_length(away)
        let own = far - (far > 1e-3 ? clothReach(plot, toward: away / far) : 0)
        if own > ROAM_RANGE || hypot(p.x, p.y) > MeadowScenery.Limits.reach { return false }
        for other in plots where other !== plot {
            let theirs = simd_distance(p, Vec2(other.middle.x, other.middle.z)) - other.radius
            if theirs < 0.8 || theirs < own { return false }
        }
        // Every flag: the ground its pill stands over on screen, from a little in front of its foot back.
        let right = Vec2(stage.surroundings.right.x, stage.surroundings.right.z)
        let across = simd_length(right) > 1e-3 ? simd_normalize(right) : Vec2(1, 0), back = Vec2(across.y, -across.x)
        for q in plots {
            let foot = p - Vec2(q.flagAt.x, q.flagAt.z), half = max(q.flagHeight * q.label.aspect * 0.5, 0.6)
            if abs(simd_dot(foot, across)) < half + 0.5 && simd_dot(foot, back) > -1.4 { return false }
        }
        let s = screenOf(Vec3(p.x, 0, p.y)), top = screenOf(Vec3(p.x, 2.4, p.y))
        let v = stage.camera.viewport, cover = stage.camera.cover
        return s.z <= 1 && s.x > IN_VIEW && s.x < v.x - cover.x - IN_VIEW && top.y > IN_VIEW && s.y < v.y - cover.y - IN_VIEW
    }

    /// Lays the field of a cat's patch: its cells open where the cat may stand, each weighed by how much cats
    /// like walking there; closed round every footprint, picnic thing and other cat (and where they are going).
    private func layField(for actor: Actor, in plot: Plot, _ stage: Stage) {
        let size = max(actor.size, 0.4)
        let clearance = CLEARANCE * size
        let middle = Vec2(plot.middle.x, plot.middle.z)
        aimScreen(stage)
        roamField.reset(center: middle, half: plot.radius * Picnic.corner + ROAM_RANGE + 1.5)
        let liking = self.liking
        roamField.mark { p in
            // Its own blanket is its own ground; the rest is its patch.
            let onCloth = simd_distance(p, middle) < plot.radius * 0.8
            let open = onCloth || self.inPatch(p, of: plot, stage)
            return (open, RoamField.cost(liking: liking.map { $0(p) } ?? 0))
        }
        // The scenery's footprints, but those that make way under a blanket.
        for f in footing where roamField.reaches(Vec2(f.x, f.z), f.r + clearance) {
            let at = Vec2(f.x, f.z)
            if plots.contains(where: { simd_distance(at, Vec2($0.middle.x, $0.middle.z)) < $0.radius }) { continue }
            roamField.close(at, f.r + clearance)
        }
        for q in plots {
            for treat in q.treats where treat.wanted {
                roamField.close(Vec2(q.group.x + treat.at.x, q.group.z + treat.at.z), treat.reach + clearance * 0.6)
            }
            for other in q.liveActors where other !== actor && !other.leaving {
                let room = 0.85 * (other.shownSize + size)
                roamField.close(Vec2(other.cat.position.x, other.cat.position.z), room)
                if let goal = other.roam.goal { roamField.close(goal, room) }
                // And its seat, which it may come back to at any moment.
                roamField.close(Vec2(q.group.x + other.spot.x, q.group.z + other.spot.z), room * 0.8)
            }
            if q !== plot { roamField.close(Vec2(q.middle.x, q.middle.z), q.radius + 0.6) }
        }
    }

    /// The camera's projection, worked out once for a field's worth of spots.
    private func aimScreen(_ stage: Stage) {
        let v = stage.camera.viewport
        screenMatrix = stage.camera.projection(aspect: v.x / Swift.max(v.y, 1)) * stage.camera.viewMatrix
        screenSize = v
    }

    private func screenOf(_ p: Vec3) -> Vec3 {
        let clip: Vec4 = screenMatrix * Vec4(p.x, p.y, p.z, 1)
        if clip.w <= 0 { return Vec3(0, 0, 2) }
        let ndc = Vec3(clip.x, clip.y, clip.z) / clip.w
        return Vec3((ndc.x + 1) / 2 * screenSize.x, (1 - ndc.y) / 2 * screenSize.y, ndc.z)
    }

    // MARK: what the meadow holds

    /// The scenery's ground, flowers and trees' shade, for cats to go round, sniff and sleep under: worked out
    /// once when the scenery is laid.
    func lay(_ scenery: MeadowScenery, shade: [Vec4]) {
        footing = scenery.things.flatMap(SceneryRules.footprint)
        blooms = scenery.things.compactMap { thing in
            guard case .plant(_, _, true, _) = SceneryCatalog.kinds[thing.id] else { return nil }
            return Vec3(thing.x, 1.5 * thing.size.y, thing.z)
        }
        treeShade = shade.map { Vec3($0.x, $0.y, $0.z) }
    }
}

/// The ground round one blanket a cat may cross, as a grid of cells half a unit across: which are open, what
/// each costs to cross (less where cats like walking), and the cheapest way across it (A*, eight ways, the
/// corners then pulled straight wherever a straight line costs no more). Its lists are kept, so a route costs
/// no allocation.
struct RoamField {
    static let cell: Float = 0.5
    /// How much cheaper a cell cats like best is to cross than plain grass.
    static let pull: Float = 0.7
    private(set) var origin = Vec2.zero
    private(set) var side = 0
    private let most: Int
    private var open: [Bool]
    private var cost: [Float]
    private var best: [Float]
    private var from: [Int32]
    private var done: [Bool]
    /// Cells waiting to be looked at, and each one's key (its cost so far plus its guess), as a binary heap.
    private var heap: [Int32]
    private var keys: [Float]
    private var corners: [Vec2] = []

    init(most: Int = 72) {
        self.most = most
        let n = most * most
        open = [Bool](repeating: false, count: n)
        cost = [Float](repeating: 1, count: n)
        best = [Float](repeating: .infinity, count: n)
        from = [Int32](repeating: -1, count: n)
        done = [Bool](repeating: false, count: n)
        heap = []
        heap.reserveCapacity(n * 4)
        keys = []
        keys.reserveCapacity(n * 4)
        corners.reserveCapacity(n)
    }

    /// What crossing a cell costs, for how much cats like walking there (0 plain grass … 1 their favourite).
    static func cost(liking: Float) -> Float { 1 - pull * clamp(liking, 0, 1) }

    /// A square of `half` units each way round `center`, every cell shut.
    mutating func reset(center: Vec2, half: Float) {
        side = min(most, Int((half * 2 / Self.cell).rounded(.up)))
        origin = center - Vec2(repeating: Float(side) * Self.cell / 2)
        for i in 0..<(side * side) { open[i] = false; cost[i] = 1 }
    }

    /// Opens (or keeps shut) every cell, and weighs it, by what `judge` says of its middle.
    mutating func mark(_ judge: (Vec2) -> (open: Bool, cost: Float)) {
        for row in 0..<side {
            for column in 0..<side {
                let i = row * side + column
                let verdict = judge(middle(i))
                open[i] = verdict.open
                cost[i] = verdict.cost
            }
        }
    }

    /// Whether a circle reaches into the field at all.
    func reaches(_ c: Vec2, _ r: Float) -> Bool {
        let far = origin + Vec2(repeating: Float(side) * Self.cell)
        return c.x + r > origin.x && c.x - r < far.x && c.y + r > origin.y && c.y - r < far.y
    }

    /// Shuts every cell whose middle lies within a circle.
    mutating func close(_ c: Vec2, _ r: Float) {
        guard reaches(c, r) else { return }
        let lo = cellOf(c - Vec2(repeating: r)), hi = cellOf(c + Vec2(repeating: r))
        for row in max(0, lo.row)...min(side - 1, hi.row) {
            for column in max(0, lo.column)...min(side - 1, hi.column) where simd_distance(middle(row * side + column), c) < r {
                open[row * side + column] = false
            }
        }
    }

    /// Whether a spot is open ground.
    func open(_ p: Vec2) -> Bool { index(p).map { open[$0] } ?? false }

    /// The cheapest open way from `start` to `end`, as corners (`end` last; `start` left out), into `path`.
    /// The cells under both ends count as open. False when there is none.
    mutating func route(from start: Vec2, to end: Vec2, into path: inout [Vec2]) -> Bool {
        path.removeAll(keepingCapacity: true)
        guard let a = index(start), let b = index(end) else { return false }
        let wasA = open[a], wasB = open[b]
        open[a] = true
        open[b] = true
        defer { open[a] = wasA; open[b] = wasB }
        let n = side * side
        for i in 0..<n { best[i] = .infinity; from[i] = -1; done[i] = false }
        heap.removeAll(keepingCapacity: true)
        keys.removeAll(keepingCapacity: true)
        let target = middle(b)
        // Never more than the cheapest a cell can cost, so the guess never overestimates.
        let floor = 1 - Self.pull
        func guess(_ i: Int) -> Float { simd_distance(middle(i), target) * floor }
        best[a] = 0
        push(a, guess(a))
        var found = false
        while let i = pop() {
            if i == b { found = true; break }
            if done[i] { continue }
            done[i] = true
            let row = i / side, column = i % side
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let r = row + dr, c = column + dc
                    guard r >= 0, r < side, c >= 0, c < side else { continue }
                    let j = r * side + c
                    guard open[j], !done[j] else { continue }
                    // No cutting a corner between two shut cells.
                    if dr != 0 && dc != 0 && (!open[row * side + c] || !open[r * side + column]) { continue }
                    let step = (dr != 0 && dc != 0 ? 1.41421356 : 1) * Self.cell * (cost[i] + cost[j]) / 2
                    let through = best[i] + step
                    if through < best[j] {
                        best[j] = through
                        from[j] = Int32(i)
                        push(j, through + guess(j))
                    }
                }
            }
        }
        guard found else { return false }
        // The cells back from the end, then pulled straight: a corner stays only where a straight line past it
        // would cross shut ground or cost more.
        corners.removeAll(keepingCapacity: true)
        var at = b
        while at != a {
            corners.append(middle(at))
            at = Int(from[at])
        }
        corners.append(start)
        corners.reverse()
        corners[corners.count - 1] = end
        var anchor = 0
        while anchor < corners.count - 1 {
            var reach = anchor + 1
            var walked = cost(corners[anchor], corners[anchor + 1])
            for k in (anchor + 2)..<max(anchor + 2, corners.count) {
                walked += cost(corners[k - 1], corners[k])
                guard clear(corners[anchor], corners[k]) && cost(corners[anchor], corners[k]) <= walked + 1e-3 else { continue }
                reach = k
            }
            path.append(corners[reach])
            anchor = reach
        }
        return true
    }

    /// Whether a straight line between two spots stays on open ground.
    private func clear(_ p: Vec2, _ q: Vec2) -> Bool {
        let steps = max(1, Int(simd_distance(p, q) / (Self.cell * 0.5)))
        for s in 0...steps {
            guard let i = index(lerp(p, q, Float(s) / Float(steps))), open[i] else { return false }
        }
        return true
    }

    /// What crossing straight from one spot to another costs.
    private func cost(_ p: Vec2, _ q: Vec2) -> Float {
        let far = simd_distance(p, q), steps = max(1, Int(far / (Self.cell * 0.5)))
        var sum: Float = 0
        for s in 0..<steps {
            let at = lerp(p, q, (Float(s) + 0.5) / Float(steps))
            sum += index(at).map { cost[$0] } ?? 1
        }
        return sum / Float(steps) * far
    }

    private func middle(_ i: Int) -> Vec2 {
        origin + Vec2(Float(i % side) + 0.5, Float(i / side) + 0.5) * Self.cell
    }
    private func cellOf(_ p: Vec2) -> (row: Int, column: Int) {
        let q = (p - origin) / Self.cell
        return (Int(q.y.rounded(.down)), Int(q.x.rounded(.down)))
    }
    private func index(_ p: Vec2) -> Int? {
        let c = cellOf(p)
        guard c.row >= 0, c.row < side, c.column >= 0, c.column < side else { return nil }
        return c.row * side + c.column
    }

    // The heap: a cell may be in it more than once (each time a cheaper way to it is found); the stale ones
    // are passed over when popped (`done`).
    private mutating func push(_ i: Int, _ key: Float) {
        heap.append(Int32(i))
        keys.append(key)
        var k = heap.count - 1
        while k > 0 {
            let parent = (k - 1) / 2
            guard keys[k] < keys[parent] else { break }
            heap.swapAt(k, parent)
            keys.swapAt(k, parent)
            k = parent
        }
    }
    private mutating func pop() -> Int? {
        guard let top = heap.first else { return nil }
        let last = heap.removeLast(), lastKey = keys.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            keys[0] = lastKey
            var k = 0
            while true {
                let l = 2 * k + 1, r = l + 1
                var least = k
                if l < heap.count && keys[l] < keys[least] { least = l }
                if r < heap.count && keys[r] < keys[least] { least = r }
                if least == k { break }
                heap.swapAt(k, least)
                keys.swapAt(k, least)
                k = least
            }
        }
        return Int(top)
    }
}
