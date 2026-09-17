import Foundation
import simd

// Cats out in the grass (docs/DESIGN.md, "Idle cats wander"). A cat whose Claude has nothing for it gets up
// after a while and wanders near its blanket: a few hops through the grass or a short waddle, a sit to watch
// whatever flies past, a sniff at a flower, a loaf in the sun, a sit on a stump or in a box, a scratch at a post,
// a look in the bowl; then on, or back to its blanket. It does so on and off for some minutes, then naps (where
// it is, in a tree's shade, in a bed or a box, or back on its blanket), circling once before it curls up; after a
// long nap it now and then wakes, stretches, takes one short outing and naps again. The moment its Claude has
// work (or needs you, or anything else changes it), it turns and runs home, ears back, skids to a stop on its
// blanket and takes up the work; the blanket and its bubble say so from the first moment.
//
// Modelled on how real cats get about, in this cat's own way (its paws are short fixed nubs, so it has no leg
// cycle): a walk is a waddle that lifts it a little with each step, a bound through long grass is a series of
// hops with a look round between, running home is low fast bounds, and every move ends where it lands: the
// cat moves on only while it is up off its paws, so it never slides. Onto a stump or into a box it hops.
//
// It keeps to its own patch of grass: within `ROAM_RANGE` of its blanket's edge, nearer its blanket than any
// other, clear of every other blanket and every flag, and in view, so whose cat it is always reads. It goes
// round the scenery's footprints (trees, stones, logs, flowers, whatever the meadow holds; stepping stones are
// walked on), the picnic things and other cats, by a route over a grid (`RoamField`) that prefers the ground
// cats like (`Village.liking`: a painted path, stepping stones). It goes round a fence too, and through its gate
// with one high bound over the gate's leaf (`FenceLines`). A spot that invites a cat (`MeadowScenery.CatSpot`)
// holds one cat at a time. Out in short bursts with long still stops between, so between them the meadow rests
// as it always did.

/// How far past its blanket's edge a cat wanders, in units, at full size; and how far it goes for a spot at a
/// thing (things near a blanket make way for it, shrinking, so those that stand whole stand further out).
let ROAM_RANGE: Float = 3.6
let ROAM_SPOT_RANGE: Float = 8.5
/// Seconds (of the wall clock, not the meadow's slowed resting time) a cat rests on its blanket before its first
/// outing, at least and at most this much more; and between outings.
let ROAM_FIRST_REST: (least: Float, more: Float) = (22, 18)
let ROAM_REST: (least: Float, more: Float) = (25, 30)
/// Seconds of leisure before a cat lets itself doze off (its Claude says it may nap well before), and between
/// the wakings of a long nap, and how long such a waking lasts (a stretch and one short outing).
let ROAM_AWAKE: (least: Float, more: Float) = (240, 120)
let ROAM_NAP: (least: Float, more: Float) = (1200, 1500)
let ROAM_BREAK: (least: Float, more: Float) = (50, 30)
/// Cats out and about at once in one meadow, at most.
let ROAM_MOST_OUT = 2
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
/// Over a gate (or, hemmed in with no way round, a fence): how far before and past it a cat leaps from and lands,
/// how high its paws are as it passes over (the gate's palings stand 2.04 tall, a fence's top rail 1.81), and how
/// wide the way through a gate's posts is kept for it.
private let LEAP_RUNUP: Float = 1.1
private let LEAP_HEIGHT: Float = 2.3
private let GATEWAY: Float = 0.3
/// Points a cat out in the grass keeps inside the view's edges (its head and ears included).
private let IN_VIEW: Float = 16
/// The route's corners a cat keeps.
let ROAM_MOST_CORNERS = 48

/// A place at a thing of the scenery where a cat likes to be (`MeadowScenery.CatSpot`), in the meadow.
struct CatPlace {
    var kind: MeadowScenery.CatSpot.Kind
    /// Where its paws are (x, height, z), and which way it faces there.
    var at: Vec3
    var toward: Vec2
    /// The thing's middle on the ground, how far its footprint reaches, and its kind's id.
    var thing: Vec2
    var reach: Float
    var id: String
    /// On or in the thing (a stump's top, a box, a bed): reached with a hop, left with one. A bowl's or a
    /// post's is on the ground before it.
    var raised: Bool { at.y > 0.15 || simd_distance(Vec2(at.x, at.z), thing) < reach }
    /// Where a cat stands to hop up, or simply stands: in front of it, clear of its footprint.
    func approach(_ size: Float) -> Vec2 {
        let spot = Vec2(at.x, at.z)
        guard raised else { return spot }
        return spot + toward * max(0.6 * size, reach + 0.45 * size - simd_dot(spot - thing, toward))
    }
    /// Somewhere to sleep: a bed, a cushion, a box.
    var forNapping: Bool { kind == .nap || id == "cat.box" }
}

/// A cat's life off its blanket.
struct Roam {
    enum Phase {
        /// On its blanket, in its seat (`rested`: when, by the clock, it may next set off).
        case home
        /// On its way to a stop, or home (`homeward`).
        case travelling
        /// At a stop, doing `outing` until `until`.
        case stopped
        /// Turning round once where it means to sleep, before it curls up (until `until`).
        case circling
        /// Asleep out in the grass (or in a bed, a box).
        case asleep
        /// Called back: running home (from `until`, once awake).
        case recalled
        /// Just home from a run: skidding to a stop and settling (until `until`).
        case settling
    }
    var phase = Phase.home
    var until: Float = 0
    /// When, by the clock, it may next set off from its blanket.
    var rested: Float = 0
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
    /// A hop under way (from, to, when it left, how long it is in the air, how fast it rose), or when the next
    /// may leave.
    var hopFrom = Vec3.zero, hopTo = Vec3.zero
    var hopAt: Float = -1, hopFor: Float = 0, hopNext: Float = 0, hopRise: Float = 0
    /// The route's corners reached by a leap over a fence (from the corner before), and whether one is under way.
    var leaps: [Int] = []
    var leaping = false
    /// The spot it is going to or is at (`Village.places`), the hop up onto it still to come, and the hop down
    /// off it before it goes anywhere (blanket-local).
    var spot: Int?
    var mount: Vec3?
    var dismount: Vec3?
    /// Where it means to sleep, and whether it has looked for such a place yet this nap.
    var bed: Vec2?
    var bedChosen = false
    /// Its route home is still to be found (it was called back between frames).
    var replan = false
    /// By the clock: since when it has been at leisure; when it lets itself doze off; when it next wakes for a
    /// while from a long nap, and until when that waking lasts.
    var leisureSince: Float?
    var dozeAt: Float = .infinity
    var wakeAt: Float = .infinity
    var awakeUntil: Float = 0
    /// Out for one short outing only (woken from a nap).
    var brief = false
    /// Asked by the app's checks for one outing (`MeadowView.sendOut`): a stop out in the grass, reached in bounds,
    /// then home; never what a cat chooses for itself.
    var asked = false
    /// How many stops it has reached off its blanket's cloth, and how many hops it has made: counts that only
    /// grow, for the app's checks to wait on what happened rather than catch a moment of it.
    var grassStops = 0
    var hops = 0
    var random: Seeded

    init(seed: String) {
        random = chance("roam/" + seed)
        route.reserveCapacity(ROAM_MOST_CORNERS)
        leaps.reserveCapacity(8)
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

    /// What a cat shows of what its Claude does. Its Claude may let it nap soon after its turn; a cat that may
    /// wander stays up and about for some minutes first (`dozeAt`), and wakes now and then from a long nap
    /// (`wakeAt`). Otherwise what it is told.
    func display(_ activity: AgentActivity, for actor: Actor) -> AgentActivity {
        guard activity == .napping, wanders else { return activity }
        if clock < actor.roam.dozeAt { return .idle }
        if clock >= actor.roam.wakeAt && clock < actor.roam.awakeUntil { return .awake }
        return .napping
    }

    /// A cat new to the meadow: its first outing after a rest, or, already napping (the app opened on a long
    /// idle Claude), asleep at once, its first waking a long nap away.
    func meet(_ actor: Actor) {
        actor.roam.rested = clock + actor.roam.pick(ROAM_FIRST_REST.least, ROAM_FIRST_REST.more)
        if actor.view.activity == .napping {
            actor.roam.dozeAt = clock
            actor.roam.wakeAt = clock + actor.roam.pick(ROAM_NAP.least, ROAM_NAP.more)
            actor.roam.awakeUntil = actor.roam.wakeAt + actor.roam.pick(ROAM_BREAK.least, ROAM_BREAK.more)
        }
    }

    /// The cat's day: since when it is at leisure, when it dozes off, when it wakes from a long nap and for how
    /// long; and what it shows by now (an outing waits for a cat's state, not the other way round).
    private func keepDay(_ actor: Actor, _ plot: Plot) {
        guard atLeisure(actor, plot) else {
            actor.roam.leisureSince = nil
            actor.roam.dozeAt = .infinity
            actor.roam.wakeAt = .infinity
            return
        }
        if actor.roam.leisureSince == nil {
            actor.roam.leisureSince = clock
            if actor.roam.dozeAt == .infinity { actor.roam.dozeAt = clock + actor.roam.pick(ROAM_AWAKE.least, ROAM_AWAKE.more) }
        }
        if clock >= actor.roam.dozeAt && actor.roam.wakeAt == .infinity {
            actor.roam.wakeAt = clock + actor.roam.pick(ROAM_NAP.least, ROAM_NAP.more)
            actor.roam.awakeUntil = actor.roam.wakeAt + actor.roam.pick(ROAM_BREAK.least, ROAM_BREAK.more)
        }
        if clock >= actor.roam.awakeUntil && actor.roam.awakeUntil > 0 && clock >= actor.roam.wakeAt {
            // Back to sleep; the next waking a long nap away.
            actor.roam.wakeAt = clock + actor.roam.pick(ROAM_NAP.least, ROAM_NAP.more)
            actor.roam.awakeUntil = actor.roam.wakeAt + actor.roam.pick(ROAM_BREAK.least, ROAM_BREAK.more)
        }
        let effective: AgentActivity = actor.view.failed ? .error : actor.view.activity
        let want = display(effective, for: actor)
        if want != (actor.queue.last ?? actor.cat.activity) {
            let wasAsleep = actor.cat.isNapping
            enqueue(actor, want)
            // Woken from a long nap: a stretch, then one short outing.
            if wasAsleep && want == .awake {
                actor.roam.brief = true
                actor.roam.rested = clock + 2.5
            }
        }
    }

    // MARK: being told

    /// A cat's state changed (`upsert`): one out in the grass that is no longer at leisure runs home.
    func reconsider(_ actor: Actor, in plot: Plot) {
        guard actor.roam.out, !atLeisure(actor, plot), actor.roam.phase != .recalled, actor.roam.phase != .settling else { return }
        recall(actor, in: plot)
    }

    /// Every cat out comes home at once, as it is (the switch turned off, Reduce Motion, the animation held):
    /// cats then stay on their blankets as they always did, and nap when they are told.
    func bringEveryoneHome() {
        for plot in plots {
            for actor in plot.actors.values {
                if actor.roam.out {
                    actor.rootLocal = actor.spot
                    settleHome(actor)
                }
                let effective: AgentActivity = actor.view.failed ? .error : actor.view.activity
                if !actor.leaving, effective != (actor.queue.last ?? actor.cat.activity) { enqueue(actor, effective) }
            }
        }
    }

    /// Every cat at leisure dozes off now rather than after its minutes up and about (the app's measuring runs,
    /// which time the meadow at rest).
    func letCatsDozeOff() {
        for plot in plots { for actor in plot.actors.values where actor.roam.dozeAt > clock { actor.roam.dozeAt = clock } }
    }

    private func settleHome(_ actor: Actor) {
        actor.roam.phase = .home
        actor.roam.goal = nil
        actor.roam.bed = nil
        actor.roam.bedChosen = false
        actor.roam.hopAt = -1
        actor.roam.spot = nil
        actor.roam.mount = nil
        actor.roam.dismount = nil
        actor.roam.brief = false
        actor.roam.asked = false
        actor.roam.leaping = false
        actor.roam.leaps.removeAll(keepingCapacity: true)
        actor.roam.rested = clock + actor.roam.pick(ROAM_REST.least, ROAM_REST.more)
        let cat = actor.cat
        cat.leap = nil
        cat.gait = .none
        cat.outing = nil
        cat.going = nil
        cat.facingSpot = nil
    }

    /// Called back: it wakes if asleep, turns and runs home the shortest clear way (down off a stump or out of
    /// a box first). With motion reduced it is simply home.
    private func recall(_ actor: Actor, in plot: Plot) {
        guard !hushed else {
            actor.rootLocal = actor.spot
            return settleHome(actor)
        }
        let cat = actor.cat
        // Only just up from its seat: it simply sits back down to work.
        if simd_distance(actor.rootLocal, actor.spot) < 0.3 && actor.roam.hopAt < 0 { return settleHome(actor) }
        let asleep = actor.roam.phase == .asleep || cat.isNapping
        leaveSpot(actor, plot)
        actor.roam.phase = .recalled
        actor.roam.gait = .run
        actor.roam.mount = nil
        // Awake at once, on its feet a moment later.
        actor.roam.until = time + (asleep ? 0.35 : 0)
        cat.outing = nil
        // Its way home is found on the next frame, with the view as it is then.
        actor.roam.route.removeAll(keepingCapacity: true)
        actor.roam.next = 0
        actor.roam.replan = true
        actor.roam.goal = Vec2(plot.group.x + actor.spot.x, plot.group.z + actor.spot.z)
    }

    /// Off the spot it was at or going to: free for another cat, with a hop down first if it is up on it (a hop
    /// under way finishes first: it is carried on to where it was going).
    private func leaveSpot(_ actor: Actor, _ plot: Plot) {
        actor.cat.facingSpot = nil
        guard let i = actor.roam.spot else { return }
        actor.roam.spot = nil
        guard i < places.count, places[i].raised, actor.roam.mount == nil else { return }
        let size = max(actor.size, 0.4)
        let ground = places[i].approach(size) - Vec2(plot.group.x, plot.group.z)
        actor.roam.dismount = Vec3(ground.x, 0, ground.y)
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
        if wanders { keepDay(actor, plot) }
        switch actor.roam.phase {
        case .home:
            actor.rootLocal += (actor.spot - actor.rootLocal) * min(1, dt * 3.5)
            guard atLeisure(actor, plot) else {
                // Busy: its next outing waits a full rest after it is free again.
                actor.roam.rested = max(actor.roam.rested, clock + ROAM_FIRST_REST.least)
                return
            }
            let ready = (cat.activity == .awake || cat.activity == .idle) && actor.queue.isEmpty && !cat.isNapping
            if ready && clock >= actor.roam.rested && !cat.watched && !cat.petting && simd_distance(actor.rootLocal, actor.spot) < 0.05 {
                // A meadow of idle cats takes turns: two out and about at once at most, the rest a while later,
                // so the meadow is still between their bursts.
                if outAndAbout() >= ROAM_MOST_OUT { actor.roam.rested = clock + actor.roam.pick(6, 10) } else { setOut(actor, in: plot, stage) }
            }
        case .stopped:
            if cat.isNapping { return lieDown(actor, in: plot, stage) }
            guard time >= actor.roam.until else { return }
            switch actor.roam.outing {
            case .sniff, .scratch:
                // A sniff or a scratch, then a sit to look about, there.
                actor.roam.outing = .watch
                cat.outing = .watch
                actor.roam.until = time + actor.roam.pick(3, 3)
            default:
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
            // Woken with nothing to do (a while up from a long nap): a stretch, a look round, then one short outing.
            if !cat.isNapping {
                actor.roam.phase = .stopped
                actor.roam.outing = .watch
                cat.outing = .watch
                cat.fidget("stretch")
                actor.roam.until = time + actor.roam.pick(3, 3)
                actor.roam.stopsLeft = 1
                actor.roam.brief = true
                actor.roam.bed = nil
                actor.roam.bedChosen = false
            }
        case .recalled:
            if time < actor.roam.until { return }
            // Called in the middle of a bound, it lands first (over a gate: on its far side), then sets off home
            // from there.
            if actor.roam.replan && actor.roam.hopAt >= 0 {
                guard flight(actor) else { return }
                actor.roam.leaping = false
            }
            if actor.roam.replan {
                actor.roam.replan = false
                if !plan(actor, in: plot, to: Vec2(actor.spot.x, actor.spot.z), stage) { straight(actor, in: plot, to: actor.spot, stage) }
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

    /// Up off the blanket: it sits up and looks about a moment, then sets off on an outing of a stop or three
    /// (one, woken from a nap).
    private func setOut(_ actor: Actor, in plot: Plot, _ stage: Stage) {
        actor.roam.stopsLeft = actor.roam.brief || actor.roam.asked ? 1 : 1 + Int(actor.roam.random.float() * 2.99)
        if actor.roam.brief { actor.cat.fidget("stretch") }
        actor.roam.phase = .stopped
        actor.roam.outing = .watch
        actor.cat.outing = .watch
        actor.roam.until = time + actor.roam.pick(0.8, 0.6) + (actor.roam.brief ? 1.6 : 0)
        actor.roam.homeward = false
    }

    /// The stop is over: on to the next, or home.
    private func onward(_ actor: Actor, in plot: Plot, _ stage: Stage) {
        leaveSpot(actor, plot)
        if actor.roam.stopsLeft > 0, let target = chooseStop(actor, in: plot, stage, sleepy: false),
           plan(actor, in: plot, to: target.at, stage, opening: target.spot != nil) {
            actor.roam.stopsLeft -= 1
            actor.roam.outing = actor.roam.asked ? .watch : target.outing
            take(target.spot, for: actor, in: plot)
            // Through the grass a cat bounds more often than it walks; across its blanket it walks.
            actor.roam.gait = actor.roam.asked ? .bound : target.onCloth || actor.roam.random.float() < 0.35 ? .walk : .bound
            return depart(actor)
        }
        // Home again, at an easy pace.
        actor.roam.gait = actor.roam.random.float() < 0.6 ? .walk : .bound
        if !plan(actor, in: plot, to: Vec2(actor.spot.x, actor.spot.z), stage) { straight(actor, in: plot, to: actor.spot, stage) }
        depart(actor, home: true)
    }

    /// Claims a spot (`places`) for this cat, with the hop up onto it still to come when it is raised.
    private func take(_ spot: Int?, for actor: Actor, in plot: Plot) {
        actor.roam.spot = spot
        actor.roam.mount = nil
        guard let spot else { return }
        let place = places[spot]
        if place.raised { actor.roam.mount = place.at - Vec3(plot.group.x, 0, plot.group.z) }
    }

    private func depart(_ actor: Actor, home: Bool = false) {
        actor.roam.phase = .travelling
        actor.roam.homeward = home
        actor.roam.hopAt = -1
        actor.roam.hopNext = time
        actor.cat.outing = nil
    }

    /// Arrived at a stop: it does what it came for, facing the thing's way at a spot.
    private func stop(_ actor: Actor, in plot: Plot) {
        let cat = actor.cat
        cat.gait = .none
        cat.going = nil
        actor.roam.phase = .stopped
        let away = Vec2(cat.position.x - plot.middle.x, cat.position.z - plot.middle.z), far = simd_length(away)
        if far > 1e-3 && far > clothReach(plot, toward: away / far) + 0.3 { actor.roam.grassStops += 1 }
        if let i = actor.roam.spot {
            cat.facingSpot = places[i].at + Vec3(places[i].toward.x, 0, places[i].toward.y) * 3
        }
        let outing = actor.roam.outing
        cat.outing = outing
        let stay: Float = switch outing {
        case .sniff: actor.roam.pick(2.4, 1)
        case .scratch: actor.roam.pick(2.6, 0.9)
        case .watch: actor.roam.pick(4.5, 4)
        case .loaf: actor.roam.pick(10, 9)
        }
        actor.roam.until = time + stay
    }

    /// Fallen asleep out in the grass: it naps where it is, or first goes somewhere nicer nearby (a free bed, box
    /// or cushion; a tree's shade; its own blanket), as this cat likes, and circles once before it curls up.
    private func lieDown(_ actor: Actor, in plot: Plot, _ stage: Stage) {
        let cat = actor.cat
        cat.outing = nil
        if !actor.roam.bedChosen {
            actor.roam.bedChosen = true
            // Already in a bed or a box: here.
            if let i = actor.roam.spot, places[i].forNapping { return circle(actor) }
            let here = Vec2(plot.group.x + actor.rootLocal.x, plot.group.z + actor.rootLocal.z)
            let offset = Vec2(plot.group.x, plot.group.z)
            if let target = chooseStop(actor, in: plot, stage, sleepy: true), target.spot != nil {
                leaveSpot(actor, plot)
                if plan(actor, in: plot, to: target.at, stage, opening: true) {
                    take(target.spot, for: actor, in: plot)
                    actor.roam.bed = target.at + offset
                    actor.roam.gait = .walk
                    return depart(actor)
                }
            }
            let taste = actor.roam.random.float()
            let seat = Vec2(plot.group.x + actor.spot.x, plot.group.z + actor.spot.z)
            var bed: Vec2? = nil
            if taste < 0.45, let shade = shadeNear(here, plot, stage) { bed = shade } else if taste > 0.8 { bed = seat }
            if let bed, simd_distance(bed, here) > 0.8 {
                leaveSpot(actor, plot)
                if plan(actor, in: plot, to: bed - offset, stage) {
                    actor.roam.bed = bed
                    actor.roam.gait = .walk
                    // Home to sleep in its seat, as cats on their blankets always have; else to the shade.
                    return depart(actor, home: bed == seat)
                }
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

    /// Moves a cat along its route by its gait; whether it has arrived. Down off a spot first, and up onto the
    /// one it is going to last, each with a hop.
    private func travel(_ actor: Actor, in plot: Plot, _ dt: Float) -> Bool {
        let cat = actor.cat
        let size = max(actor.size, 0.4)
        cat.outing = nil
        if let down = actor.roam.dismount {
            if hop(actor, in: plot, to: down) { actor.roam.dismount = nil }
            return false
        }
        // Over a fence's gate: one high bound from the corner before it to the corner past it.
        if actor.roam.leaping || leapsNext(actor) {
            actor.roam.leaping = true
            let c = actor.roam.route[actor.roam.next]
            guard hop(actor, in: plot, to: Vec3(c.x, 0, c.y), clearing: LEAP_HEIGHT) else { return false }
            actor.roam.leaping = false
            actor.roam.next += 1
            actor.roam.hopNext = time + actor.roam.pick(0.3, 0.3)
            actor.roam.ramp = 0
            actor.roam.stride = 0
        }
        let arrived: Bool
        if actor.roam.gait == .bound && actor.roam.hopAt < 0 && actor.roam.next >= actor.roam.route.count {
            arrived = true
        } else if actor.roam.gait == .bound {
            arrived = bound(actor, in: plot, size)
        } else {
            arrived = walk(actor, in: plot, dt, size)
        }
        guard arrived else { return false }
        if let up = actor.roam.mount {
            if hop(actor, in: plot, to: up) { actor.roam.mount = nil; return true }
            return false
        }
        return true
    }

    /// Walking or running: turned to the way it goes first, then step by step, moving on only while lifted.
    private func walk(_ actor: Actor, in plot: Plot, _ dt: Float, _ size: Float) -> Bool {
        let cat = actor.cat
        guard actor.roam.next < actor.roam.route.count else {
            cat.gait = .none
            return true
        }
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
        while left > 0 && actor.roam.next < actor.roam.route.count && !actor.roam.leaps.contains(actor.roam.next) {
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
        if actor.roam.next >= actor.roam.route.count || leapsNext(actor) {
            // Arrived, or come to where it leaps over a gate (`travel`): its step ends here.
            actor.roam.ramp = 0
            actor.roam.stride = 0
            cat.stride = 0
            cat.gait = .none
            return actor.roam.next >= actor.roam.route.count
        }
        return false
    }

    /// Whether the cat stands where its route leaps over a fence: at the corner before a leap's landing.
    private func leapsNext(_ actor: Actor) -> Bool {
        let next = actor.roam.next
        guard next > 0, next < actor.roam.route.count, actor.roam.hopAt < 0, actor.roam.leaps.contains(next) else { return false }
        return simd_distance(Vec2(actor.rootLocal.x, actor.rootLocal.z), actor.roam.route[next - 1]) < 0.01
    }

    /// Bounding through the grass: hop by hop along the route, turned to each before it leaves, a look round
    /// between. Carried forward only while in the air, landing exactly where it was going.
    private func bound(_ actor: Actor, in plot: Plot, _ size: Float) -> Bool {
        let cat = actor.cat
        cat.gait = .bound
        if actor.roam.hopAt >= 0 {
            // Along and up together, on one clock: it lands exactly where, and when, it was going.
            guard flight(actor) else { return false }
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
        let here = Vec2(actor.rootLocal.x, actor.rootLocal.z)
        var at = here, left = HOP_LENGTH * size, index = actor.roam.next
        // Never past where it leaps over a gate: that is a bound of its own (`travel`).
        while index < actor.roam.route.count && !actor.roam.leaps.contains(index) {
            let c = actor.roam.route[index], far = simd_distance(c, at)
            if far <= left { at = c; left -= far; index += 1 } else { at += (c - at) / far * left; break }
        }
        // A last scrap of a hop is folded into the one before it.
        if index == actor.roam.route.count - 1, !actor.roam.leaps.contains(index), simd_distance(actor.roam.route[index], at) < 0.35 * size {
            at = actor.roam.route[index]
            index += 1
        }
        guard simd_distance(at, here) > 1e-3 else { return false }
        let landing = Vec3(at.x, 0, at.y)
        cat.going = plot.group + landing
        guard cat.turned(from: plot.group + landing) < 0.3 else { return false }
        launch(actor, to: landing, speed: HOP_SPEED * (0.75 + 0.25 * size))
        actor.roam.next = index
        return false
    }

    /// One hop to a spot (blanket-local, its height too): up onto a stump, into a box, down again; over a gate, its
    /// paws `clearing` that high at the top of the bound. Turned to it first; whether it has landed.
    private func hop(_ actor: Actor, in plot: Plot, to target: Vec3, clearing: Float = 0) -> Bool {
        let cat = actor.cat
        cat.gait = .bound
        if actor.roam.hopAt >= 0 {
            guard flight(actor) else { return false }
            cat.gait = .none
            return true
        }
        let world = plot.group + Vec3(target.x, 0, target.z)
        cat.going = world
        guard cat.turned(from: world) < 0.3, cat.height == 0 else { return false }
        // Higher up wants a stronger spring: the arc clears the edge it lands over.
        launch(actor, to: target, speed: max(HOP_SPEED + max(0, target.y - actor.rootLocal.y) * 1.6, (2 * -GRAVITY * clearing).squareRoot()))
        return false
    }

    private func launch(_ actor: Actor, to landing: Vec3, speed: Float) {
        actor.roam.hops += 1
        actor.roam.hopRise = speed
        actor.roam.hopFrom = actor.rootLocal
        actor.roam.hopTo = landing
        actor.roam.hopAt = time
        actor.roam.hopFor = 2 * speed / -GRAVITY
    }

    /// A hop's flight this frame: along from where it left to where it lands and up its arc, on one clock;
    /// whether it has landed.
    private func flight(_ actor: Actor) -> Bool {
        let u = min(1, (time - actor.roam.hopAt) / actor.roam.hopFor), rise = actor.roam.hopRise
        actor.rootLocal = lerp(actor.roam.hopFrom, actor.roam.hopTo, u)
        actor.cat.leap = (rise * rise / (2 * -GRAVITY) * 4 * u * (1 - u), rise * (1 - 2 * u))
        guard u >= 1 else { return false }
        actor.roam.hopAt = -1
        return true
    }

    /// A route of one straight leg, when no better one is found (a cat hemmed in by others, say), over any fence
    /// in the way.
    private func straight(_ actor: Actor, in plot: Plot, to spot: Vec3, _ stage: Stage) {
        actor.roam.route.removeAll(keepingCapacity: true)
        actor.roam.route.append(Vec2(spot.x, spot.z))
        actor.roam.next = 0
        leapFences(actor, in: plot, stage)
    }

    /// Whether a fence's line stands: its posts (each of its parts is drawn from one) not shrunk away for a blanket
    /// come near, as every rooted thing makes way (`Meadow.standing`). One that has made way is neither gone round
    /// nor leapt.
    func stands(_ line: FenceLines.Line, _ stage: Stage) -> Bool {
        min(Meadow.standing(line.a.x, line.a.y, 0, stage.world.clearings, stage.clearingCount),
            Meadow.standing(line.b.x, line.b.y, 0, stage.world.clearings, stage.clearingCount)) > 0.5
    }

    /// Where its route crosses a fence (at a gate; or, on a straight way when no route was found, anywhere), a
    /// leap: the route goes square on to the gate's middle (a fence: where it is met) to a corner a run-up before
    /// it, then lands as far past it; corners nearer the gate than that are passed over, and a last one is moved
    /// out to where it lands.
    private func leapFences(_ actor: Actor, in plot: Plot, _ stage: Stage) {
        actor.roam.leaps.removeAll(keepingCapacity: true)
        actor.roam.leaping = false
        guard !fences.isEmpty else { return }
        let offset = Vec2(plot.group.x, plot.group.z)
        let start = actor.roam.dismount.map { Vec2($0.x, $0.z) } ?? Vec2(actor.rootLocal.x, actor.rootLocal.z)
        var i = 0
        while i < actor.roam.route.count && actor.roam.leaps.count < 8 {
            let from = i == 0 ? start : actor.roam.route[i - 1], to = actor.roam.route[i]
            guard !actor.roam.leaps.contains(i), let crossing = fences.firstCrossing(from + offset, to + offset, standing: { stands($0, stage) }) else {
                i += 1
                continue
            }
            let at = (crossing.gate ? crossing.line.middle : crossing.at) - offset
            let across = simd_dot(crossing.line.across, to - from) < 0 ? -crossing.line.across : crossing.line.across
            let before = at - across * LEAP_RUNUP, after = at + across * LEAP_RUNUP
            // Within the run-up either side, square on to it.
            func beside(_ p: Vec2) -> Bool { abs(simd_dot(p - at, Vec2(across.y, -across.x))) < LEAP_RUNUP && abs(simd_dot(p - at, across)) < LEAP_RUNUP }
            while i > 0, !actor.roam.leaps.contains(i - 1), beside(actor.roam.route[i - 1]) {
                actor.roam.route.remove(at: i - 1)
                i -= 1
            }
            while i < actor.roam.route.count - 1, beside(actor.roam.route[i]) { actor.roam.route.remove(at: i) }
            if beside(actor.roam.route[i]) {
                actor.roam.route[i] = after
                actor.roam.route.insert(before, at: i)
            } else {
                actor.roam.route.insert(contentsOf: [before, after], at: i)
            }
            actor.roam.leaps.append(i + 1)
        }
        actor.roam.goal = (actor.roam.route.last ?? start) + offset
    }

    // MARK: choosing where

    /// A stop worth going to. A spot that invites a cat (a stump to sit on, a box, a post to scratch, a bowl) is
    /// preferred when one is free and in reach; else open ground in its patch (or now and then a corner of its
    /// own blanket), a short way off, across or toward you rather than away, by a flower to sniff, on ground it
    /// likes. Sleepy, only a bed, a box or a cushion will do. `at` is where it walks to (blanket-local); `spot`
    /// the place it will take there.
    private func chooseStop(_ actor: Actor, in plot: Plot, _ stage: Stage, sleepy: Bool) -> (at: Vec2, outing: Cat.Outing, onCloth: Bool, spot: Int?)? {
        let size = max(actor.size, 0.4)
        layField(for: actor, in: plot, stage)
        let here = Vec2(plot.group.x + actor.rootLocal.x, plot.group.z + actor.rootLocal.z)
        let offset = Vec2(plot.group.x, plot.group.z)
        let middle = Vec2(plot.middle.x, plot.middle.z)
        var toYou = Vec2(stage.camera.eye.x - here.x, stage.camera.eye.z - here.y)
        toYou = simd_length(toYou) > 1e-3 ? simd_normalize(toYou) : Vec2(0, 1)
        // A free spot within reach.
        var spot: (index: Int, at: Vec2, score: Float)?
        for (i, place) in places.enumerated() where !sleepy || place.forNapping {
            guard !taken(i, by: actor) else { continue }
            let stand = place.approach(size)
            // Not the one it is at now; standing whole (not shrunk away for a blanket); in its patch.
            guard simd_distance(Vec2(place.at.x, place.at.z), here) > 0.6, simd_distance(stand, here) > 0.5 || place.raised,
                  Meadow.standing(place.thing.x, place.thing.y, place.reach, stage.world.clearings, stage.clearingCount) > 0.95,
                  inPatch(stand, of: plot, stage, reach: ROAM_SPOT_RANGE) else { continue }
            let score = -simd_distance(stand, here) * 0.2 + actor.roam.random.float()
            if score > spot?.score ?? -.infinity { spot = (i, stand, score) }
        }
        if let spot, !actor.roam.asked, sleepy || actor.roam.random.float() < 0.8 {
            let place = places[spot.index], thing = Vec3(place.thing.x, 0, place.thing.y)
            let outing: Cat.Outing = switch place.id {
            case "cat.scratchingPost": .scratch(thing + Vec3(0, 1.3, 0))
            case "cat.bowl": .sniff(thing + Vec3(0, 0.25, 0))
            default: place.kind == .nap ? .loaf : .watch
            }
            return (spot.at - offset, outing, false, spot.index)
        }
        if sleepy { return nil }
        var best: (at: Vec2, outing: Cat.Outing, onCloth: Bool, score: Float)?
        for _ in 0..<28 {
            let a = actor.roam.random.float() * 2 * .pi, dir = Vec2(sin(a), cos(a))
            let edge = clothReach(plot, toward: dir)
            // Asked for an outing (`MeadowView.sendOut`): out in the grass, never on its blanket.
            let onCloth = !actor.roam.asked && actor.roam.random.float() < 0.12
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
        return best.map { ($0.at - offset, $0.outing, $0.onCloth, nil) }
    }

    /// Cats off their blankets and not asleep.
    private func outAndAbout() -> Int {
        var n = 0
        for plot in plots { for actor in plot.actors.values where actor.roam.out && actor.roam.phase != .asleep { n += 1 } }
        return n
    }

    /// Whether another cat is at a spot, or on its way to it.
    private func taken(_ spot: Int, by actor: Actor) -> Bool {
        for plot in plots { for other in plot.actors.values where other !== actor && other.roam.spot == spot { return true } }
        return false
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

    /// Plans a route from where the cat is (where it hops down to, when it is up on a spot) to `to`
    /// (blanket-local) over the field of its patch; whether one was found.
    func plan(_ actor: Actor, in plot: Plot, to: Vec2, _ stage: Stage, opening: Bool = false) -> Bool {
        layField(for: actor, in: plot, stage)
        let offset = Vec2(plot.group.x, plot.group.z)
        // Up to a spot at a thing: the grass kept round the thing's footprint is crossed to stand by it.
        if opening { roamField.clear(to + offset, 0.7 * max(actor.size, 0.4)) }
        let start = actor.roam.dismount.map { Vec2($0.x, $0.z) } ?? Vec2(actor.rootLocal.x, actor.rootLocal.z)
        let goal = to + offset
        guard roamField.route(from: start + offset, to: goal, fences: fences, standing: { self.stands($0, stage) }, into: &actor.roam.route) else { return false }
        for i in actor.roam.route.indices { actor.roam.route[i] -= offset }
        actor.roam.next = 0
        actor.roam.goal = goal
        leapFences(actor, in: plot, stage)
        return true
    }

    // MARK: the ground a cat may cross

    /// Whether a spot (world) is in a cat's own patch: near its blanket, nearer its blanket than any other,
    /// clear of other blankets and every flag, inside the meadow and in view.
    func inPatch(_ p: Vec2, of plot: Plot, _ stage: Stage, reach: Float = ROAM_RANGE) -> Bool {
        let middle = Vec2(plot.middle.x, plot.middle.z), away = p - middle, far = simd_length(away)
        let own = far - (far > 1e-3 ? clothReach(plot, toward: away / far) : 0)
        if own > reach || hypot(p.x, p.y) > MeadowScenery.Limits.reach { return false }
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
        roamField.reset(center: middle, half: plot.radius * Picnic.corner + ROAM_SPOT_RANGE + 1.5)
        let liking = self.liking
        roamField.mark { p in
            // Its own blanket is its own ground; the rest is its patch, out as far as a spot it may go to.
            let onCloth = simd_distance(p, middle) < plot.radius * 0.8
            let open = onCloth || self.inPatch(p, of: plot, stage, reach: ROAM_SPOT_RANGE)
            return (open, RoamField.cost(liking: liking.map { $0(p) } ?? 0))
        }
        // The scenery's footprints, but those that make way under a blanket.
        for f in footing where roamField.reaches(Vec2(f.x, f.z), f.r + clearance) {
            let at = Vec2(f.x, f.z)
            if plots.contains(where: { simd_distance(at, Vec2($0.middle.x, $0.middle.z)) < $0.radius }) { continue }
            roamField.close(at, f.r + clearance)
        }
        // A gate is a way through the grass kept round its posts, square on to it, where both sides are its patch.
        fences.gates(near: middle, half: plot.radius * Picnic.corner + ROAM_SPOT_RANGE + 1.5) { gate in
            guard stands(gate, stage) else { return }
            let a = gate.middle - gate.across * (LEAP_RUNUP + 0.5), b = gate.middle + gate.across * (LEAP_RUNUP + 0.5)
            guard inPatch(a, of: plot, stage, reach: ROAM_SPOT_RANGE), inPatch(b, of: plot, stage, reach: ROAM_SPOT_RANGE) else { return }
            roamField.clear(from: a, to: b, GATEWAY * size)
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

    /// The scenery's ground, flowers, trees' shade and the spots its things offer cats, for cats to go round
    /// (never a stepping stone: those are walked on), sniff, sleep under and use: worked out once when the
    /// scenery is laid.
    func lay(_ scenery: MeadowScenery, shade: [Vec4], fences: FenceLines) {
        footing = scenery.things.filter { SceneryCatalog.treads[$0.id]?.walked != true }.flatMap(SceneryRules.footprint)
        self.fences = fences
        blooms = scenery.things.compactMap { thing in
            guard case .plant(_, _, true, _) = SceneryCatalog.kinds[thing.id] else { return nil }
            return Vec3(thing.x, 1.5 * thing.size.y, thing.z)
        }
        treeShade = shade.map { Vec3($0.x, $0.y, $0.z) }
        places = scenery.things.compactMap { thing in
            guard let spot = thing.catSpot else { return nil }
            let reach = SceneryRules.footprint(of: thing).map(\.r).max() ?? 0
            return CatPlace(kind: spot.kind, at: spot.at, toward: spot.toward, thing: Vec2(thing.x, thing.z), reach: reach, id: thing.id)
        }
        // A cat at or going to a spot that is no more simply carries on where it is.
        for plot in plots { for actor in plot.actors.values where (actor.roam.spot ?? 0) >= places.count { actor.roam.spot = nil; actor.roam.mount = nil } }
    }
}

/// The ground round one blanket a cat may cross, as a grid of cells half a unit across: which are open, what
/// each costs to cross (less where cats like walking), and the cheapest way across it (A*, eight ways, the
/// corners then pulled straight wherever a straight line costs no more), never across a fence but at its gate
/// (`FenceLines`). Its lists are kept, so a route costs no allocation.
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

    init(most: Int = 96) {
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

    /// Opens every cell whose middle lies within `r` of the line from `a` to `b`: a way through (a gate).
    mutating func clear(from a: Vec2, to b: Vec2, _ r: Float) {
        let steps = max(1, Int((simd_distance(a, b) / (Self.cell * 0.5)).rounded(.up)))
        for s in 0...steps { clear(lerp(a, b, Float(s) / Float(steps)), r) }
    }

    /// Opens every cell whose middle lies within a circle.
    mutating func clear(_ c: Vec2, _ r: Float) {
        guard reaches(c, r) else { return }
        let lo = cellOf(c - Vec2(repeating: r)), hi = cellOf(c + Vec2(repeating: r))
        for row in max(0, lo.row)...min(side - 1, hi.row) {
            for column in max(0, lo.column)...min(side - 1, hi.column) where simd_distance(middle(row * side + column), c) < r {
                open[row * side + column] = true
            }
        }
    }

    /// The cheapest open way from `start` to `end`, as corners (`end` last; `start` left out), into `path`,
    /// never through a fence but at its gate (`fences`, those of its lines `standing`). The cells under both ends
    /// count as open. False when there is none.
    mutating func route(from start: Vec2, to end: Vec2, fences: FenceLines = FenceLines(), standing: (FenceLines.Line) -> Bool = { _ in true },
                        into path: inout [Vec2]) -> Bool {
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
        let fenced = fences.near(origin + Vec2(repeating: Float(side) * Self.cell / 2), half: Float(side) * Self.cell / 2)
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
                    // No cutting a corner between two shut cells, and no step through a fence.
                    if dr != 0 && dc != 0 && (!open[row * side + c] || !open[r * side + column]) { continue }
                    if fenced && fences.crosses(middle(i), middle(j), standing: standing) { continue }
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
                guard clear(corners[anchor], corners[k]) && !(fenced && fences.crosses(corners[anchor], corners[k], standing: standing))
                        && cost(corners[anchor], corners[k]) <= walked + 1e-3 else { continue }
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
